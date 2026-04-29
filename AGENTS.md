# Notes for AI agents working on this repository

This file is the entry point for any LLM-driven assistant (Claude Code,
opencode, Cursor, etc.) editing this codebase. Read it before doing
anything non-trivial.

## What this is

Nim Chrome DevTools Protocol bindings — `ncdp`. Two parts so far:

* **PDL parser** (`src/gen/pdl/`) — reads the Chrome DevTools Protocol
  grammar files and produces an AST.
* **CDP runtime** (`src/cdp/`) — `transport.nim`, `chrome.nim`,
  `jsonhooks.nim`, plus a few hand-written domain modules
  (`schema.nim`, `system_info.nim`, `browser.nim`) that act as the
  reference shape the eventual codegen has to reproduce.

The next phase is the code generator (`src/gen/cdp/`, doesn't exist yet)
that walks the PDL AST and emits one Nim module per domain matching the
hand-written reference modules byte-for-byte.

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
  (`SubsamplingFormat.sfYuv420`), paired with a `XxxWire: array[T,
  string]` constant and `to/fromJsonHook` overloads. The wire spelling
  never appears in user code.
* Module layout: `src/cdp/<snake_name>.nim` per domain. Codegen will
  emit there too once it lands.

## Building & running

* `nimble test` — parser + transport unit tests.
* `nim c -d:ssl -r examples/gen/ex_02_call_browser_getVersion.nim` —
  end-to-end smoke against a launched Chrome. Needs
  `LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib` at runtime
  (see memory note).
* `nws_client` is a local checkout at `/app/nws_client/`, wired via a
  `path` switch in `config.nims`. It is **not** in the nimble registry.

## Code review

When reviewing or being reviewed: read the hand-written reference
modules (`schema.nim`, `system_info.nim`) carefully — every shape choice
there will be reproduced ~50 times by codegen. Comments on idiom there
are unusually high-leverage.
