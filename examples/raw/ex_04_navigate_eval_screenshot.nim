## ex_04_navigate_eval_screenshot — take the browser out for a spin.
##
## Drives a real Chrome through several CDP domains using only the
## generated bindings:
##
## 1. Launch chrome (or `--discover` an existing one).
## 2. Open a new tab and connect a CDPClient to its **page-scoped**
##    debugger URL — that gives us `Page.*`, `Runtime.*`, `DOM.*`
##    without needing session routing on top of the browser
##    websocket.
## 3. Enable the `Page` domain and subscribe to `loadEventFired`.
## 4. Navigate to a URL (default https://example.com).
## 5. Wait for the load event.
## 6. Evaluate JavaScript via `Runtime.evaluate` to read
##    ``document.title`` and the first 200 chars of body text.
## 7. Capture a PNG screenshot via `Page.captureScreenshot` and write
##    it to ``/tmp/ncdp-screenshot.png``.
## 8. Close the tab and terminate chrome.
##
## Usage::
##
##   nim c -d:ssl -r examples/raw/ex_04_navigate_eval_screenshot.nim
##   nim c -d:ssl -r examples/raw/ex_04_navigate_eval_screenshot.nim -- --url=https://news.ycombinator.com
##   nim c -d:ssl -r examples/raw/ex_04_navigate_eval_screenshot.nim -- --discover
##
## Set ``LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib``
## on NixOS for OpenSSL to load.

import std/[options, parseopt, strformat, strutils]
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
    out_path: string

proc parseArgs(): Args =
  result = Args(mode: mLaunch, host: "127.0.0.1", port: 9222,
                url: "https://example.com",
                out_path: "/tmp/ncdp-screenshot.png")
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      if p.key.len == 0: continue # separator from ``nim c -r file -- ...``
      case p.key
      of "discover", "d": result.mode = mDiscover
      of "launch", "l":   result.mode = mLaunch
      of "host":          result.host = p.val
      of "port":          result.port = parseInt(p.val)
      of "url":           result.url = p.val
      of "out", "o":      result.out_path = p.val
      of "help", "h":
        echo "usage: ex_04 [--launch|--discover] [--host=H] [--port=N] " &
             "[--url=URL] [--out=PATH]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc demo(args: Args; client: CDPClient) {.async: (raises: [CatchableError]).} =
  # Subscribe to Page.loadEventFired BEFORE enabling the domain — the
  # listener registration is a local bookkeeping op and doesn't race
  # with chrome.
  let loaded = newFuture[void]("page-loaded")
  cdpPage.onLoadEventFired(client,
    proc(p: PageLoadEventFiredParams) {.gcsafe, raises: [].} =
      if not loaded.finished:
        loaded.complete())

  echo "--- Page.enable ---"
  await cdpPage.enable(client, enableFileChooserOpenedEvent = none(bool))

  echo "--- Page.navigate ---"
  let nav = await cdpPage.navigate(client,
    url = args.url,
    referrer = none(string),
    transitionType = none(PageTransitionType),
    frameId = none(PageFrameId),
    referrerPolicy = none(PageReferrerPolicy))
  echo &"  frameId:    {nav.frameId.string}"
  if nav.errorText.isSome:
    echo &"  errorText:  {nav.errorText.get}"

  echo "--- waiting for loadEventFired ---"
  if not await loaded.withTimeout(10.seconds):
    raise newException(CatchableError, "page load timed out after 10s")
  echo "  page loaded."

  echo "--- Runtime.evaluate (document.title) ---"
  let titleR = await cdpRuntime.evaluate(client,
    expression = "document.title",
    objectGroup = none(string),
    includeCommandLineAPI = none(bool),
    silent = none(bool),
    contextId = none(RuntimeExecutionContextId),
    returnByValue = some(true),
    generatePreview = none(bool),
    userGesture = none(bool),
    awaitPromise = none(bool),
    throwOnSideEffect = none(bool),
    timeout = none(RuntimeTimeDelta),
    disableBreaks = none(bool),
    replMode = none(bool),
    allowUnsafeEvalBlockedByCSP = none(bool),
    uniqueContextId = none(string),
    serializationOptions = none(RuntimeSerializationOptions))
  let titleVal =
    if titleR.result.value.isSome: titleR.result.value.get
    else: newJNull()
  echo &"  title: {titleVal}"

  echo "--- Runtime.evaluate (first 200 chars of body) ---"
  let bodyR = await cdpRuntime.evaluate(client,
    expression = "document.body && document.body.innerText.slice(0, 200)",
    objectGroup = none(string),
    includeCommandLineAPI = none(bool),
    silent = none(bool),
    contextId = none(RuntimeExecutionContextId),
    returnByValue = some(true),
    generatePreview = none(bool),
    userGesture = none(bool),
    awaitPromise = none(bool),
    throwOnSideEffect = none(bool),
    timeout = none(RuntimeTimeDelta),
    disableBreaks = none(bool),
    replMode = none(bool),
    allowUnsafeEvalBlockedByCSP = none(bool),
    uniqueContextId = none(string),
    serializationOptions = none(RuntimeSerializationOptions))
  let bodyStr =
    if bodyR.result.value.isSome and bodyR.result.value.get.kind == JString:
      bodyR.result.value.get.getStr()
    else: ""
  echo "  body excerpt: |"
  for line in bodyStr.splitLines:
    echo "    ", line

  echo "--- Page.captureScreenshot ---"
  let shot = await cdpPage.captureScreenshot(client,
    format = some(PageCaptureScreenshotParamsFormat.Png),
    quality = none(int),
    clip = none(PageViewport),
    fromSurface = some(true),
    captureBeyondViewport = none(bool),
    optimizeForSpeed = some(true))
  let raw = shot.data.bytes
  var asStr = newString(raw.len)
  for i in 0 ..< raw.len: asStr[i] = char(raw[i])
  writeFile(args.out_path, asStr)
  echo &"  wrote {raw.len} bytes → {args.out_path}"

proc connectAndRun(args: Args; pageWsUrl: string) {.
    async: (raises: [CatchableError]).} =
  let client = await transport.connect(pageWsUrl)
  try:
    await demo(args, client)
  finally:
    await transport.close(client)

proc runDiscover(args: Args) {.async: (raises: [CatchableError]).} =
  echo "--- discover ---"
  let pageWs = await chrome.newTab(args.host, args.port, "about:blank")
  echo "  page websocket: ", pageWs
  await connectAndRun(args, pageWs)

proc runLaunch(args: Args) {.async: (raises: [CatchableError]).} =
  echo "--- launch ---"
  var opts = initLaunchOptions()
  opts.host = args.host
  opts.port = args.port
  let cp = await chrome.launch(opts)
  echo "  chrome wsUrl: ", cp.wsUrl
  try:
    let pageWs = await chrome.newTab(args.host, args.port, "about:blank")
    echo "  page wsUrl:   ", pageWs
    await connectAndRun(args, pageWs)
  finally:
    await chrome.terminate(cp)

when isMainModule:
  let args = parseArgs()
  case args.mode
  of mLaunch: waitFor runLaunch(args)
  of mDiscover: waitFor runDiscover(args)
