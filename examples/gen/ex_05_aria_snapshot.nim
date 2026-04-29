## ex_05_aria_snapshot — render a Playwright-style ARIA tree dump.
##
## This example loads the bundled ``examples/ariaSnapshot.js`` helper into
## the inspected page, calls ``generateAriaTree`` on ``document.body``,
## then prints ``renderAriaTree(...).text``.
##
## Usage::
##
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --url=https://example.com
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --discover --depth=3 --boxes
##   nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --interactive
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
    interactive: bool

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
      of "interactive", "i": result.interactive = true
      of "help", "h":
        echo "usage: ex_05 [--launch|--discover] [--host=H] [--port=N] " &
             "[--url=URL] [--depth=N] [--boxes] [--interactive]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc waitForPageLoad(loaded: Future[void]) {.async: (raises: [CatchableError]).} =
  if not await loaded.withTimeout(10.seconds):
    raise newException(CatchableError, "page load timed out after 10s")

proc exceptionMessage(details: RuntimeExceptionDetails): string =
  result = details.text
  if details.exception.isSome:
    let ex = details.exception.get
    if ex.description.isSome:
      result.add "\n" & ex.description.get
    elif ex.value.isSome:
      result.add "\n" & $ex.value.get
  if details.url.isSome:
    result.add &"\n  at {details.url.get}:{details.lineNumber + 1}:{details.columnNumber + 1}"

proc jsString(s: string): string = $(%s)

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
    raise newException(CatchableError,
      "Runtime.evaluate threw:\n" &
      exceptionMessage(r.exceptionDetails.get))
  if r.result.value.isSome and r.result.value.get.kind == JString:
    return r.result.value.get.getStr()
  raise newException(CatchableError, "Runtime.evaluate did not return a string")

proc ariaSnapshotHelperSource(): string =
  let helperPath = currentSourcePath().parentDir() / ".." / "ariaSnapshot.js"
  result = readFile(helperPath)
  let exportAt = result.rfind("\nexport {")
  if exportAt >= 0:
    result.setLen(exportAt)

proc ariaOptionsLiteral(args: Args): string =
  let opts = %*{
    "mode": "ai",
    "refPrefix": "n",
    "boxes": args.boxes,
  }
  if args.depth > 0:
    opts["depth"] = newJInt(args.depth)
  $opts

proc installAriaHelperExpression(): string =
  let helper = ariaSnapshotHelperSource()
  """
(() => {
  if (window.__ncdpAria?.click)
    return "ok";
""" & helper & """
  const root = () => document.body || document.documentElement;
  const refresh = options => {
    const snapshot = generateAriaTree(root(), options);
    window.__ncdpAriaElements = snapshot.elements;
    return snapshot;
  };
  const elementForRef = ref => {
    const current = window.__ncdpAriaElements?.get(ref);
    if (current && current.isConnected)
      return current;
    refresh({ mode: "ai", refPrefix: "n" });
    return window.__ncdpAriaElements?.get(ref);
  };
  const fire = (element, type) => element.dispatchEvent(new Event(type, {
    bubbles: true,
    composed: true,
  }));
  window.__ncdpAria = {
    snapshotText(options) {
      return renderAriaTree(refresh(options), options).text;
    },
    click(ref) {
      const element = elementForRef(ref);
      if (!element)
        throw new Error(`No element for ref=${ref}. Run snapshot and use a visible ref.`);
      element.scrollIntoView({ block: "center", inline: "center" });
      element.focus?.();
      element.click();
      return `clicked ${ref}`;
    },
    fill(ref, text) {
      const element = elementForRef(ref);
      if (!element)
        throw new Error(`No element for ref=${ref}. Run snapshot and use a visible ref.`);
      element.scrollIntoView({ block: "center", inline: "center" });
      element.focus?.();
      if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
        element.value = text;
        fire(element, "input");
        fire(element, "change");
      } else if (element.isContentEditable) {
        element.textContent = text;
        fire(element, "input");
      } else {
        throw new Error(`ref=${ref} is not fillable`);
      }
      return `filled ${ref}`;
    },
    press(key) {
      const element = document.activeElement || root();
      for (const type of ["keydown", "keyup"])
        element.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, composed: true }));
      return `pressed ${key}`;
    },
  };
  return "ok";
})()
"""

