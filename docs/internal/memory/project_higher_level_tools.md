---
name: Higher-level tools over generated CDP
description: Direction for building ergonomic Browser/Page/ARIA APIs on top of the generated raw CDP surface.
type: project
---

The generated CDP modules are the foundation, not the final user experience.
They should stay complete, typed, close to the protocol, and predictable. On
top of them, `ncdp` should grow a small higher-level layer for common browser
automation tasks.

The key boundary: generated modules expose **raw protocol verbs**;
higher-level tools expose **browser automation intentions**.

Initial slice exists under `src/ncdp/`:

* `browser.nim` — `Browser`/`Page`, launch/discover, `newPage`, `goto`,
  `evalJson`/`evalString`, screenshots, and cleanup.
* `aria.nim` — bundled ARIA helper injection, `ariaSnapshot`, `clickRef`,
  `fillRef`, `setRef`, `selectRef`, `press`, action-oriented ref
  enumeration, and link enumeration.

The top-level numbered examples use these modules. The old generated-CDP
examples moved to `examples/raw/` as reference specimens.

## Shape to aim for

Start with a minimal Browser/Page facade:

```nim
type
  Browser* = ref object
  Page* = ref object

proc launchBrowser*(): Future[Browser]
proc newPage*(b: Browser; url = "about:blank"): Future[Page]
proc goto*(p: Page; url: string): Future[void]
proc evalString*(p: Page; expression: string): Future[string]
proc ariaSnapshot*(p: Page; depth = 0): Future[string]
proc close*(p: Page): Future[void]
proc close*(b: Browser): Future[void]
```

Example user shape:

```nim
let browser = await launchBrowser()
let page = await browser.newPage()
await page.goto("https://example.com")
echo await page.evalString("document.title")
echo await page.ariaSnapshot(depth = 3)
await browser.close()
```

Internally this wraps the existing low-level pieces:

* `chrome.launch`
* `chrome.newTab`
* `transport.connect`
* generated `Page.*`, `Runtime.*`, `Input.*`, etc.
* target cleanup

## Proposed layers

### 1. Browser / Page lifecycle

Own page-scoped CDP clients and hide target creation:

```nim
let browser = await launchBrowser()
let page = await browser.newPage()
await page.close()
await browser.close()
```

This layer should remember host/port, browser process ownership, page target
IDs, and websocket clients. It should distinguish launched browsers from
discovered browsers so `close(browser)` only kills processes it owns.

### 2. Navigation and waiting

Provide reliable waits instead of asking users to hand-wire events:

```nim
await page.goto("https://developer.mozilla.org/", waitUntil = Load)
await page.waitForSelector("main")
await page.waitForUrl(contains = "mozilla")
```

This coordinates `Page.navigate`, `Page.loadEventFired`, lifecycle events,
timeouts, and possibly DOM polling via `Runtime.evaluate`.

Keep this boring at first: load-event wait plus timeout is enough. Do not try
to clone Playwright's full auto-waiting semantics in the first pass.

### 3. Evaluation helpers

Centralize `Runtime.evaluate` ceremony:

```nim
let title = await page.evalString("document.title")
let count = await page.evalInt("document.querySelectorAll('a').length")
let data = await page.evalJson("""() => ({ title: document.title })""")
```

This layer should consistently set `returnByValue = true` and
`awaitPromise = true`, format `exceptionDetails`, and extract JSON values.

### 4. Input layer

Eventually, actions should use CDP-native input dispatch rather than DOM
`.click()` or synthetic keyboard events:

```nim
await page.click("text=Learn more")
await page.fill("input[name=email]", "ada@example.com")
await page.press("Enter")
```

This likely wraps:

* DOM querying / element resolution
* scroll into view
* bounding-box calculation
* `Input.dispatchMouseEvent`
* `Input.dispatchKeyEvent`
* visibility and detached-node checks

The current ARIA example's DOM-level `.click()` is useful as a prototype but
should not be the final action semantics.

### 5. ARIA / AI layer

Promote the ARIA snapshot example into reusable APIs:

```nim
let tree = await page.ariaSnapshot(depth = 3)
echo tree.text

await page.clickRef("ne6")
await page.fillRef("ne12", "ada@example.com")
await page.setRef("ne20", "2026-04-29")
discard await page.selectRef("ne22", "Afternoon")
```

This is the most distinctive angle for model/agent use:

* compact accessibility-tree observation
* ref-based actions
* machine-readable ref actions for autocomplete and constrained generation
* action-result-observation loop
* optional diff snapshots
* less DOM/CSS noise than raw HTML

The refs are snapshot-relative. Navigation or major DOM churn invalidates old
refs; the API should make this explicit and encourage `snapshot → act →
snapshot` loops.

### 6. Screenshots and artifacts

Convenience wrappers around binary CDP results:

```nim
await page.screenshot("/tmp/page.png")
let png = await page.screenshotBytes()
```

This wraps `Page.captureScreenshot` and the `Binary` JSON hook.

### 7. Network / console / tracing later

Useful, but not first:

```nim
page.onRequest(proc(req: Request) = ...)
page.onConsole(proc(msg: ConsoleMessage) = ...)
await page.route("**/api/**", handler)
```

These require more state management, request interception, and event routing.
Defer until Browser/Page lifecycle and eval/navigation are solid.

## Possible module layout

Keep raw protocol and ergonomic tools visually separate.

Option A:

```text
src/cdp/
  chrome.nim              # current low-level launcher
  transport.nim           # current low-level transport
  jsonhooks.nim
  gen/                    # generated raw CDP bindings

src/ncdp/
  browser.nim             # high-level Browser/Page lifecycle
  page.nim                # navigation/eval/screenshot/input
  aria.nim                # ARIA snapshot + ref actions
  wait.nim                # timeout/retry/wait utilities
  errors.nim              # high-level error types
```

Option B:

```text
src/cdp/tools/page.nim
src/cdp/tools/aria.nim
src/cdp/tools/input.nim
```

The better default is probably `src/ncdp/` for high-level APIs and `src/cdp/`
for raw protocol/runtime. That makes import intent clear:

* `import cdp/gen/page` — raw generated CDP
* `import ncdp/page` — ergonomic automation layer

## First implementation slice

Do not start with a framework. Start with the smallest layer that makes the
examples collapse into reusable API calls:

1. `Browser` owns a launched or discovered browser.
2. `Page` owns a page target websocket and `CDPClient`.
3. `newPage` opens a target and connects to it.
4. `goto` navigates and waits for load.
5. `evalString` wraps `Runtime.evaluate` with good exception messages.
6. `ariaSnapshot` reuses the bundled helper from `examples/ariaSnapshot.js` or
   moves that helper into a resource module.
7. `close` cleans up page/client/browser process in ownership order.

Once that exists, revisit input and ARIA ref actions with CDP-native dispatch.
