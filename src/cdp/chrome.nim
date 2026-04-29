## Launch and manage Chrome / Chromium for CDP integration.
##
## Two entry points:
##
## * `launch(opts)` — spawn a fresh browser process with a temporary
##   user-data dir, wait for the debugger endpoint to become reachable,
##   and return a handle owning both the process and the discovered
##   browser-level websocket URL.
## * `discover(host, port)` — point at an already-running browser
##   started elsewhere and return its websocket URL only.
##
## A `ChromeProcess` returned by `launch` cleans itself up on
## `terminate`: SIGTERM with a configurable grace period, falling back
## to SIGKILL, then deleting the temporary user-data dir.

import std/[exitprocs, json, os, strformat, strutils, sysrand, uri]
import chronos
import chronos/asyncproc
import chronos/apps/http/httpclient
import ./logging

when defined(posix):
  import std/posix

logScope:
  topics = "chrome"

type
  LaunchOptions* = object
    ## Configuration knobs for `launch`. Sensible defaults mean the
    ## common case — "give me a headless Chrome on a random local
    ## port" — is one zero-arg call away.
    executable*: string
      ## Override the binary path. Empty means "look up via
      ## ``$NCDP_CHROME`` and then PATH".
    host*: string ## Default ``"127.0.0.1"``.
    port*: int    ## Default ``9222``. Pick something else when running
                  ## several browsers in parallel.
    headless*: bool   ## Default ``true``. ``--headless=new`` is passed
                      ## when this is set.
    extraArgs*: seq[string]
      ## Appended verbatim to the chrome command line, after the
      ## defaults.
    userDataDir*: string
      ## Override the user-data dir. Empty means "create a fresh temp
      ## dir and clean it up on terminate".
    bootTimeout*: Duration
      ## How long `launch` waits for the debugger endpoint to come up
      ## before giving up. Default 10 seconds.

  ChromeProcess* = ref object
    handle: AsyncProcessRef
    wsUrl*: string
      ## Browser-level websocket URL (the ``webSocketDebuggerUrl`` from
      ## ``/json/version``). Pass this straight to
      ## ``transport.connect``.
    httpBase*: string
      ## ``http://host:port`` — handy for hitting other endpoints under
      ## ``/json/`` for tab discovery, etc.
    userDataDir: string
      ## Set when launch created a temp dir; cleaned up on terminate.

  ChromeError* = object of CatchableError
    ## Any failure from this module: missing binary, boot timeout,
    ## non-200 response from the discovery endpoint, malformed JSON.

# ----------------------------- exit-handler bookkeeping -------------------

var liveProcesses {.threadvar.}: seq[ChromeProcess]
var exitHandlerRegistered {.threadvar.}: bool

proc killOnExit() {.noconv.} =
  ## Last-ditch cleanup invoked from ``addExitProc``. We can't run
  ## async code here, so on POSIX we send SIGKILL to the whole process
  ## group of every still-live ``ChromeProcess`` and recursively delete
  ## its user-data dir. On Windows we currently do nothing — the
  ## process and its job-object children will be reaped by the OS once
  ## our process exits.
  trace "exit handler firing", count = liveProcesses.len
  for p in liveProcesses:
    if p.handle.isNil: continue
    when defined(posix):
      let pid = Pid(p.handle.pid)
      discard posix.kill(-pid, SIGKILL)  # negative pid → process group
    if p.userDataDir.len > 0:
      try: removeDir(p.userDataDir)
      except CatchableError: discard
  liveProcesses.setLen(0)

proc registerExitHandler() =
  if not exitHandlerRegistered:
    {.cast(gcsafe).}:
      addExitProc(killOnExit)
    exitHandlerRegistered = true

proc unregisterLiveProcess(p: ChromeProcess) =
  ## Remove ``p`` from the exit-handler list after explicit cleanup.
  ## Linear scan is fine — callers normally have one or two browsers.
  for i in 0 ..< liveProcesses.len:
    if liveProcesses[i] == p:
      liveProcesses.del(i)
      break

# -------------------------------------------------------- defaults ----------

proc initLaunchOptions*(): LaunchOptions =
  ## Default options — useful as a base when overriding only one or two
  ## fields: ``var o = initLaunchOptions(); o.port = 9333``.
  LaunchOptions(
    host: "127.0.0.1",
    port: 9222,
    headless: true,
    bootTimeout: 10.seconds)

# -------------------------------------------------------- helpers -----------

proc fail(msg: string) {.noreturn.} =
  raise newException(ChromeError, msg)

