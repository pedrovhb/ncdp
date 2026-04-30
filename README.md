# ncdp

> **Pre-alpha:** this library is not production-ready yet. APIs and
> behavior may change without notice until the first stable release.

Nim bindings for the Chrome DevTools Protocol (CDP).

The project has three pieces:

- A PDL parser for Chrome's protocol grammar files under `src/gen/pdl/`.
- A small CDP runtime under `src/cdp/` for launching Chrome, opening websocket connections, sending commands, and receiving events.
- A code generator under `src/gen/cdp/` that emits one domain module per CDP domain plus a shared generated type module under `src/cdp/gen/`.

Generated bindings use Chronos futures and map CDP optional fields to `Option[T]`.

**Requirements**
- Nim `>= 2.2.8`.
- Chrome or Chromium on `PATH`, or `NCDP_CHROME=/path/to/chrome`.
- `nws_client`, installed by Nimble from its GitHub repository.

**Quickstart**
Generate the CDP domain bindings:

```sh
nimble gen
```

Run the test suite:

```sh
nimble test
```

Compile the numbered examples without running Chrome:

```sh
nimble examples
```

Generate local API docs into `htmldocs/`:

```sh
nimble docs
```

The docs task currently covers the parser barrel plus transport/json helpers.
`cdp/chrome.nim` and high-level modules that import it trip Nim's doc
generator on Chronos `asyncproc` symbols on this toolchain even though the
modules compile normally.

Call `Browser.getVersion` against a launched Chrome:

```sh
nim c -d:ssl -r examples/ex_01_browser_get_version.nim
```

Use an already-running Chrome that was started with remote debugging enabled:

```sh
chromium --remote-debugging-port=9222 --user-data-dir=/tmp/ncdp-profile
nim c -d:ssl -r examples/ex_01_browser_get_version.nim -- --discover
```

**Minimal Example**
```nim
import chronos
import ncdp/browser

proc main() {.async.} =
  let br = await launchBrowser()
  try:
    let version = await br.version()
    echo version.product
    echo version.protocolVersion
  finally:
    await br.close()

waitFor main()
```

**Page-Scoped Workflow**
The recommended page workflow uses the small high-level `ncdp/browser` facade:

```nim
let br = await launchBrowser()
let page = await br.newPage()
await page.goto("https://example.com")
echo await page.evalString("document.title")
await page.screenshot("/tmp/ncdp-screenshot.png")
await page.close()
await br.close()
```

The raw page-target ceremony is still available in `examples/raw/` for people
who want to see the generated CDP calls directly.

**Chrome Output**
`chrome.launch()` captures and discards Chrome stdout/stderr by default so unrelated browser diagnostics do not pollute example output. Set `LaunchOptions.chromeOutput` to `coInherit` to let Chrome write to the parent terminal, or `coBuffer` to capture output and read it with `chromeOutput(process)` after termination.

**Examples**
The top-level numbered examples are the recommended, latest-and-greatest path:

- `examples/ex_01_browser_get_version.nim`: launch/discover Chrome and call `Browser.getVersion` through the high-level browser facade.
- `examples/ex_02_page_goto_eval_screenshot.nim`: open a page, navigate, evaluate JavaScript, and capture a screenshot through the Page facade.
- `examples/ex_03_aria_snapshot.nim`: print an AI-friendly Markdown view by default; ARIA snapshots remain available with the `aria`/`snapshot` command, and `--full-page` restores full-page source content. `--interactive` starts a stdin REPL that can `click`, `fill`, `set`, `select`, `press`, `goto`, and inspect refs.

Raw generated-CDP examples live under `examples/raw/` and keep their numbering:

- `examples/raw/ex_01_parse_summary.nim`: parse the vendored PDL files and print a protocol summary.
- `examples/raw/ex_02_call_browser_getVersion.nim`: launch/discover Chrome and call generated `Browser.getVersion` directly.
- `examples/raw/ex_03_browser_via_codegen.nim`: call generated browser and target bindings.
- `examples/raw/ex_04_navigate_eval_screenshot.nim`: open a page target, navigate, evaluate JavaScript, and capture a screenshot with raw generated calls.
- `examples/raw/ex_05_aria_snapshot.nim`: the original raw generated-CDP ARIA snapshot example.

`examples/ariaSnapshot.js` is a bundled compiled copy of Playwright's ARIA snapshot helper used by `ncdp/aria` and the raw ARIA example.

**ARIA Snapshot Example**
```sh
nim c -d:ssl -r examples/ex_03_aria_snapshot.nim -- --url=https://example.com
nim c -d:ssl -r examples/ex_03_aria_snapshot.nim -- --url=https://example.com --full-page
nim c -d:ssl -r examples/ex_03_aria_snapshot.nim -- --url=https://example.com --interactive
```

The default view is Markdown converted from Mozilla Readability's reduced HTML,
with ARIA as the fallback if Markdown conversion returns no content. Forms and
common controls are preserved in reduced views as explicit field descriptions
where possible. Use `--full-page` for browser automation workflows that need
controls outside the detected article, or for pages where Readability falls
back too aggressively.

The high-level ARIA module can also convert the same readable HTML view to
Markdown via a bundled rehype/remark pipeline:

```nim
echo await page.readableMarkdown()
```

Interactive commands:

```text
view | v                  print the default Markdown view
aria | snapshot | s       print the current ARIA tree
click <ref>               click an element, e.g. click ne6
fill <ref> <text>         replace text in an input/textarea
set <ref> <value>         set number/date/time/range/color inputs
select <ref> <value>      select an option by value or label
press <key>               send real CDP keyboard input, e.g. Tab or F5
goto <url>                navigate and print a fresh Markdown view
back | b                  go back and print a fresh Markdown view
reload | r                reload and print a fresh Markdown view
screenshot | ss <path>    capture a PNG screenshot
wait <ms>                 sleep for a number of milliseconds
waitFor <text>            wait until body text contains text
refs | actions            list refs and supported actions
links                     list links detected on the page
markdown | md             print Readability/full-page HTML as Markdown
console | logs | c        print console messages and page errors
clearconsole | cc         clear the console message buffer
eval <javascript>         evaluate JavaScript and print its string result
quit | q                  exit
```

**Generated Modules**
The generator writes ignored files under `src/cdp/gen/`:

- `types.nim`: shared generated types for every emitted domain. This avoids cross-domain import cycles.
- `<domain>.nim`: generated commands and event listener helpers for one CDP domain.

Type names are domain-prefixed in the shared type module, for example `Network.RequestId` becomes `NetworkRequestId`. Pure enums use qualified PascalCase members, for example `PageTransitionType.Link`.

**Troubleshooting**
See `docs/troubleshooting.md` for Chrome binary discovery, generated-module setup, noisy Chrome stderr, CSP/evaluation notes, and port conflicts.
