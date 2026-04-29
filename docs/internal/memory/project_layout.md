---
name: ncdp project layout
description: Directory structure, build dependencies, and where the parser/runtime/codegen split lives.
type: project
originSessionId: b148520b-ecfa-4969-897d-69c921fd08fd
---
`/app/ncdp` is "Nim Chrome DevTools Protocol bindings" — a PDL parser,
a small hand-written CDP runtime, and a code generator that emits Nim CDP
domain bindings.

**Tree:**

* `src/gen/pdl/` — `ast.nim` + `parser.nim`. PDL grammar AST and
  recursive-descent parser. The AST hierarchy uses
  `ref object of RootObj` (per user preference), so visitors will
  dispatch with `method`. `parsePdlFile(path, followIncludes=true)`
  resolves the `browser_protocol.pdl` include barrel.
* `src/cdp/` — hand-written runtime plus generated domain bindings.
  - `transport.nim` — `CDPClient`, `connect`, `sendCommand`,
    `addEventListener`, `close`, plus `dispatchResponse` / `dispatchEvent`
    + `newTestClient` exported for unit tests.
  - `jsonhooks.nim` — `Binary` distinct seq[byte] + base64 hooks,
    `dropNullFields` for `Option[T]` omission. Re-exports json/jsonutils/options.
  - `chrome.nim` — process launcher (`launch`/`discover`/`terminate`).
  - `gen/` — ignored generated output: shared `types.nim` plus one
    command/event module per CDP domain.
* `src/ncdp/` — high-level ergonomic browser automation layer. `browser.nim`
  owns Browser/Page lifecycle, navigation, evaluation, and screenshots;
  `aria.nim` wraps the bundled ARIA snapshot helper and ref actions.
* `src/gen/cdp/` — codegen pipeline (`names.nim`, `emit.nim`, `driver.nim`).
  It reads parsed PDL, emits the shared type module, and emits per-domain
  command/event modules.
* `examples/` — top-level numbered examples are the recommended high-level
  path: `ex_01_browser_get_version`, `ex_02_page_goto_eval_screenshot`, and
  `ex_03_aria_snapshot`.
* `examples/raw/` — numbered raw generated-CDP examples kept as reference
  specimens: parser tour, direct Browser.getVersion, generated Browser/Target,
  raw page navigation/eval/screenshot, and raw ARIA snapshot.
* `tests/` — parser corpus tests, transport/jsonhook tests, name-mangling
  tests, emitter shape tests, and generated-corpus compile acceptance.
* `resources/devtools-protocol/pdl/` — vendored CDP grammar files
  (`browser_protocol.pdl`, `js_protocol.pdl`, `domains/*.pdl`).

**Why:** runtime modules stay at `src/cdp/*.nim`; generated bindings live
under `src/cdp/gen/` so regeneration cannot clobber hand-written runtime
files. A single generated `types.nim` avoids Nim import cycles from CDP's
cross-domain type graph.

**How to apply:**

* `chronos` is the async runtime. `nws_client` (local checkout at
  `/app/nws_client/`, NOT in nimble registry — wired via path switch in
  `config.nims`) is the websocket layer.
* Generated raises set on every command proc:
  `[CDPError, CDPTransportError, CancelledError]`. Note **CDPTransportError**
  not `TransportError` — the latter clashes with chronos's own.
* Generated output uses a shared type module. Cross-domain references are
  bare domain-prefixed names such as `NetworkRequestId`, not module-qualified
  references.
* Generated enums are `{.pure.}` with PascalCase members and wire-array JSON
  hooks. This prevents enum member collisions in the shared type namespace.
* Pdl reference docs: `/references/Nim/lib/` (compiler stdlib),
  `/references/chronos/` (chronos checkout), `/app/nws_client/` (the
  websocket client). Distilled Nim guide:
  `/home/pedro/.claude-work/skills/nim/references/`. Mirror copies at
  `/references/Nim_2/` and `/references/nim-guide/`.