const ChromeCandidates = [
  "chromium", "chromium-browser",
  "google-chrome", "google-chrome-stable",
  "chrome",
]

proc resolveExecutable(override: string): string =
  ## Pick an executable: explicit override → ``$NCDP_CHROME`` →
  ## first hit in ``$PATH`` from the candidate list.
  if override.len > 0:
    if not fileExists(override):
      fail("chrome executable not found: " & override)
    return override
  let envPath = getEnv("NCDP_CHROME")
  if envPath.len > 0:
    if not fileExists(envPath):
      fail("NCDP_CHROME points at non-existent file: " & envPath)
    return envPath
  for name in ChromeCandidates:
    let p = findExe(name)
    if p.len > 0: return p
  fail("could not find Chrome / Chromium on PATH; " &
       "set NCDP_CHROME or pass LaunchOptions.executable")

proc uniqueDataDir(): string =
  ## Build a temp directory path with enough entropy (8 random bytes)
  ## that two concurrent ``launch`` calls — or a fresh launch sharing
  ## the same pid/port as a stale crashed one — can't collide.
  var rnd = newSeq[byte](8)
  if not urandom(rnd):
    # urandom shouldn't fail in practice, but if it does we still want
    # *some* uniqueness — fall back to pid+counter-style naming.
    rnd = @[byte(getCurrentProcessId() and 0xff)]
  var hex = ""
  for b in rnd: hex.add b.toHex(2)
  getTempDir() / &"ncdp-chrome-{hex.toLowerAscii()}"

proc buildArgs(opts: LaunchOptions; userDataDir: string): seq[string] =
  ## Compose the chrome command line. Most defaults exist to keep the
  ## headless instance from doing anything we didn't ask for: no first-
  ## run UI, no default browser prompt, no network probes for
  ## extensions, no GPU init when we won't render anything.
  result = @[
    &"--remote-debugging-port={opts.port}",
    &"--remote-debugging-address={opts.host}",
    &"--user-data-dir={userDataDir}",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--metrics-recording-only",
    "--disable-features=Translate,MediaRouter",
    "--mute-audio",
    "--password-store=basic",
    "--use-mock-keychain",
  ]
  if opts.headless:
    result.add "--headless=new"
    result.add "--disable-gpu"
  for a in opts.extraArgs: result.add a
  result.add "about:blank"

proc fetchVersion(host: string; port: int): Future[JsonNode] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## One-shot HTTP GET to ``/json/version``. Returns the parsed body.
  ## Failures are mapped to ``ChromeError`` so callers don't have to
  ## know about chronos's HTTP error hierarchy.
  let session = HttpSessionRef.new()
  defer:
    try: await session.closeWait()
    except CancelledError: discard
  let url = parseUri(&"http://{host}:{port}/json/version")
  var resp: HttpResponseTuple
  try:
    resp = await session.fetch(url)
  except CancelledError as e: raise e
  except CatchableError as e:
    raise newException(ChromeError, "fetch failed: " & e.msg)
  if resp.status != 200:
    fail(&"/json/version returned HTTP {resp.status}")
  var body = newString(resp.data.len)
  for i in 0 ..< resp.data.len: body[i] = char(resp.data[i])
  try: parseJson(body)
  except CatchableError as e:
    raise newException(ChromeError, "/json/version: bad JSON: " & e.msg)

proc waitForBoot(host: string; port: int;
                 timeout: Duration): Future[JsonNode] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Poll ``/json/version`` until it answers or ``timeout`` elapses.
  ## Backoff: 50 ms → 100 ms → 200 ms, capped at 500 ms.
  let started = Moment.now()
  let deadline = started + timeout
  var delay = 50.milliseconds
  var lastErr = ""
  var attempt = 0
  while Moment.now() < deadline:
    inc attempt
    let elapsed = Moment.now() - started
    trace "boot poll", attempt = attempt, elapsed = elapsed
    try:
      let info = await fetchVersion(host, port)
      if elapsed > 2.seconds:
        warn "chrome boot slow", elapsed = elapsed, attempts = attempt
      return info
    except CancelledError as e: raise e
    except ChromeError as e:
      lastErr = e.msg
    await sleepAsync(delay)
    if delay < 500.milliseconds: delay = delay * 2
  let elapsed = Moment.now() - started
  error "chrome boot timeout", elapsed = elapsed, lastErr = lastErr,
        attempts = attempt
  fail("timed out waiting for chrome debugger endpoint" &
       (if lastErr.len > 0: " (last error: " & lastErr & ")" else: ""))

# -------------------------------------------------------- public API --------

