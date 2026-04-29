## ex_03_aria_snapshot — high-level ARIA observe/action loop.
##
## Prints a Playwright-style ARIA tree and optionally starts a tiny REPL that
## acts on snapshot refs.
##
## Usage::
##
##   nim c -d:ssl -r examples/ex_03_aria_snapshot.nim
##   nim c -d:ssl -r examples/ex_03_aria_snapshot.nim -- --url=https://example.com
##   nim c -d:ssl -r examples/ex_03_aria_snapshot.nim -- --interactive

import std/[base64, json, options, parseopt, strformat, strutils, syncio]
import chronos
import cdp/gen/runtime as cdpRuntime
import ncdp/browser
import ncdp/aria

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

  ConsoleBuffer = ref object
    entries: seq[string]

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
      <label>Quantity <input name="quantity" type="number" min="1" max="10" value="1"></label>
      <label>Delivery date <input name="delivery" type="date" value="2026-04-29"></label>
      <label>Delivery window
        <select name="window">
          <option value="morning">Morning</option>
          <option value="afternoon" selected>Afternoon</option>
          <option value="evening">Evening</option>
        </select>
      </label>
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
  result = "data:text/html;charset=utf-8;base64," & base64.encode(SampleHtml)

proc parseArgs(): Args =
  result = Args(mode: mLaunch, host: "127.0.0.1", port: 9222,
                url: sampleUrl(), depth: 0, boxes: false)
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      if p.key.len == 0: continue # separator from ``nim c -r file -- ...``
      case p.key
      of "discover", "d": result.mode = mDiscover
      of "launch", "l": result.mode = mLaunch
      of "host": result.host = p.val
      of "port": result.port = parseInt(p.val)
      of "url": result.url = p.val
      of "depth": result.depth = parseInt(p.val)
      of "boxes": result.boxes = true
      of "interactive", "i": result.interactive = true
      of "help", "h":
        echo "usage: ex_03 [--launch|--discover] [--host=H] [--port=N] " &
             "[--url=URL] [--depth=N] [--boxes] [--interactive]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc openBrowser(args: Args): Future[Browser] {.
    async: (raises: [CatchableError]).} =
  case args.mode
  of mLaunch:
    result = await launchBrowser(args.host, args.port)
  of mDiscover:
    result = await connectBrowser(args.host, args.port)

proc displayUrl(url: string): string =
  const MaxUrl = 160
  if url.len <= MaxUrl:
    result = url
  else:
    result = url[0 ..< MaxUrl] & "..."

proc printSnapshot(page: Page; args: Args) {.
    async: (raises: [CatchableError]).} =
  let info = await page.evalJson("""
(() => ({ url: location.href, title: document.title }))()
""")
  if info.kind == JObject:
    let urlNode = info.getOrDefault("url")
    let titleNode = info.getOrDefault("title")
    let url = if urlNode.isNil or urlNode.kind != JString: "" else: urlNode.getStr()
    let title = if titleNode.isNil or titleNode.kind != JString: "" else: titleNode.getStr()
    echo &"url:   {displayUrl(url)}"
    echo &"title: {title}"
  echo await page.ariaSnapshot(depth = args.depth, boxes = args.boxes)

proc printInteractiveHelp() =
  echo ""
  echo "Interactive commands:"
  echo "  snapshot | s              print the current ARIA tree"
  echo "  click <ref>               click an element, e.g. click n6"
  echo "  fill <ref> <text>         replace text in an input/textarea"
  echo "  set <ref> <value>         set number/date/time/range/color inputs"
  echo "  select <ref> <value>      select an option by value or label"
  echo "  press <key>               send real CDP keyboard input, e.g. Tab or F5"
  echo "  goto <url>                navigate and print a fresh snapshot"
  echo "  back | b                  go back and print a fresh snapshot"
  echo "  reload | r                reload and print a fresh snapshot"
  echo "  screenshot | ss <path>    capture a PNG screenshot"
  echo "  wait <ms>                 sleep for a number of milliseconds"
  echo "  waitFor <text>            wait until body text contains text"
  echo "  refs | actions            list refs and supported actions"
  echo "  links                     list links detected on the page"
  echo "  console | logs | c        print console messages and page errors"
  echo "  clearconsole | cc         clear the console message buffer"
  echo "  eval <javascript>         evaluate JavaScript and print its string result"
  echo "  help                      print this help"
  echo "  quit | q                  exit"
  echo ""

