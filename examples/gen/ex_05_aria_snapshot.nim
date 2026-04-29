## ex_05_aria_snapshot — render a Playwright-style ARIA tree dump.
##
## This example loads the bundled ``examples/ariaSnapshot.js`` helper into
## the inspected page as an ES module, calls ``generateAriaTree`` on
## ``document.body``, then prints ``renderAriaTree(...).text``.
##
## Usage::
##
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --url=https://example.com
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --discover --depth=3 --boxes
##
## Set ``LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib`` on
## NixOS if OpenSSL does not load.

import std/[base64, json, options, os, parseopt, strformat, strutils]
import chronos
import cdp/[chrome, transport, jsonhooks]
import cdp/gen/page as cdpPage
import cdp/gen/runtime as cdpRuntime

type
  Mode = enum mLaunch, mDiscover

  Args = object
    mode: Mode
    host: string
    port: int
    url: string
    depth: int
    boxes: bool

const SampleHtml = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ncdp ARIA snapshot demo</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 42rem; }
    nav a, button { margin-right: .75rem; }
    main { display: grid; gap: 1rem; }
    fieldset { border: 1px solid #bbb; border-radius: .5rem; padding: 1rem; }
  </style>
</head>
<body>
  <header>
    <h1>Checkout</h1>
    <nav aria-label="Primary">
      <a href="#cart">Cart</a>
      <a href="#shipping">Shipping</a>
      <a href="#payment">Payment</a>
    </nav>
  </header>
  <main>
    <section aria-labelledby="cart-heading">
      <h2 id="cart-heading">Cart summary</h2>
      <ul>
        <li>Noise-cancelling headphones, quantity 1</li>
        <li>USB-C cable, quantity 2</li>
      </ul>
      <p>Total: <strong>$129.00</strong></p>
    </section>
    <form aria-label="Shipping details">
      <label>Full name <input name="name" value="Ada Lovelace"></label>
      <label>Email <input name="email" type="email" placeholder="you@example.com"></label>
      <fieldset>
        <legend>Delivery speed</legend>
        <label><input type="radio" name="speed" checked> Standard</label>
        <label><input type="radio" name="speed"> Express</label>
      </fieldset>
      <label><input type="checkbox" checked> Send delivery updates</label>
      <button type="button">Continue to payment</button>
    </form>
  </main>
</body>
</html>
"""

proc sampleUrl(): string =
  "data:text/html;charset=utf-8;base64," & base64.encode(SampleHtml)

proc parseArgs(): Args =
  result = Args(mode: mLaunch, host: "127.0.0.1", port: 9222,
                url: sampleUrl(), depth: 0, boxes: false)
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "discover", "d": result.mode = mDiscover
      of "launch", "l":   result.mode = mLaunch
      of "host":          result.host = p.val
      of "port":          result.port = parseInt(p.val)
      of "url":           result.url = p.val
      of "depth":         result.depth = parseInt(p.val)
      of "boxes":         result.boxes = true
      of "help", "h":
        echo "usage: ex_05 [--launch|--discover] [--host=H] [--port=N] " &
             "[--url=URL] [--depth=N] [--boxes]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc waitForPageLoad(loaded: Future[void]) {.async: (raises: [CatchableError]).} =
  if not await loaded.withTimeout(10.seconds):
    raise newException(CatchableError, "page load timed out after 10s")

proc evaluateString(client: CDPClient; expression: string): Future[string] {.
    async: (raises: [CatchableError]).} =
  let r = await cdpRuntime.evaluate(client,
    expression = expression,
    objectGroup = none(string),
    includeCommandLineAPI = none(bool),
    silent = none(bool),
    contextId = none(RuntimeExecutionContextId),
    returnByValue = some(true),
    generatePreview = none(bool),
    userGesture = none(bool),
    awaitPromise = some(true),
    throwOnSideEffect = none(bool),
    timeout = none(RuntimeTimeDelta),
    disableBreaks = none(bool),
    replMode = none(bool),
    allowUnsafeEvalBlockedByCSP = some(true),
    uniqueContextId = none(string),
    serializationOptions = none(RuntimeSerializationOptions))
  if r.exceptionDetails.isSome:
    raise newException(CatchableError, "Runtime.evaluate threw while building ARIA snapshot")
  if r.result.value.isSome and r.result.value.get.kind == JString:
    return r.result.value.get.getStr()
  raise newException(CatchableError, "Runtime.evaluate did not return a string")

proc ariaTreeExpression(args: Args): string =
  let helperPath = currentSourcePath().parentDir() / ".." / "ariaSnapshot.js"
  let helper = readFile(helperPath)
  let moduleUrl = "data:text/javascript;base64," & base64.encode(helper)
  let opts = %*{
    "mode": "ai",
    "refPrefix": "n",
    "boxes": args.boxes,
  }
  if args.depth > 0:
    opts["depth"] = newJInt(args.depth)
  let moduleUrlLiteral = $(%moduleUrl)
  let optsLiteral = $opts
  """
(async () => {
  const aria = await import(""" & moduleUrlLiteral & """);
  const root = document.body || document.documentElement;
  const options = """ & optsLiteral & """;
  const snapshot = aria.generateAriaTree(root, options);
  return aria.renderAriaTree(snapshot, options).text;
})()
"""

proc demo(args: Args; client: CDPClient) {.async: (raises: [CatchableError]).} =
  let loaded = newFuture[void]("aria-snapshot-page-loaded")
  cdpPage.onLoadEventFired(client,
    proc(p: PageLoadEventFiredParams) {.gcsafe, raises: [].} =
      if not loaded.finished:
        loaded.complete())
  await cdpPage.enable(client, enableFileChooserOpenedEvent = none(bool))

  echo "--- Page.navigate ---"
  let nav = await cdpPage.navigate(client,
    url = args.url,
    referrer = none(string),
    transitionType = none(PageTransitionType),
    frameId = none(PageFrameId),
    referrerPolicy = none(PageReferrerPolicy))
  echo &"  frameId: {nav.frameId.string}"
  if nav.errorText.isSome:
    echo &"  errorText: {nav.errorText.get}"

  echo "--- waiting for loadEventFired ---"
  await waitForPageLoad(loaded)

  echo "--- ARIA snapshot ---"
  let tree = await evaluateString(client, ariaTreeExpression(args))
  echo tree

proc connectAndRun(args: Args; pageWsUrl: string) {.
    async: (raises: [CatchableError]).} =
  let client = await transport.connect(pageWsUrl)
  try:
    await demo(args, client)
  finally:
    await transport.close(client)

proc runDiscover(args: Args) {.async: (raises: [CatchableError]).} =
  let pageWs = await chrome.newTab(args.host, args.port, "about:blank")
  echo "page websocket: ", pageWs
  await connectAndRun(args, pageWs)

proc runLaunch(args: Args) {.async: (raises: [CatchableError]).} =
  var opts = initLaunchOptions()
  opts.host = args.host
  opts.port = args.port
  let cp = await chrome.launch(opts)
  echo "chrome wsUrl: ", cp.wsUrl
  try:
    let pageWs = await chrome.newTab(args.host, args.port, "about:blank")
    echo "page wsUrl:   ", pageWs
    await connectAndRun(args, pageWs)
  finally:
    await chrome.terminate(cp)

when isMainModule:
  let args = parseArgs()
  case args.mode
  of mLaunch: waitFor runLaunch(args)
  of mDiscover: waitFor runDiscover(args)
