## Bindings for the CDP `Browser` domain — partial.
##
## This module currently exposes only `Browser.getVersion`, which is
## what the end-to-end smoke test (`examples/gen/ex_02`) actually
## hits: `Schema.getDomains` lives at the page-target scope, but the
## debugger endpoint chrome opens for us is browser-scope, so we need
## a browser-scope command for any "did the round trip work?" demo.
##
## The full Browser domain (window bounds, permissions, downloads,
## etc.) will land via codegen.

import chronos
import ./jsonhooks
import ./transport

type
  GetVersionResult* = ref object
    ## Result of `Browser.getVersion`.
    protocolVersion*: string
      ## Protocol version.
    product*: string
      ## Product name.
    revision*: string
      ## Product revision.
    userAgent*: string
      ## User-Agent.
    jsVersion*: string
      ## V8 version.

proc getVersion*(client: CDPClient): Future[GetVersionResult] {.
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  ## Returns version information.
  let raw = await client.sendCommand("Browser.getVersion")
  try:
    result = jsonTo(raw, GetVersionResult)
  except CatchableError as e:
    raise newException(CDPError,
      "Browser.getVersion: malformed response: " & e.msg)