proc argAfter(line, command: string): string =
  result = line[command.len .. ^1].strip()

proc remoteObjectText(arg: RuntimeRemoteObject): string =
  if arg.value.isSome:
    let value = arg.value.get
    if value.kind == JString:
      return value.getStr()
    return $value
  if arg.unserializableValue.isSome:
    return arg.unserializableValue.get
  if arg.description.isSome:
    return arg.description.get
  result = $arg.`type`

proc formatConsoleMessage(params: RuntimeConsoleApiCalledParams): string =
  var parts: seq[string]
  for arg in params.args:
    parts.add remoteObjectText(arg)
  result = "[" & $params.`type` & "] " & parts.join(" ")
  if params.stackTrace.isSome:
    let trace = params.stackTrace.get
    if trace.callFrames.len > 0:
      let frame = trace.callFrames[0]
      result.add " (" & frame.url & ":" & $(frame.lineNumber + 1) & ")"

proc formatException(details: RuntimeExceptionDetails): string =
  result = "[Exception] " & details.text
  if details.exception.isSome:
    result.add ": " & remoteObjectText(details.exception.get)
  if details.url.isSome:
    result.add " (" & details.url.get & ":" & $(details.lineNumber + 1) & ")"
  elif details.stackTrace.isSome and details.stackTrace.get.callFrames.len > 0:
    let frame = details.stackTrace.get.callFrames[0]
    result.add " (" & frame.url & ":" & $(frame.lineNumber + 1) & ")"

proc enableConsoleCapture(page: Page): Future[ConsoleBuffer] {.
    async: (raises: [CatchableError]).} =
  result = ConsoleBuffer()
  await cdpRuntime.enable(page.client)
  let buffer = result
  cdpRuntime.onConsoleAPICalled(page.client,
    proc(params: RuntimeConsoleApiCalledParams) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        {.cast(raises: []).}:
          buffer.entries.add formatConsoleMessage(params))
  cdpRuntime.onExceptionThrown(page.client,
    proc(params: RuntimeExceptionThrownParams) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        {.cast(raises: []).}:
          buffer.entries.add formatException(params.exceptionDetails))

proc printConsole(buffer: ConsoleBuffer) =
  if buffer.entries.len == 0:
    echo "(no console messages)"
  else:
    for entry in buffer.entries:
      echo entry

proc actionName(action: AriaAction): string =
  result = action.name
  if result.len == 0:
    case action.kind
    of AriaActionKind.Click: result = "click"
    of AriaActionKind.Fill: result = "fill"
    of AriaActionKind.Set: result = "set"
    of AriaActionKind.Select: result = "select"
    of AriaActionKind.Check: result = "check"
    of AriaActionKind.Uncheck: result = "uncheck"

proc actionKinds(item: AriaActionRef): string =
  var parts: seq[string]
  for action in item.actions:
    parts.add actionName(action)
  result = parts.join(",")

proc printActionRefs(page: Page; args: Args) {.
    async: (raises: [CatchableError]).} =
  let refs = await page.actionRefs(
    initAriaOptions(depth = args.depth, boxes = args.boxes))
  if refs.len == 0:
    echo "(no actionable refs)"
    return
  for item in refs:
    echo item.refId.alignLeft(6), " ", actionKinds(item).alignLeft(16), " ",
         item.role.alignLeft(12), " ", item.label
    if item.selectOptions.len > 0:
      var options: seq[string]
      for option in item.selectOptions:
        let marker = if option.selected: "*" else: ""
        options.add marker & option.label & "=" & option.value
      echo "      options: ", options.join(", ")

proc printLinks(page: Page; args: Args) {.
    async: (raises: [CatchableError]).} =
  let links = await page.links(
    initAriaOptions(depth = args.depth, boxes = args.boxes))
  if links.len == 0:
    echo "(no links)"
    return
  for link in links:
    let refLabel = if link.refId.len == 0: "-" else: link.refId
    echo refLabel.alignLeft(6), link.text.alignLeft(24), displayUrl(link.href)

