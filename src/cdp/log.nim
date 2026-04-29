## Logging configuration and re-exports for ncdp.
##
## Single import point so every module logs through the same chronicles
## instance. Topic strings live here as `const` so call sites can write
## ``logScope: topics = TopicTransport`` instead of repeating literals.
##
## Usage::
##
##   import ./log
##   logScope: topics = TopicTransport
##   info "transport connected", url = wsUrl
##
## See ``docs/internal/logging-plan.md`` for the noise budget and the
## level conventions (`trace` per-frame, `debug` per-request,
## `info` once-per-session lifecycle, `warn`/`error` operator-actionable).

import chronicles
export chronicles

logScope:
  topics = "cdp"

const
  TopicTransport* = "transport"
  TopicChrome*    = "chrome"
  TopicCDP*       = "cdp"
  TopicPDL*       = "pdl"
