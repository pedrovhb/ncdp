## CDP transport: a websocket client speaking JSON-RPC 2.0 to a
## `chrome --remote-debugging-port=NNNN` endpoint.
##
## The shape is deliberately small: callers `connect` to a `ws://...`
## URL and get back a `CDPClient`. They invoke `sendCommand`, which
## allocates a request id, sends a `{id, method, params}` frame, and
## awaits a `Future[JsonNode]` that the receive loop completes when the
## matching `{id, result}` arrives. Events are fanned out to callbacks
## registered with `addEventListener`.
##
## This module is hand-written and never regenerated. Generated domain
## modules use only `sendCommand` and `addEventListener` from here —
## the rest of this file is private machinery.

import std/[json, tables]
import chronos
import nws_client
import ./jsonhooks

type
  CDPError* = object of CatchableError
    ## Protocol-level error: the server sent a response frame whose
    ## ``error`` field was populated, or a frame's shape didn't match
    ## what the protocol promises. ``code`` mirrors the server-supplied
    ## error code when one was given.
    code*: int

  CDPTransportError* = object of CatchableError
    ## Anything below the protocol layer: websocket open failed,
    ## connection dropped while we had pending requests, or an inbound
    ## frame failed UTF-8 / JSON validation. Pending Futures are failed
    ## with a ``CDPTransportError`` when the session closes.

  EventCallback* = proc(params: JsonNode) {.gcsafe, raises: [].}
    ## Called with the raw ``params`` JSON for each matching event.
    ## Listeners must not raise; protocol-level decoding happens inside
    ## the listener (typically a thin wrapper produced by codegen).

  CDPClient* = ref object
    ws: WSClient
    nextId: int
    pending: Table[int, Future[JsonNode]]
    listeners: Table[string, seq[EventCallback]]
    runner: Future[void]
    closed: bool

# --------------------------------------------------------------- helpers ----

proc allocId(c: CDPClient): int =
  inc c.nextId
  c.nextId

proc failPending(c: CDPClient; reason: string) =
  ## Fail every still-pending request with a ``CDPTransportError``. Called
  ## when the session closes or when the receive loop hits an
  ## unrecoverable decode failure.
  for id, fut in c.pending.mpairs:
    if not fut.finished:
      let e = newException(CDPTransportError, reason)
      fut.fail(e)
  c.pending.clear()

proc dispatchResponse*(c: CDPClient; frame: JsonNode) {.raises: [].} =
  ## Inbound frame carries an ``id`` — match it to a pending Future and
  ## complete or fail it. Unknown ids are ignored: they correspond to
  ## requests already cancelled on our side.
  let idNode = frame.getOrDefault("id")
  if idNode.isNil or idNode.kind != JInt: return
  let id = int(idNode.num)
  let fut = c.pending.getOrDefault(id, nil)
  c.pending.del(id)
  if fut.isNil or fut.finished: return
  let err = frame.getOrDefault("error")
  if not err.isNil and err.kind == JObject:
    let msgNode = err.getOrDefault("message")
    let msg = if not msgNode.isNil and msgNode.kind == JString: msgNode.str
              else: "CDP error"
    let codeNode = err.getOrDefault("code")
    let code = if not codeNode.isNil and codeNode.kind == JInt: int(codeNode.num)
               else: 0
    let e = newException(CDPError, msg)
    e.code = code
    fut.fail(e)
  else:
    let res = frame.getOrDefault("result")
    fut.complete(if res.isNil: newJObject() else: res)

proc dispatchEvent*(c: CDPClient; frame: JsonNode) {.raises: [].} =
  let mNode = frame.getOrDefault("method")
  if mNode.isNil or mNode.kind != JString: return
  let m = mNode.str
  let params = frame.getOrDefault("params")
  let p = if params.isNil: newJObject() else: params
  let cbs = c.listeners.getOrDefault(m)
  for cb in cbs:
    cb(p)

# ---------------------------------------------------- the receive callback -

proc onEvent(ws: WSClient; ev: WSEvent;
             c: CDPClient): Future[void] {.async: (raises: [CancelledError]).} =
  ## The callback handed to ``nws_client.run``. Routes inbound frames
  ## into ``pending`` / ``listeners``. nws_client only allows
  ## ``CancelledError`` to escape, so every other failure is mapped to
  ## a transport-error completion of the affected Future.
  case ev.kind
  of WSEventKind.Open:
    discard
  of WSEventKind.Text:
    var parsed: JsonNode
    try:
      parsed = parseJson(ev.text)
    except CatchableError as e:
      c.failPending("malformed JSON inbound: " & e.msg)
      return
    if parsed.kind != JObject:
      c.failPending("non-object inbound frame")
      return
    if parsed.hasKey("id"):
      c.dispatchResponse(parsed)
    elif parsed.hasKey("method"):
      c.dispatchEvent(parsed)
    # silently ignore frames that are neither — chrome occasionally
    # sends keepalive / debug noise that doesn't fit either shape
  of WSEventKind.Binary:
    # CDP is text-only; binary frames are protocol violations on
    # chrome's side. Drop them.
    discard
  of WSEventKind.Closed:
    c.closed = true
    c.failPending("transport closed: " & $int(ev.code) & " " & ev.reason)