proc waitForText(page: Page; text: string; timeout = 10.seconds) {.
    async: (raises: [CatchableError]).} =
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    let found = await page.evalJson("""
((needle) => (document.body?.innerText || '').includes(needle))
""" & "(" & $(%text) & ")")
    if found.kind == JBool and found.getBool(): return
    await sleepAsync(100.milliseconds)
  raise newException(NcdpError, "timed out waiting for text: " & text)

proc pathArg(line, command: string): string =
  result = argAfter(line, command)
  if result.len == 0:
    raise newException(NcdpError, "usage: " & command.strip() & " <path>")

proc interactiveLoop(page: Page; args: Args) {.
    async: (raises: [CatchableError]).} =
  let console = await enableConsoleCapture(page)
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
      let lower = line.toLowerAscii()
      if lower in ["snapshot", "s"]:
        await printSnapshot(page, args)
      elif lower.startsWith("click "):
        echo await page.clickRef(argAfter(line, "click"))
        await sleepAsync(300.milliseconds)
        await printSnapshot(page, args)
      elif lower.startsWith("fill "):
        let rest = argAfter(line, "fill")
        let splitAt = rest.find(' ')
        if splitAt < 0:
          echo "usage: fill <ref> <text>"
        else:
          echo await page.fillRef(rest[0 ..< splitAt], rest[splitAt + 1 .. ^1])
          await printSnapshot(page, args)
      elif lower.startsWith("set "):
        let rest = argAfter(line, "set")
        let splitAt = rest.find(' ')
        if splitAt < 0:
          echo "usage: set <ref> <value>"
        else:
          echo await page.setRef(rest[0 ..< splitAt], rest[splitAt + 1 .. ^1])
          await printSnapshot(page, args)
      elif lower.startsWith("select "):
        let rest = argAfter(line, "select")
        let splitAt = rest.find(' ')
        if splitAt < 0:
          echo "usage: select <ref> <value>"
        else:
          let values = await page.selectRef(rest[0 ..< splitAt], rest[splitAt + 1 .. ^1])
          echo "selected: ", values.join(", ")
          await printSnapshot(page, args)
      elif lower.startsWith("press "):
        echo await page.press(argAfter(line, "press"))
        await sleepAsync(300.milliseconds)
        await printSnapshot(page, args)
      elif lower.startsWith("goto "):
        await page.goto(argAfter(line, "goto"))
        await printSnapshot(page, args)
      elif lower in ["back", "b"]:
        if await page.goBack():
          await printSnapshot(page, args)
        else:
          echo "no previous history entry"
      elif lower in ["reload", "r"]:
        await page.reload()
        await printSnapshot(page, args)
      elif lower.startsWith("screenshot "):
        let path = pathArg(line, "screenshot")
        await page.screenshot(path)
        echo "screenshot: ", path
      elif lower.startsWith("ss "):
        let path = pathArg(line, "ss")
        await page.screenshot(path)
        echo "screenshot: ", path
      elif lower.startsWith("wait "):
        let ms = parseInt(argAfter(line, "wait"))
        await sleepAsync(ms.milliseconds)
        await printSnapshot(page, args)
      elif lower.startsWith("waitfor "):
        let text = line["waitFor".len .. ^1].strip()
        await waitForText(page, text)
        await printSnapshot(page, args)
      elif lower in ["refs", "actions"]:
        await printActionRefs(page, args)
      elif lower == "links":
        await printLinks(page, args)
      elif lower in ["console", "logs", "c"]:
        printConsole(console)
      elif lower in ["clearconsole", "cc"]:
        console.entries.setLen(0)
        echo "console buffer cleared"
      elif lower.startsWith("eval "):
        echo await page.evalString(argAfter(line, "eval"))
      else:
        echo "unknown command; type help"
    except CatchableError as e:
      echo "error: ", e.msg

proc main() {.async: (raises: [CatchableError]).} =
  let args = parseArgs()
  let br = await openBrowser(args)
  try:
    let page = await br.newPage()
    try:
      await page.goto(args.url)
      await printSnapshot(page, args)
      if args.interactive:
        await interactiveLoop(page, args)
    finally:
      await page.close()
  finally:
    await br.close()

when isMainModule:
  waitFor main()
