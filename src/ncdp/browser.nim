## Small ergonomic browser/page layer over the generated CDP bindings.
##
## The raw generated modules remain available under ``cdp/gen/*``. This module
## is the recommended surface for examples and common automation scripts: it
## owns the launch/connect/new-page ceremony and keeps the generated-command
## verbosity out of user code.

import std/[json, options, strformat, syncio]
import chronos
import cdp/[chrome, jsonhooks, transport]
import cdp/gen/browser as cdpBrowser
import cdp/gen/page as cdpPage
import cdp/gen/runtime as cdpRuntime

type
  NcdpError* = object of CatchableError
    ## High-level automation error raised by the ergonomic ``ncdp/*`` layer.

  BrowserVersion* = object
    ## Browser version details returned by ``Browser.getVersion``.
    product*: string
    revision*: string
    protocolVersion*: string
    jsVersion*: string
    userAgent*: string

  Browser* = ref object
    ## A browser discovered or launched by ncdp.
    host*: string
    port*: int
    wsUrl*: string
    process: chrome.ChromeProcess
    ownsProcess: bool

  Page* = ref object
    ## A page-scoped CDP connection.
    browser*: Browser
    client*: CDPClient
      ## Escape hatch for raw generated CDP calls.
    targetId*: string
    wsUrl*: string

proc evalString*(p: Page; expression: string): Future[string] {.
    async: (raises: [CatchableError]).}
proc evalJson*(p: Page; expression: string): Future[JsonNode] {.
    async: (raises: [CatchableError]).}

proc fail(msg: string) {.noreturn.} =
  raise newException(NcdpError, msg)

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

proc launchBrowser*(opts: chrome.LaunchOptions): Future[Browser] {.
    async: (raises: [CatchableError]).} =
  ## Launch a fresh Chrome process and return a high-level browser handle.
  ##
  ## Use this overload when you need low-level launch options such as
  ## ``chromeOutput`` or ``extraArgs``. Most examples use the host/port
  ## overload below.
  let cp = await chrome.launch(opts)
  result = Browser(
    host: opts.host,
    port: opts.port,
    wsUrl: cp.wsUrl,
    process: cp,
    ownsProcess: true)

proc launchBrowser*(host = "127.0.0.1"; port = 9222): Future[Browser] {.
    async: (raises: [CatchableError]).} =
  ## Launch a headless Chrome with the default ncdp launch options.
  var opts = chrome.initLaunchOptions()
  opts.host = host
  opts.port = port
  result = await launchBrowser(opts)

proc connectBrowser*(host = "127.0.0.1"; port = 9222): Future[Browser] {.
    async: (raises: [CatchableError]).} =
  ## Connect to an already-running Chrome remote-debugging endpoint.
  let wsUrl = await chrome.discover(host, port)
  result = Browser(host: host, port: port, wsUrl: wsUrl, ownsProcess: false)

proc chromeOutput*(b: Browser): string =
  ## Buffered Chrome stdout/stderr when launched with ``coBuffer``.
  if b.process.isNil: "" else: chrome.chromeOutput(b.process)

proc version*(b: Browser): Future[BrowserVersion] {.
    async: (raises: [CatchableError]).} =
  ## Call ``Browser.getVersion`` through a short-lived browser-scope client.
  let client = await transport.connect(b.wsUrl)
  try:
    let v = await cdpBrowser.getVersion(client)
    result = BrowserVersion(
      product: v.product,
      revision: v.revision,
      protocolVersion: v.protocolVersion,
      jsVersion: v.jsVersion,
      userAgent: v.userAgent)
  finally:
    await transport.close(client)

proc newPage*(b: Browser; url = "about:blank"): Future[Page] {.
    async: (raises: [CatchableError]).} =
  ## Open a new page target and connect a page-scoped CDP client.
  let tab = await chrome.newTabInfo(b.host, b.port, url)
  var client: CDPClient = nil
  try:
    client = await transport.connect(tab.wsUrl)
    await cdpPage.enable(client, enableFileChooserOpenedEvent = none(bool))
  except CatchableError as e:
    if not client.isNil:
      try: await transport.close(client)
      except CatchableError: discard
    try: await chrome.closeTab(b.host, b.port, tab.id)
    except CatchableError: discard
    raise e
  result = Page(browser: b, client: client, targetId: tab.id, wsUrl: tab.wsUrl)

proc waitForNavigationReady(p: Page; oldHref: string;
                            timeout: Duration): Future[void] {.
    async: (raises: [CatchableError]).} =
  let deadline = Moment.now() + timeout
  var lastErr = ""
  while Moment.now() < deadline:
    try:
      let state = await p.evalJson("""
(() => ({
  readyState: document.readyState,
  href: location.href,
  oldMarker: window.__ncdpGotoMarker === true,
}))()
""")
      if state.kind == JObject:
        let readyNode = state.getOrDefault("readyState")
        let hrefNode = state.getOrDefault("href")
        let markerNode = state.getOrDefault("oldMarker")
        let ready = if readyNode.isNil or readyNode.kind != JString: ""
                    else: readyNode.getStr()
        let href = if hrefNode.isNil or hrefNode.kind != JString: ""
                   else: hrefNode.getStr()
        let oldMarker = not markerNode.isNil and markerNode.kind == JBool and
                        markerNode.getBool()
        if ready == "complete" and (not oldMarker or href != oldHref):
          return
    except CatchableError as e:
      lastErr = e.msg
    await sleepAsync(50.milliseconds)
  fail(&"page load timed out after {timeout}" &
       (if lastErr.len > 0: " (last error: " & lastErr & ")" else: ""))