# --------------------------------------------------------- test helpers ---

proc newTestClient*(): CDPClient =
  ## Constructor used by unit tests. The client has no websocket
  ## attached and ``sendCommand`` will fail; the test exercises the
  ## frame-dispatch helpers directly.
  CDPClient()

proc registerPendingForTest*(c: CDPClient; id: int): Future[JsonNode] =
  ## Insert a pending Future under a known id so a test can simulate
  ## the receive path calling ``dispatchResponse``.
  result = newFuture[JsonNode]("test.pending")
  c.pending[id] = result

# ------------------------------------------------------- public surface ----

proc onRunnerDone*(udata: pointer) {.gcsafe, raises: [].} =
  ## Settling-side cleanup attached to ``client.runner`` via
  ## ``addCallback``. Whatever path ended the runner — a regular
  ## ``WSEventKind.Closed`` event already failed pending Futures and
  ## set ``closed`` (so this is a no-op then), or cancellation /
  ## a ``Defect`` slipped past the ``raises: [CancelledError]``
  ## annotation, in which case we still need to flush pending Futures
  ## so callers don't hang on them forever.
  let client = cast[CDPClient](udata)
  if client.isNil or client.closed: return
  client.closed = true
  client.failPending("receive loop ended without Closed event")

proc connect*(url: string): Future[CDPClient] {.
    async: (raises: [CDPTransportError, CancelledError]).} =
  ## Opens a websocket to ``url`` (typically ``ws://localhost:9222/...``)
  ## and starts the receive loop in the background. The returned client
  ## is ready to accept ``sendCommand`` calls.
  ##
  ## A cleanup callback is attached to the runner Future so that if the
  ## receive loop terminates by any path other than emitting a
  ## ``WSEventKind.Closed`` (notably cancellation), pending requests
  ## are still failed. ``nws_client.run`` declares itself
  ## ``raises: [CancelledError]`` and otherwise turns transport-level
  ## errors into ``Closed`` events, but we don't rely on that contract
  ## holding under every edge case.
  let client = CDPClient()
  try:
    client.ws = await nws_client.connect(url)
  except CatchableError as e:
    raise newException(CDPTransportError, "connect failed: " & e.msg)
  let handler: WSHandler = proc(ws: WSClient; ev: WSEvent): Future[void]
      {.async: (raises: [CancelledError]).} =
    await onEvent(ws, ev, client)
  client.runner = nws_client.run(client.ws, handler)
  client.runner.addCallback(onRunnerDone, cast[pointer](client))
  asyncSpawn client.runner
  client

proc sendCommand*(c: CDPClient; methodName: string;
                  params: JsonNode = nil): Future[JsonNode] {.
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  ## Send a JSON-RPC command, return the ``result`` member of the
  ## response. ``params`` may be nil (no params on the wire), a
  ## ``JObject``, or any other JSON node (the protocol forbids
  ## non-objects but we don't second-guess the caller).
  ##
  ## ``params`` is **not** mutated: ``sendCommand`` deep-copies it
  ## before stripping ``null`` fields, so callers can safely pass
  ## a node they intend to inspect or reuse afterwards.
  if c.closed:
    raise newException(CDPTransportError, "client is closed")
  let id = c.allocId()
  let frame = newJObject()
  frame["id"] = newJInt(id)
  frame["method"] = newJString(methodName)
  if params != nil and params.kind != JNull:
    let owned = json.copy(params)
    dropNullFields(owned)
    frame["params"] = owned
  let fut = newFuture[JsonNode]("cdp.sendCommand")
  {.cast(gcsafe).}:
    {.cast(raises: []).}:
      c.pending[id] = fut
  try:
    await c.ws.send($frame)
  except CatchableError as e:
    {.cast(gcsafe).}:
      {.cast(raises: []).}:
        c.pending.del(id)
    raise newException(CDPTransportError, "send failed: " & e.msg)
  try:
    return await fut
  except CDPError as e:
    raise e
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raise newException(CDPTransportError, "response failed: " & e.msg)

proc addEventListener*(c: CDPClient; methodName: string; cb: EventCallback) =
  ## Register a listener for events with the given fully-qualified
  ## method name (e.g. ``"Page.frameNavigated"``). Multiple listeners
  ## per method are allowed; they fire in registration order.
  c.listeners.mgetOrPut(methodName, @[]).add(cb)

proc removeEventListeners*(c: CDPClient; methodName: string) =
  ## Drop every listener registered for ``methodName``.
  c.listeners.del(methodName)

proc close*(c: CDPClient): Future[void] {.async: (raises: [CancelledError]).} =
  ## Close the websocket and fail any still-pending requests. Safe to
  ## call multiple times; idempotent.
  if c.closed: return
  c.closed = true
  await c.ws.close()
  if not c.runner.isNil and not c.runner.finished:
    try:
      await c.runner
    except CatchableError:
      discard
  c.failPending("client closed by caller")
