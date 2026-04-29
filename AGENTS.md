# Notes for AI agents working on this repository

This file is the entry point for any LLM-driven assistant (Claude Code,
opencode, Cursor, etc.) editing this codebase. Read it before doing
anything non-trivial.

## What this is

Nim Chrome DevTools Protocol bindings — `ncdp`. Three parts:

* **PDL parser** (`src/gen/pdl/`) — reads the Chrome DevTools Protocol
  grammar files and produces an AST.
* **CDP runtime** (`src/cdp/`) — `transport.nim`, `chrome.nim`,
  `jsonhooks.nim`, and `logging.nim`.
* **CDP code generator** (`src/gen/cdp/`) — walks the PDL AST and emits
  generated bindings under the ignored `src/cdp/gen/` directory: one
  shared `types.nim` module plus one command/event module per domain.

## Where the project memory lives

`docs/internal/memory/` is the project's accumulated notes — gotchas,
non-obvious decisions, the story behind things that aren't visible from
the code alone. **Read `docs/internal/memory/MEMORY.md` first** for the
index; it points at:

* `project_layout.md` — directory structure, dependencies, key reference
  paths (chronos checkout, nws_client, Nim stdlib).
* `project_chrome_host_header.md` — Chrome's `webSocketDebuggerUrl`
  rewriting based on the `Host:` request header. Don't trust the
  returned URL verbatim.
* `project_nix_ld_library_path.md` — Nim binaries on this NixOS host
  need `LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib` at
  runtime when they pull in OpenSSL.

If you discover a new gotcha, add it as a new `.md` under that
directory and link it from `MEMORY.md`. Every memory file has frontmatter
(`name`, `description`, `type`) so future agents can find it.

## Conventions

* `ref object of RootObj` for the PDL AST (visitor dispatch via `method`).
* Async raises set on every CDP command proc:
  `[CDPError, CDPTransportError, CancelledError]`. Note the prefixed
  `CDPTransportError` — chronos exports its own `TransportError`.
* `Option[T]` for PDL `optional` fields. Outbound omission is handled in
  `transport.sendCommand` via `dropNullFields`, not at every call site.
* PDL named enums → Nim enums with type-prefixed members
  was the old plan. Current generated enums are `{.pure.}` with
  qualified PascalCase members (`SubsamplingFormat.Yuv420`), paired
  with a `XxxWire: array[T, string]` constant and `to/fromJsonHook`
  overloads. The wire spelling never appears in user code.
* Module layout: hand-written runtime modules live at `src/cdp/*.nim`;
  generated domain modules live at `src/cdp/gen/<snake_name>.nim` and
  share `src/cdp/gen/types.nim`.

## Building & running

* `nimble test` — parser, transport, name-mangling, codegen, and focused
  generated-output checks. The full generated-corpus `nim check` is opt-in
  via `-d:ncdpFullCompileCheck` because it is slow.
* `nimble gen` — regenerate ignored bindings under `src/cdp/gen/`.
* `nimble docs` — generate local API docs under ignored `htmldocs/`.
  It intentionally skips `cdp/chrome.nim` and high-level modules that import
  it because Nim doc trips over Chronos `asyncproc` on this toolchain.
* `nimble examples` — compile the numbered examples without running Chrome.
* `nim c -d:ssl -r examples/ex_01_browser_get_version.nim` —
  end-to-end smoke against a launched Chrome. Needs
  `LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib` at runtime
  (see memory note).
* `nws_client` is a local checkout at `/app/nws_client/`, wired via a
  `path` switch in `config.nims`. It is **not** in the nimble registry.

## Code review

When reviewing or being reviewed: focus especially on `src/gen/cdp/emit.nim`,
`src/gen/cdp/names.nim`, and representative generated output. Shape choices
there affect every CDP domain, so comments on naming, optional handling,
raises sets, and JSON hooks are unusually high-leverage.
