# Logging plan: chronicles integration for ncdp

Captured from a research pass on `/references/chronicles/` (Status's
chronos-friendly structured logger). Not yet adopted — this is the
runway. Read alongside `docs/internal/memory/project_layout.md`.

## Why chronicles, not std/logging or printf

- Built for chronos: every log call site is wrapped in
  `try/except CatchableError` by the chronicles macro, so logging
  cannot leak exceptions into our `{.async: (raises: [...]).}` set.
  See `chronicles.nim` lines 322–326 (the macro emits the wrapper).
- Records are **structured** (`info "msg", k=v, k=v`), not formatted
  strings. That means we can swap the sink from human-readable text to
  JSON without touching call sites — important when codegen will
  produce them by the hundred.
- Topic + dynamic-scope mechanism means request-id threading is
  automatic: every record produced inside `dynamicLogScope(id):` gets
  `id=N` attached without the caller passing it down.

## Compile-time configuration (set later in `config.nims`)

```nim
switch("define", "chronicles_sinks=textlines[stderr,nocolors]")
switch("define", "chronicles_log_level=DEBUG")  # debug builds
# release: chronicles_log_level=INFO
```

Defer until we have a deployment target:

- `chronicles_runtime_filtering=on` — runtime `setLogLevel` /
  `setTopicState`. Useful for an admin endpoint or CLI flag.
- `chronicles_streams` — multi-sink layouts (JSON to a file, text to
  stderr) when we wire to a log aggregation backend.

## Sinks

- **Local dev / tests**: `textlines[stderr,nocolors]`. Stderr keeps
  stdout clean for example output. `nocolors` works in any terminal.
- **Machine-parseable** (later): `json[file(logs/ncdp.json)]`. File
  output is lazy-opened on first write; the path can be reconfigured
  at runtime via `defaultChroniclesStream.output.open(path)`.
- **Defensive escape hatch**: the `dynamic` sink lets us install a
  closure that writes to stderr without raising
  (`try: stderr.write(...); except IOError: discard`). The chronicles
  macro already swallows raises, but in the hottest paths
  (frame dispatch, generated commands) we can shortcut to dynamic.

## Topic taxonomy

- `transport` — websocket connection, frame dispatch, request lifecycle
- `chrome` — process launch, `/json/version` polling, termination
- `cdp` — codegen-emitted domain commands and events (one bucket)
- `pdl` — PDL parser

Topics must be string literals at compile time. Either set them in a
module-level `logScope`, or pass them per-statement with
`info "msg", topics = "transport", k = v`.

## Request-id threading

```nim
proc sendCommand(...) {.async.} =
  let id = c.allocId()
  dynamicLogScope(id):
    info "request sent", `method` = methodName
    # ...
    let res = await fut
    info "response received", latency = elapsed
```

Every record in the dynamic scope's call tree carries `id=N` without
the called code knowing.

## Async + raises

The chronicles macro emits this around every log call:

```nim
try:
  block ...:
    `code`
except CatchableError as err:
  logLoggingFailure(cstring(eventName), err)
```

So a logging call cannot raise into our procs. **No need to wrap
`info`/`debug` in `try/except` at call sites.** This is the entire
reason chronicles is preferred over `std/logging`.

## Call-site idiom (for codegen reference)

```nim
# request lifecycle (transport.sendCommand)
info "request sent", id, `method` = methodName, paramBytes = $frame |> len
info "response received", id, latency

# transport error
error "transport error", err = e.msg, context = "frame dispatch"

# event listener fires (codegen output)
info "event fired", topics = "cdp", event = methodName

# chrome lifecycle (chrome.launch / chrome.terminate)
info "chrome spawned", topics = "chrome", pid, port, wsUrl
warn "boot timeout", topics = "chrome", lastErr, elapsed = Moment.now() - start
```

Identifier names without explicit `=value` expand to `name = name` —
keep the conventions short.

## Pitfalls

- **`trace` vs `debug` vs `info`.** `trace` is `{.noSideEffect.}`
  (callable from `func`) but compiled out unless explicitly enabled;
  `debug` is on in dev, off in release; `info` is the default for
  production-visible events. Don't reach for `warn`/`error` unless
  there's something the operator can act on.
- **Topics must be literals.** `topics = myStringVar` won't compile.
  Centralise topic strings as `const TopicTransport* = "transport"`.
- **Multi-sink ordering matters.** `textlines[stdout,file(...)]` writes
  to both, in order, before the next sink runs. To get colors in
  terminal but plain text on disk, use two sinks, not one
  multi-target sink.

## `src/cdp/log.nim` sketch (not yet written)

```nim
## Logging configuration and re-exports for ncdp.
## `import cdp/log; info "msg", key=val`.

import chronicles
export chronicles

logScope:
  topics = "cdp"

const
  TopicTransport* = "transport"
  TopicChrome*    = "chrome"
  TopicCDP*       = "cdp"
  TopicPDL*       = "pdl"
```

Single re-export point, four topic constants, one default `logScope`.
About 15 lines. Codegen depends only on `import cdp/log`; the rest of
the codebase ditto.

## Adoption plan

1. **Now or whenever it stops feeling premature.** Add chronicles to
   `ncdp.nimble`, write `src/cdp/log.nim`, set `chronicles_sinks` in
   `config.nims`. No call sites yet — verifies compile and config.
2. Instrument `src/cdp/transport.nim` (request/response/error
   lifecycle, dynamicLogScope on the request id). Highest-leverage
   visibility into the slow path.
3. Instrument `src/cdp/chrome.nim` (launch, boot polling, terminate).
4. Bake into codegen output (`src/gen/cdp/`). Each generated command
   gets one entry-point `info`; each event gets one. Codegen owns
   the idiom so we don't have to maintain it by hand.

The first two phases are independent and cheap. Defer phase 4 until
the codegen pipeline itself is settled.