proc rewriteAuthority(wireUrl, host: string; port: int): string =
  ## Chrome echoes back whatever ``Host:`` header it received in the
  ## ``webSocketDebuggerUrl``, so when our HTTP client omits the port
  ## (chronos drops the default-looking ``:80`` for HTTP fetches), we
  ## get a URL that's missing it. Patch the authority back from the
  ## known host:port we just talked to.
  const Schemes = ["ws://", "wss://"]
  for scheme in Schemes:
    if wireUrl.startsWith(scheme):
      let rest = wireUrl[scheme.len .. ^1]
      let slash = rest.find('/')
      let pathPart = if slash >= 0: rest[slash .. ^1] else: ""
      return &"{scheme}{host}:{port}{pathPart}"
  wireUrl  # unrecognised scheme — leave it alone

proc discover*(host = "127.0.0.1"; port = 9222): Future[string] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Resolve the browser-level websocket URL from a Chrome started
  ## elsewhere. Equivalent to fetching ``/json/version`` once and
  ## pulling out the ``webSocketDebuggerUrl`` field, with the
  ## host:port restored to what we actually used (Chrome rewrites it
  ## from the request's ``Host:`` header, dropping the default port).
  let info = await fetchVersion(host, port)
  let url = info.getOrDefault("webSocketDebuggerUrl")
  if url.isNil or url.kind != JString:
    fail("/json/version: missing webSocketDebuggerUrl")
  rewriteAuthority(url.getStr(), host, port)

proc fetchWithMethod(host: string; port: int; path: string;
                      meth: HttpMethod): Future[JsonNode] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Issue an HTTP request against chrome's debugger REST endpoints
  ## with a non-GET method. chronos's `session.fetch(url)` is
  ## GET-only, so we go via `HttpClientRequestRef.new`.
  let session = HttpSessionRef.new()
  defer:
    try: await session.closeWait()
    except CancelledError: discard
  let req = HttpClientRequestRef.new(
    session, &"http://{host}:{port}{path}", meth = meth).valueOr:
      raise newException(ChromeError, "bad URL: " & $error)
  defer:
    try: await req.closeWait()
    except CancelledError: discard
  var resp: HttpResponseTuple
  try:
    resp = await req.fetch()
  except CancelledError as e: raise e
  except CatchableError as e:
    raise newException(ChromeError, &"{path} fetch failed: " & e.msg)
  if resp.status != 200:
    fail(&"{path} returned HTTP {resp.status}")
  var body = newString(resp.data.len)
  for i in 0 ..< resp.data.len: body[i] = char(resp.data[i])
  try: parseJson(body)
  except CatchableError as e:
    raise newException(ChromeError, &"{path}: bad JSON: " & e.msg)

proc newTab*(host: string; port: int;
              url = "about:blank"): Future[string] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Open a new browser tab via Chrome's `PUT /json/new?<url>` REST
  ## convenience endpoint and return its `webSocketDebuggerUrl`. The
  ## endpoint creates an honest target (a separate page-scoped
  ## websocket) so a CDPClient connected to the returned URL can
  ## issue `Page.*`, `Runtime.*`, `DOM.*` etc. without needing
  ## session routing on top of the browser-level websocket.
  let info = await fetchWithMethod(host, port, "/json/new?" & encodeUrl(url),
                                   MethodPut)
  let wsUrl = info.getOrDefault("webSocketDebuggerUrl")
  if wsUrl.isNil or wsUrl.kind != JString:
    fail("/json/new: missing webSocketDebuggerUrl")
  rewriteAuthority(wsUrl.getStr(), host, port)

proc closeTab*(host: string; port: int; targetId: string):
    Future[void] {.async: (raises: [ChromeError, CancelledError]).} =
  ## Close a tab opened via `newTab`. Best-effort — chrome may have
  ## already disposed the target if the underlying page was closed.
  try:
    discard await fetchWithMethod(host, port, "/json/close/" & targetId,
                                  MethodGet)
  except ChromeError:
    discard  # tab might be gone already; not worth raising

