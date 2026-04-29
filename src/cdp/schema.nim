## Bindings for the CDP `Schema` domain.
##
## NOTE: this is a hand-written reference module. Once the codegen
## lands, this file should match the generator's output for the
## `Schema` PDL domain byte-for-byte (modulo trailing whitespace).
## Every shape decision here will be reproduced for the other ~49
## domains, so it is worth thinking each one through.
##
## Source PDL: `resources/devtools-protocol/pdl/js_protocol.pdl`,
## `deprecated domain Schema`.

import chronos
import ./jsonhooks
import ./transport

type
  Domain* {.deprecated.} = ref object
    ## Description of the protocol domain.
    name*: string
      ## Domain name.
    version*: string
      ## Domain version.

  GetDomainsResult* {.deprecated.} = ref object
    ## Result of `Schema.getDomains`.
    domains*: seq[Domain]
      ## List of supported domains.

proc getDomains*(client: CDPClient): Future[GetDomainsResult] {.
    deprecated,
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  ## Returns supported domains.
  let raw = await client.sendCommand("Schema.getDomains")
  try:
    result = jsonTo(raw, GetDomainsResult)
  except CatchableError as e:
    raise newException(CDPError,
      "Schema.getDomains: malformed response: " & e.msg)