proc ariaTreeExpression(args: Args): string =
  let helper = ariaSnapshotHelperSource()
  let optsLiteral = ariaOptionsLiteral(args)
  """
(() => {
  if (!window.__ncdpAria) {
""" & helper & """
    const root = () => document.body || document.documentElement;
    const refresh = options => {
      const snapshot = generateAriaTree(root(), options);
      window.__ncdpAriaElements = snapshot.elements;
      return snapshot;
    };
    window.__ncdpAria = {
      snapshotText(options) {
        return renderAriaTree(refresh(options), options).text;
      },
    };
  }
  const root = document.body || document.documentElement;
  const options = """ & optsLiteral & """;
  return window.__ncdpAria.snapshotText(options);
})()
"""

proc refActionExpression(action, refId: string): string =
  "(() => window.__ncdpAria." & action & "(" & jsString(refId) & "))()"

proc fillExpression(refId, text: string): string =
  "(() => window.__ncdpAria.fill(" & jsString(refId) & ", " & jsString(text) & "))()"

proc pressExpression(key: string): string =
  "(() => window.__ncdpAria.press(" & jsString(key) & "))()"

proc printInteractiveHelp() =
  echo ""
  echo "Interactive commands:"
  echo "  snapshot | s              print the current ARIA tree"
  echo "  click <ref>               click an element, e.g. click ne6"
  echo "  fill <ref> <text>         replace text in an input/textarea"
  echo "  press <key>               dispatch keydown/keyup on the active element"
  echo "  goto <url>                navigate and print a fresh snapshot"
  echo "  eval <javascript>         evaluate JavaScript and print its string result"
  echo "  help                      print this help"
  echo "  quit | q                  exit"
  echo ""

proc argAfter(line, command: string): string =
  line[command.len .. ^1].strip()

proc interactiveLoop(args: Args; client: CDPClient) {.
    async: (raises: [CatchableError]).} =
  printInteractiveHelp()
  while true:
    stdout.write("aria> ")
    stdout.flushFile()
    let line = try: stdin.readLine().strip()
               except EOFError: break
    if line.len == 0: continue
    if line in ["quit", "q", "exit"]: break
    if line in ["help", "h", "?"]:
      printInteractiveHelp()
      continue
    try:
      if line in ["snapshot", "s"]:
        echo await evaluateString(client, ariaTreeExpression(args))
      elif line.startsWith("click "):
        let refId = argAfter(line, "click")
        let loaded = newFuture[void]("aria-snapshot-click-navigation")
        cdpPage.onLoadEventFired(client,
          proc(p: PageLoadEventFiredParams) {.gcsafe, raises: [].} =
            if not loaded.finished:
              loaded.complete())
        discard await evaluateString(client, installAriaHelperExpression())
        echo await evaluateString(client, refActionExpression("click", refId))
        discard await loaded.withTimeout(3.seconds)
        echo await evaluateString(client, ariaTreeExpression(args))
      elif line.startsWith("fill "):
        let rest = argAfter(line, "fill")
        let splitAt = rest.find(' ')
        if splitAt < 0:
          echo "usage: fill <ref> <text>"
        else:
          let refId = rest[0 ..< splitAt]
          let text = rest[splitAt + 1 .. ^1]
          discard await evaluateString(client, installAriaHelperExpression())
          echo await evaluateString(client, fillExpression(refId, text))
          echo await evaluateString(client, ariaTreeExpression(args))
      elif line.startsWith("press "):
        discard await evaluateString(client, installAriaHelperExpression())
        echo await evaluateString(client, pressExpression(argAfter(line, "press")))
        echo await evaluateString(client, ariaTreeExpression(args))
      elif line.startsWith("goto "):
        let url = argAfter(line, "goto")
        let loaded = newFuture[void]("aria-snapshot-interactive-navigation")
        cdpPage.onLoadEventFired(client,
          proc(p: PageLoadEventFiredParams) {.gcsafe, raises: [].} =
            if not loaded.finished:
              loaded.complete())
        discard await cdpPage.navigate(client,
          url = url,
          referrer = none(string),
          transitionType = none(PageTransitionType),
          frameId = none(PageFrameId),
          referrerPolicy = none(PageReferrerPolicy))
        await waitForPageLoad(loaded)
        discard await evaluateString(client, installAriaHelperExpression())
        echo await evaluateString(client, ariaTreeExpression(args))
      elif line.startsWith("eval "):
        echo await evaluateString(client, argAfter(line, "eval"))
      else:
        echo "unknown command; type help"
    except CatchableError as e:
      echo "error: ", e.msg

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
  discard await evaluateString(client, installAriaHelperExpression())
  let tree = await evaluateString(client, ariaTreeExpression(args))
  echo tree
  if args.interactive:
    await interactiveLoop(args, client)

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
