## Acceptance tests for the codegen emitter.
##
## Codegen emits a single ``gen/types.nim`` containing every PDL
## type, and a per-domain module containing only commands and event
## registrations. These tests assert shape on representative
## domains. Compile-acceptance is in ``temit_compile.nim``.

import std/[os, strutils, tables, unittest]
import gen/pdl/[ast, parser]
import gen/cdp/[emit, names]

const PdlRoot = currentSourcePath().parentDir() / ".." /
                "resources" / "devtools-protocol" / "pdl"

proc loadDomains(): seq[PdlDomain] =
  let f = parsePdlFile(PdlRoot / "browser_protocol.pdl",
                       followIncludes = true)
  let g = parsePdlFile(PdlRoot / "js_protocol.pdl")
  result.add f.domains
  result.add g.domains

proc findDomain(domains: seq[PdlDomain]; name: string): PdlDomain =
  for d in domains:
    if d.name == name: return d
  raise newException(ValueError, "domain not found: " & name)

suite "emitTypesModule":

  test "emits something for every non-reserved domain":
    let domains = loadDomains()
    let reg = newRegistry()
    let txt = emitTypesModule(domains, reg)
    check txt.len > 1000
    # Sanity-check a handful of well-known generated types.
    check "BrowserGetVersionResult*" in txt
    check "RuntimeRemoteObject*" in txt
    check "NetworkRequestId*" in txt
    check "PageFrameAttachedParams*" in txt

  test "enums are emitted as pure":
    # Pure enums let `EnumType.Member` access the member without
    # polluting the module's flat namespace. Without `.pure.`, two
    # enums with shared spellings (e.g. SmartCardEmulation's
    # `Disposition.reset-card` and `ResultCode.reset-card`) would
    # collide.
    let reg = newRegistry()
    let txt = emitTypesModule(loadDomains(), reg)
    # Spot-check the previously-colliding pair from SmartCardEmulation.
    check "SmartCardEmulationDisposition" in txt
    check "{.pure.}" in txt

  test "every PDL enum mangles without intra-enum collision":
    # The mangler's per-enum collision check catches cases like two
    # members of the SAME enum normalizing to the same identifier.
    # Cross-enum is no longer an issue thanks to .pure.
    let reg = newRegistry()
    discard emitTypesModule(loadDomains(), reg)
    check reg.enums.len > 50

suite "emitDomainModule":

  test "Browser domain has getVersion proc":
    let domains = loadDomains()
    let reg = newRegistry()
    discard emitTypesModule(domains, reg)
    let txt = emitDomainModule(findDomain(domains, "Browser"), reg)
    check "proc getVersion*" in txt
    check "Future[BrowserGetVersionResult]" in txt
    check "import ./types" in txt
    check "import ../transport" in txt

  test "Page domain has event registration":
    let domains = loadDomains()
    let reg = newRegistry()
    discard emitTypesModule(domains, reg)
    let txt = emitDomainModule(findDomain(domains, "Page"), reg)
    # At least one on<Event> proc — Page has many events.
    check "proc onFrameAttached*" in txt
    check "addEventListener" in txt

  test "deprecated commands carry the pragma":
    let domains = loadDomains()
    let reg = newRegistry()
    discard emitTypesModule(domains, reg)
    # Network has at least one deprecated command.
    let txt = emitDomainModule(findDomain(domains, "Network"), reg)
    check "{.deprecated, async:" in txt

suite "emit corpus smoke":

  test "every domain emits without raising":
    let domains = loadDomains()
    let reg = newRegistry()
    discard emitTypesModule(domains, reg)
    var emitted = 0
    for d in domains:
      try:
        discard emitDomainModule(d, reg)
        inc emitted
      except CatchableError as e:
        checkpoint "emit failed for " & d.name & ": " & e.msg
        raise
    check emitted >= 50
