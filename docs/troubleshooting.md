# Troubleshooting

Common issues when building or running `ncdp` examples.

**Chrome Binary Not Found**
`chrome.launch()` searches in this order:

- `LaunchOptions.executable`
- `NCDP_CHROME`
- common Chrome/Chromium names on `PATH`

Set the environment variable when Chrome is installed in a non-standard location:

```sh
export NCDP_CHROME=/path/to/chrome
```

**Remote Debugging Port Already In Use**
The default examples use `127.0.0.1:9222`. If another Chrome instance is already using that port, pass another port:

```sh
nim c -r examples/ex_01_browser_get_version.nim -- --port=9333
```

For `--discover`, start Chrome yourself with the same port:

```sh
chromium --remote-debugging-port=9333 --user-data-dir=/tmp/ncdp-profile
nim c -r examples/ex_01_browser_get_version.nim -- --discover --port=9333
```

**Generated Modules Missing**
Examples that import `cdp/gen/...` require generated files under `src/cdp/gen/`. That directory is ignored by Git because it is derived from the vendored PDL files.

Generate it with:

```sh
nimble gen
```

`nimble gen` is the explicit regeneration entrypoint. `nimble examples` expects
the generated modules to exist before compiling examples that import
`cdp/gen/...` directly.

**API Docs**
Generate local API docs with:

```sh
nimble docs
```

The output directory is `htmldocs/` and is ignored by Git.

The docs task intentionally skips `cdp/chrome.nim` and the high-level modules
that import it for now because Nim doc trips over Chronos' `asyncproc` process
symbols on this toolchain. The modules still compile normally and are covered
by `nimble examples`.

**Chrome `webSocketDebuggerUrl` Missing The Port**
Chrome builds `webSocketDebuggerUrl` from the HTTP request's `Host:` header. Some HTTP clients normalize `Host:` in a way that drops the port. `cdp/chrome.discover` and `cdp/chrome.launch` rewrite the websocket authority back to the host and port they actually contacted, so prefer those helpers over using `/json/version` manually.

**Noisy Chrome Stderr**
Chrome can write unrelated diagnostics such as GCM registration errors, GPU adapter messages, and Vulkan/WebGPU warnings to stderr. Some of these are emitted before Chrome's logging system initializes, so `--log-level` alone is not enough.

`chrome.launch()` captures launched Chrome stdout/stderr into a pipe and drains it silently by default, and also passes `--disable-logging` and `--log-level=3`. Draining is important: if output is captured but not read, Chrome can block on a full pipe.

Use `LaunchOptions.chromeOutput` to change this:

- `coDiscard`: default; capture and discard.
- `coInherit`: inherit parent stdout/stderr.
- `coBuffer`: capture and expose output with `chromeOutput(process)` after termination.

This only applies to browsers launched by ncdp; `--discover` attaches to an existing Chrome process whose output is controlled by however it was started.

This is separate from ncdp's structured logs, which are controlled through the Chronicles settings in `config.nims`.

**Browser Scope Vs Page Scope**
The recommended page API hides page-target setup:

```nim
let br = await launchBrowser()
let page = await br.newPage()
await page.goto("https://example.com")
```

The browser websocket supports browser-level domains such as `Browser`. Raw
generated-CDP page work needs a page target websocket. Use:

```nim
let pageWs = await chrome.newTab(host, port, "about:blank")
let client = await transport.connect(pageWs)
```

Then call generated modules such as `cdp/gen/page`, `cdp/gen/runtime`, and
`cdp/gen/dom`. The examples under `examples/raw/` show this lower-level shape.

**Evaluated JavaScript And CSP**
`Runtime.evaluate` runs in the inspected page. Strict pages may block network or `data:` module imports via Content Security Policy. The ARIA helpers avoid this by inlining `examples/ariaSnapshot.js` into the evaluated expression instead of dynamically importing a `data:` module.

If an evaluated expression fails, inspect `RuntimeEvaluateResult.exceptionDetails`; examples surface this as a readable error.

**ARIA Interactive Refs Change After Navigation**
The `--interactive` ARIA example uses refs such as `[ref=n6]` from the latest snapshot. A navigation creates a new document and invalidates the old page-global helper state. The helper is reinstalled and refs are refreshed after navigation, but you still need to use refs from the most recent `snapshot` output.

ARIA actions use CDP input where browser semantics matter: `clickRef` dispatches
mouse events at the element center, `fillRef` focuses/selects then uses
`Input.insertText`, and `press` uses `Input.dispatchKeyEvent` so keys such as
`Tab`, `Return`, `F5`, and `Shift+Tab` go through Chrome's input pipeline rather
than synthetic DOM `KeyboardEvent`s.

Non-text native controls use browser value semantics instead of pretending they
are text boxes. Use `setRef` for `input[type=number]`, `date`, `time`,
`datetime-local`, `month`, `week`, `range`, and `color`; the helper assigns the
native value, verifies the browser accepted it, then dispatches `input` and
`change`. Use `selectRef` for `<select>` elements; it selects by value or label
and returns the selected option values.

The interactive ARIA example also enables the Runtime domain and records
`Runtime.consoleAPICalled` plus `Runtime.exceptionThrown` events while the REPL
is active. Use `console`, `logs`, or `c` to print messages, and `clearconsole`
or `cc` to reset the buffer.

Use `refs` or `actions` to enumerate actionable ARIA refs. The programmatic
`ncdp/aria.actionRefs` API returns both simple booleans and machine-readable
`actions` with value kinds and select options, so CLI autocomplete or agent
grammar generation can use the same data as the example. Use `links` to list all
detected page links; the programmatic `ncdp/aria.links` API returns the same
link data with ARIA refs when a link is present in the current snapshot.