proc goto*(p: Page; url: string; timeout = 10.seconds): Future[void] {.
    async: (raises: [CatchableError]).} =
  ## Navigate and wait for the new document to reach ``document.readyState ==
  ## "complete"``. Same-document URL changes complete once ``location.href``
  ## changes.
  if p.client.isNil:
    fail("page is closed")
  let oldHref = await p.evalString(
    "window.__ncdpGotoMarker = true; location.href")
  let nav = await cdpPage.navigate(p.client,
    url = url,
    referrer = none(string),
    transitionType = none(PageTransitionType),
    frameId = none(PageFrameId),
    referrerPolicy = none(PageReferrerPolicy))
  if nav.errorText.isSome:
    fail("navigation failed: " & nav.errorText.get)
  await p.waitForNavigationReady(oldHref, timeout)

proc goBack*(p: Page; timeout = 10.seconds): Future[bool] {.
    async: (raises: [CatchableError]).} =
  ## Navigate one entry back in page history. Returns ``false`` when there is no
  ## previous entry.
  if p.client.isNil:
    fail("page is closed")
  let history = await cdpPage.getNavigationHistory(p.client)
  let targetIndex = history.currentIndex - 1
  if targetIndex < 0:
    return false
  let oldHref = await p.evalString(
    "window.__ncdpGotoMarker = true; location.href")
  await cdpPage.navigateToHistoryEntry(p.client,
    history.entries[targetIndex].id)
  await p.waitForNavigationReady(oldHref, timeout)
  result = true

proc reload*(p: Page; ignoreCache = false; timeout = 10.seconds): Future[void] {.
    async: (raises: [CatchableError]).} =
  ## Reload the current page and wait for the new document to become ready.
  if p.client.isNil:
    fail("page is closed")
  let oldHref = await p.evalString(
    "window.__ncdpGotoMarker = true; location.href")
  await cdpPage.reload(p.client,
    ignoreCache = some(ignoreCache),
    scriptToEvaluateOnLoad = none(string),
    loaderId = none(NetworkLoaderId))
  await p.waitForNavigationReady(oldHref, timeout)

proc evalJson*(p: Page; expression: string): Future[JsonNode] {.
    async: (raises: [CatchableError]).} =
  ## Evaluate JavaScript and return the by-value JSON result.
  if p.client.isNil:
    fail("page is closed")
  let r = await cdpRuntime.evaluate(p.client,
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
    fail("Runtime.evaluate threw:\n" & exceptionMessage(r.exceptionDetails.get))
  if r.result.value.isSome:
    result = r.result.value.get
  else:
    result = newJNull()

proc evalString*(p: Page; expression: string): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Evaluate JavaScript and coerce the by-value result to a Nim string.
  let value = await p.evalJson(expression)
  result = if value.kind == JString: value.getStr() else: $value

proc screenshotBytes*(p: Page): Future[seq[byte]] {.
    async: (raises: [CatchableError]).} =
  ## Capture a PNG screenshot and return raw bytes.
  if p.client.isNil:
    fail("page is closed")
  let shot = await cdpPage.captureScreenshot(p.client,
    format = some(PageCaptureScreenshotParamsFormat.Png),
    quality = none(int),
    clip = none(PageViewport),
    fromSurface = some(true),
    captureBeyondViewport = none(bool),
    optimizeForSpeed = some(true))
  result = shot.data.bytes

proc screenshot*(p: Page; path: string): Future[void] {.
    async: (raises: [CatchableError]).} =
  ## Capture a PNG screenshot and write it to ``path``.
  let raw = await p.screenshotBytes()
  var bytes = newString(raw.len)
  for i in 0 ..< raw.len:
    bytes[i] = char(raw[i])
  writeFile(path, bytes)

proc close*(p: Page): Future[void] {.
    async: (raises: [CancelledError]).} =
  ## Close the page target and its websocket client. Idempotent.
  if p.isNil or p.client.isNil: return
  let client = p.client
  p.client = nil
  try: await chrome.closeTab(p.browser.host, p.browser.port, p.targetId)
  except CancelledError as e: raise e
  except CatchableError: discard
  try: await transport.close(client)
  except CancelledError as e: raise e
  except CatchableError: discard

proc close*(b: Browser): Future[void] {.
    async: (raises: [CancelledError]).} =
  ## Close a browser launched by ncdp. Discovered browsers are left running.
  if b.isNil or b.process.isNil: return
  if b.ownsProcess:
    await chrome.terminate(b.process)
  b.process = nil
