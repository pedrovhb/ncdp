# ncdp

Nim bindings for the Chrome DevTools Protocol (CDP).

The project has three pieces:

- A PDL parser for Chrome's protocol grammar files under `src/gen/pdl/`.
- A small CDP runtime under `src/cdp/` for launching Chrome, opening websocket connections, sending commands, and receiving events.
- A code generator under `src/gen/cdp/` that emits one domain module per CDP domain plus a shared generated type module under `src/cdp/gen/`.

Generated bindings use Chronos futures and map CDP optional fields to `Option[T]`.

**Requirements**
- Nim `>= 2.2.8`.
- Chrome or Chromium on `PATH`, or `NCDP_CHROME=/path/to/chrome`.
- `nws_client` available via the local path configured in `config.nims`.
- On some NixOS systems, binaries that load OpenSSL need `LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib`.

**Quickstart**
Generate the CDP domain bindings:

```sh
nimble gen
```

Run the test suite:

```sh
nimble test
```

Call `Browser.getVersion` against a launched Chrome:

```sh
nim c -d:ssl -r examples/gen/ex_02_call_browser_getVersion.nim
```

Use an already-running Chrome that was started with remote debugging enabled:

```sh
chromium --remote-debugging-port=9222 --user-data-dir=/tmp/ncdp-profile
nim c -d:ssl -r examples/gen/ex_02_call_browser_getVersion.nim -- --discover
```

**Minimal Example**
```nim
import chronos
import cdp/[chrome, transport]
import cdp/gen/browser

proc main() {.async.} =
  let cp = await chrome.launch()
  try:
    let client = await transport.connect(cp.wsUrl)
    try:
      let version = await client.getVersion()
      echo version.product
      echo version.protocolVersion
    finally:
      await client.close()
  finally:
    await cp.terminate()

waitFor main()
```

**Page-Scoped Workflow**
Browser-level commands such as `Browser.getVersion` run against `ChromeProcess.wsUrl`. Page domains such as `Page`, `Runtime`, `DOM`, and `Accessibility` need a page target websocket:

```nim
let host = "127.0.0.1"
let port = 9222
var opts = chrome.initLaunchOptions()
opts.host = host
opts.port = port
let cp = await chrome.launch(opts)
let pageWsUrl = await chrome.newTab(host, port, "about:blank")
let client = await transport.connect(pageWsUrl)
```

In examples, this is written out explicitly with `host` and `port` arguments. See `examples/gen/ex_04_navigate_eval_screenshot.nim` for a full page navigation flow.

**Examples**
- `examples/gen/ex_01_parse_summary.nim`: parse the vendored PDL files and print a protocol summary.
- `examples/gen/ex_02_call_browser_getVersion.nim`: launch/discover Chrome and call `Browser.getVersion`.
- `examples/gen/ex_03_browser_via_codegen.nim`: call generated browser and target bindings.
- `examples/gen/ex_04_navigate_eval_screenshot.nim`: open a page target, navigate, evaluate JavaScript, and capture a screenshot.
- `examples/gen/ex_05_aria_snapshot.nim`: inject the bundled Playwright ARIA snapshot helper and print an AI-friendly ARIA tree; `--interactive` starts a small stdin REPL that can `click`, `fill`, `press`, `goto`, and `snapshot` using ARIA refs.

`examples/ariaSnapshot.js` is a bundled compiled copy of Playwright's ARIA snapshot helper used by `ex_05_aria_snapshot.nim`.

**ARIA Snapshot Example**
```sh
nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --url=https://example.com
nim c -d:ssl -r examples/gen/ex_05_aria_snapshot.nim -- --url=https://example.com --interactive
```

Interactive commands:

```text
snapshot | s              print the current ARIA tree
click <ref>               click an element, e.g. click ne6
fill <ref> <text>         replace text in an input/textarea
press <key>               dispatch keydown/keyup on the active element
goto <url>                navigate and print a fresh snapshot
eval <javascript>         evaluate JavaScript and print its string result
quit | q                  exit
```

**Generated Modules**
The generator writes ignored files under `src/cdp/gen/`:

- `types.nim`: shared generated types for every emitted domain. This avoids cross-domain import cycles.
- `<domain>.nim`: generated commands and event listener helpers for one CDP domain.

Type names are domain-prefixed in the shared type module, for example `Network.RequestId` becomes `NetworkRequestId`. Pure enums use qualified PascalCase members, for example `PageTransitionType.Link`.

**Troubleshooting**
See `docs/troubleshooting.md` for Chrome binary discovery, NixOS OpenSSL, generated-module setup, noisy Chrome stderr, CSP/evaluation notes, and port conflicts.
