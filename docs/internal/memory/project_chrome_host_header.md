---
name: Chrome Host header CDP gotcha
description: Chrome rewrites webSocketDebuggerUrl from the Host: request header, so a port-less Host: produces a port-less URL. Patch authority client-side.
type: project
originSessionId: b148520b-ecfa-4969-897d-69c921fd08fd
---
When fetching `/json/version` from a Chrome `--remote-debugging-port`, the
returned `webSocketDebuggerUrl` is **constructed from the `Host:` request
header**, not from the actual listening port. chronos's
`HttpSessionRef.fetch` sends `Host: 127.0.0.1` (no port) for HTTP fetches,
so Chrome answers with `ws://127.0.0.1/devtools/browser/...` — the port is
gone, and the subsequent websocket connect hits a 308 redirect.

**Why:** observed end-to-end while wiring `examples/raw/ex_02`. Verified
with curl: `-H "Host: 127.0.0.1"` reproduces the port-stripping;
`-H "Host: 127.0.0.1:9222"` returns the correct URL. So this is Chrome's
behaviour, not a chronos bug, and it affects any HTTP client that omits
the port from `Host:` (most do, for the default-port case).

**How to apply:** When integrating with `chrome --remote-debugging-port`
from any HTTP client in this project, do not trust the
`webSocketDebuggerUrl` field verbatim — replace its authority with the
host:port the caller actually requested. The fix lives in
`src/cdp/chrome.nim:rewriteAuthority`. If we ever swap the HTTP client
or move to `wss://`, re-test that the rewrite still applies cleanly.

Adjacent fact worth knowing: the browser-scope debugger endpoint
(`ws://.../devtools/browser/...`) only exposes Browser, Target, Tracing,
Storage, IO, and similar domains. `Schema.getDomains` lives at page-scope
and returns `'Schema.getDomains' wasn't found` if called on the browser
endpoint. To exercise per-target domains, attach via
`Target.attachToTarget` first.