proc launch*(opts = initLaunchOptions()): Future[ChromeProcess] {.
    async: (raises: [ChromeError, CancelledError]).} =
  ## Spawn a fresh chrome process and return a handle once the
  ## debugger endpoint is responsive. The caller owns the handle and
  ## must call ``terminate`` on it (typically inside a ``try/finally``).
  let exe = try: resolveExecutable(opts.executable)
            except OSError as e:
              raise newException(ChromeError, e.msg)
  let createdDataDir = opts.userDataDir.len == 0
  let dataDir =
    if createdDataDir: uniqueDataDir() else: opts.userDataDir
  if createdDataDir:
    try: createDir(dataDir)
    except CatchableError as e:
      fail("could not create user-data dir: " & e.msg)
  # Chrome's stderr is left unredirected and prints to the parent's
  # terminal. That's loud but cheap; a future revision can wire
  # stdoutHandle / stderrHandle through `ProcessStreamHandle.init` to
  # capture or discard the output.
  let args = buildArgs(opts, dataDir)
  # ``ProcessGroup`` puts chrome and every helper it spawns (zygote,
  # renderer, GPU broker) into a fresh process group whose pgid equals
  # the chrome pid. That lets ``terminate`` signal the whole tree
  # rather than just the parent — without it we routinely returned
  # from ``terminate`` while a renderer still held the user-data dir
  # open, causing ``removeDir`` to silently fail.
  let process = try:
      await startProcess(exe, arguments = args,
                         options = {AsyncProcessOption.ProcessGroup})
    except CancelledError as e:
      if createdDataDir:
        try: removeDir(dataDir)
        except CatchableError: discard
      raise e
    except CatchableError as e:
      if createdDataDir:
        try: removeDir(dataDir)
        except CatchableError: discard
      raise newException(ChromeError, "startProcess failed: " & e.msg)

  result = ChromeProcess(
    handle: process,
    httpBase: &"http://{opts.host}:{opts.port}",
    userDataDir: if createdDataDir: dataDir else: "",
  )
  registerExitHandler()
  liveProcesses.add(result)
  template tearDownAndRaise(err: untyped) =
    # Boot failed — tear the process down before propagating.
    try: discard process.terminate()
    except CatchableError: discard
    try: await process.closeWait()
    except CatchableError: discard
    unregisterLiveProcess(result)
    if result.userDataDir.len > 0:
      try: removeDir(result.userDataDir)
      except CatchableError: discard
      result.userDataDir = ""
    result.handle = nil
    raise err
  try:
    let info = await waitForBoot(opts.host, opts.port, opts.bootTimeout)
    let url = info.getOrDefault("webSocketDebuggerUrl")
    if url.isNil or url.kind != JString:
      fail("/json/version: missing webSocketDebuggerUrl")
    result.wsUrl = rewriteAuthority(url.getStr(), opts.host, opts.port)
    info "chrome spawned", pid = process.pid, port = opts.port,
         wsUrl = result.wsUrl
  except ChromeError as e:
    tearDownAndRaise(e)
  except CancelledError as e:
    tearDownAndRaise(e)

when defined(posix):
  proc signalGroup(p: ChromeProcess; sig: cint) =
    ## Send ``sig`` to the entire process group whose pgid is the
    ## chrome pid (chronos's ``ProcessGroup`` option made the chrome
    ## process the leader of a fresh group). Failures are intentionally
    ## ignored — by the time we get here the group may already be gone.
    let pid = Pid(p.handle.pid)
    discard posix.kill(-pid, sig)

proc terminate*(p: ChromeProcess; grace = 3.seconds): Future[void] {.
    async: (raises: [CancelledError]).} =
  ## Stop the process tree. Sends SIGTERM to the whole process group
  ## (chrome + zygote + renderers + GPU helper), waits up to ``grace``
  ## for the parent to exit, escalates to SIGKILL if the grace period
  ## elapses, then removes the temporary user-data dir. Idempotent and
  ## safe to call from a ``finally`` block; nothing here re-raises
  ## beyond cancellation.
  if p.handle.isNil: return
  let pid = p.handle.pid
  debug "terminating chrome", pid = pid
  var forced = false

  when defined(posix):
    p.signalGroup(SIGTERM)
  else:
    try: discard p.handle.terminate()
    except CatchableError: discard

  try:
    discard await p.handle.waitForExit().wait(grace)
  except AsyncTimeoutError:
    forced = true
    warn "chrome killed forcibly", pid = pid, grace = grace
    when defined(posix):
      p.signalGroup(SIGKILL)
    else:
      try: discard p.handle.kill()
      except CatchableError: discard
    try: discard await p.handle.waitForExit().wait(grace)
    except CatchableError: discard
  except CancelledError as e:
    raise e
  except CatchableError: discard

  try: await p.handle.closeWait()
  except CatchableError: discard

  unregisterLiveProcess(p)

  if p.userDataDir.len > 0:
    try: removeDir(p.userDataDir)
    except CatchableError: discard
    p.userDataDir = ""

  if not forced:
    debug "chrome terminated", pid = pid
