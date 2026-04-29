## Unit tests for `cdp/transport`. We don't open a websocket here; the
## tests exercise `dispatchResponse` / `dispatchEvent` against a bare
## `CDPClient` and assert that pending Futures complete (or fail) with
## the right values, and that registered event listeners observe the
## right payloads.

import std/[json, unittest]
import chronos
import cdp/[transport, jsonhooks]

suite "transport — response dispatch":

  test "successful response completes the matching Future":
    let c = newTestClient()
    let fut = c.registerPendingForTest(7)
    c.dispatchResponse(%*{"id": 7, "result": {"hello": "world"}})
    check fut.finished
    let res = waitFor fut
    check res["hello"].getStr() == "world"

  test "error response fails the Future with CDPError":
    let c = newTestClient()
    let fut = c.registerPendingForTest(11)
    c.dispatchResponse(%*{"id": 11,
        "error": {"code": -32601, "message": "method not found"}})
    check fut.finished
    expect CDPError:
      discard waitFor fut

  test "missing result is treated as empty object":
    let c = newTestClient()
    let fut = c.registerPendingForTest(3)
    c.dispatchResponse(%*{"id": 3})
    let res = waitFor fut
    check res.kind == JObject
    check res.len == 0

  test "unknown id is silently dropped":
    let c = newTestClient()
    # No pending Future for id=99 — must not raise.
    c.dispatchResponse(%*{"id": 99, "result": {}})

  test "onRunnerDone fails pending without a Closed event":
    proc body() =
      # Simulate the receive loop ending abnormally (e.g. cancelled or
      # a Defect bubbled past the raises annotation): the addCallback
      # hook should still flush pending Futures so callers don't hang.
      let c = newTestClient()
      let fut = c.registerPendingForTest(42)
      let runner = newFuture[void]("test.runner")
      runner.addCallback(onRunnerDone, cast[pointer](c))
      runner.complete()  # fires the callback synchronously
      check fut.finished
      expect CDPTransportError:
        discard waitFor fut

suite "transport — event dispatch":

  # Each test wraps its body in a proc so the closure captures stay
  # local (chronos requires gcsafe on EventCallback, which forbids
  # capturing module-level GC'd vars).
  type
    Seen = ref object
      node: JsonNode
      order: seq[int]
      fired: int

  test "listener fires with params":
    proc body() =
      let c = newTestClient()
      let s = Seen()
      c.addEventListener("Page.frameNavigated",
        proc(p: JsonNode) {.gcsafe, raises: [].} = s.node = p)
      c.dispatchEvent(%*{"method": "Page.frameNavigated",
          "params": {"frameId": "abc"}})
      check s.node != nil
      check s.node["frameId"].getStr() == "abc"
    body()

  test "multiple listeners fire in registration order":
    proc body() =
      let c = newTestClient()
      let s = Seen()
      c.addEventListener("X.tick",
        proc(p: JsonNode) {.gcsafe, raises: [].} = s.order.add 1)
      c.addEventListener("X.tick",
        proc(p: JsonNode) {.gcsafe, raises: [].} = s.order.add 2)
      c.dispatchEvent(%*{"method": "X.tick", "params": {}})
      check s.order == @[1, 2]
    body()

  test "removeEventListeners drops every callback":
    proc body() =
      let c = newTestClient()
      let s = Seen()
      c.addEventListener("X.y",
        proc(p: JsonNode) {.gcsafe, raises: [].} = inc s.fired)
      c.removeEventListeners("X.y")
      c.dispatchEvent(%*{"method": "X.y", "params": {}})
      check s.fired == 0
    body()

  test "missing params surfaces as empty object":
    proc body() =
      let c = newTestClient()
      let s = Seen()
      c.addEventListener("X.bare",
        proc(p: JsonNode) {.gcsafe, raises: [].} = s.node = p)
      c.dispatchEvent(%*{"method": "X.bare"})
      check s.node != nil
      check s.node.kind == JObject
      check s.node.len == 0
    body()

suite "jsonhooks — dropNullFields":

  test "removes null leaves recursively":
    let j = %*{"a": 1, "b": nil, "c": {"d": nil, "e": 2}, "f": [{"g": nil}]}
    dropNullFields(j)
    check not j.hasKey("b")
    check not j["c"].hasKey("d")
    check j["c"]["e"].getInt() == 2
    check not j["f"][0].hasKey("g")

  test "leaves arrays of primitives alone":
    let j = %*{"xs": [1, 2, 3]}
    dropNullFields(j)
    check j["xs"].len == 3

suite "jsonhooks — Binary":

  test "round-trips through base64":
    let original = Binary(@[byte 1, 2, 3, 4, 5])
    let encoded = toJson(original)
    check encoded.kind == JString
    var decoded: Binary
    fromJsonHook(decoded, encoded)
    check decoded.bytes == @[byte 1, 2, 3, 4, 5]
