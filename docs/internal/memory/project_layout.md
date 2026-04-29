---
name: ncdp project layout
description: Directory structure, build dependencies, and where the parser/runtime/codegen split lives.
type: project
originSessionId: b148520b-ecfa-4969-897d-69c921fd08fd
---
`/app/ncdp` is "Nim Chrome DevTools Protocol bindings" — currently a PDL
parser plus a small hand-written CDP runtime. Code generator from PDL →
Nim modules is the next phase.

**Tree:**

* `src/gen/pdl/` — `ast.nim` + `parser.nim`. PDL grammar AST and
  recursive-descent parser. The AST hierarchy uses
  `ref object of RootObj` (per user preference), so visitors will
  dispatch with `method`. `parsePdlFile(path, followIncludes=true)`
  resolves the `browser_protocol.pdl` include barrel.
* `src/cdp/` — runtime + hand-written reference modules.
  - `transport.nim` — `CDPClient`, `connect`, `sendCommand`,
    `addEventListener`, `close`, plus `dispatchResponse` / `dispatchEvent`
    + `newTestClient` exported for unit tests.
  - `jsonhooks.nim` — `Binary` distinct seq[byte] + base64 hooks,
    `dropNullFields` for `Option[T]` omission. Re-exports json/jsonutils/options.
  - `chrome.nim` — process launcher (`launch`/`discover`/`terminate`).
  - `schema.nim` / `system_info.nim` / `browser.nim` — hand-written
    domain bindings, used as codegen reference (schema, system_info)
    and end-to-end smoke test (browser).
* `src/gen/cdp/` — *future* codegen pipeline (names.nim, emit.nim,
  driver.nim). Doesn't exist yet.
* `examples/gen/` — `ex_01_parse_summary` (parser tour),
  `ex_02_call_browser_getVersion` (live Chrome roundtrip).
* `tests/` — `tpdl_parser.nim` (parser corpus + unit tests),
  `ttransport.nim` (dispatch + jsonhooks).
* `resources/devtools-protocol/pdl/` — vendored CDP grammar files
  (`browser_protocol.pdl`, `js_protocol.pdl`, `domains/*.pdl`).

**Why:** user's chosen layout (`src/cdp/<domain>.nim`, not
`src/ncdp/cdp/...`) mirrors the wire `Page.foo` calls.

**How to apply:**

* `chronos` is the async runtime. `nws_client` (local checkout at
  `/app/nws_client/`, NOT in nimble registry — wired via path switch in
  `config.nims`) is the websocket layer.
* Generated raises set on every command proc:
  `[CDPError, CDPTransportError, CancelledError]`. Note **CDPTransportError**
  not `TransportError` — the latter clashes with chronos's own.
* The hand-written modules `schema.nim` and `system_info.nim` are the
  byte-for-byte reference the codegen must reproduce; do not change
  their idiom without recording the reasoning.
* Pdl reference docs: `/references/Nim/lib/` (compiler stdlib),
  `/references/chronos/` (chronos checkout), `/app/nws_client/` (the
  websocket client). Distilled Nim guide:
  `/home/pedro/.claude-work/skills/nim/references/`. Mirror copies at
  `/references/Nim_2/` and `/references/nim-guide/`.
