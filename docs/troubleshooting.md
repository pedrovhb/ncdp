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
nim c -r examples/gen/ex_02_call_browser_getVersion.nim -- --port=9333
```

For `--discover`, start Chrome yourself with the same port:

```sh
chromium --remote-debugging-port=9333 --user-data-dir=/tmp/ncdp-profile
nim c -r examples/gen/ex_02_call_browser_getVersion.nim -- --discover --port=9333
```

**Generated Modules Missing**
Examples that import `cdp/gen/...` require generated files under `src/cdp/gen/`. That directory is ignored by Git because it is derived from the vendored PDL files.

Generate it with:

```sh
nimble gen
```

`nimble test` also generates the corpus before the compile-acceptance test.

**NixOS OpenSSL Runtime Errors**
On this NixOS host, Nim binaries that load OpenSSL may fail at runtime unless `LD_LIBRARY_PATH` includes nix-ld's library directory:

```sh
export LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib
```

This mainly affects binaries compiled with `-d:ssl`.

**Chrome `webSocketDebuggerUrl` Missing The Port**
Chrome builds `webSocketDebuggerUrl` from the HTTP request's `Host:` header. Some HTTP clients normalize `Host:` in a way that drops the port. `cdp/chrome.discover` and `cdp/chrome.launch` rewrite the websocket authority back to the host and port they actually contacted, so prefer those helpers over using `/json/version` manually.

**Noisy Chrome Stderr**
Chrome can write unrelated diagnostics such as GCM registration errors, GPU adapter messages, and Vulkan/WebGPU warnings to stderr. Some of these are emitted before Chrome's logging system initializes, so `--log-level` alone is not enough.

`chrome.launch()` captures launched Chrome stdout/stderr into a pipe and drains it silently, and also passes `--disable-logging` and `--log-level=3`. Draining is important: if output is captured but not read, Chrome can block on a full pipe. This only applies to browsers launched by ncdp; `--discover` attaches to an existing Chrome process whose output is controlled by however it was started.

This is separate from ncdp's structured logs, which are controlled through the Chronicles settings in `config.nims`.

**Browser Scope Vs Page Scope**
The browser websocket supports browser-level domains such as `Browser`. Most web-page work needs a page target websocket. Use:

```nim
let pageWs = await chrome.newTab(host, port, "about:blank")
let client = await transport.connect(pageWs)
```

Then call generated modules such as `cdp/gen/page`, `cdp/gen/runtime`, and `cdp/gen/dom`.

**Evaluated JavaScript And CSP**
`Runtime.evaluate` runs in the inspected page. Strict pages may block network or `data:` module imports via Content Security Policy. The ARIA snapshot example avoids this by inlining `examples/ariaSnapshot.js` into the evaluated expression instead of dynamically importing a `data:` module.

If an evaluated expression fails, inspect `RuntimeEvaluateResult.exceptionDetails`; examples surface this as a readable error.

**ARIA Interactive Refs Change After Navigation**
The `--interactive` ARIA example uses refs such as `[ref=ne6]` from the latest snapshot. A navigation creates a new document and invalidates the old page-global helper state. The example reinstalls the helper and refreshes refs after navigation, but you still need to use refs from the most recent `snapshot` output.
