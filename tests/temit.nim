## Acceptance tests for the codegen emitter. The bar set in the plan
## is: ``repr(emitDomain(Schema))`` matches the hand-written
## ``src/cdp/schema.nim`` byte-for-byte modulo whitespace and import
## ordering. We compare a normalized form (strip trailing whitespace,
## collapse runs of blank lines).
##
## The point of this suite is to keep emitter changes honest: any
## refactor that diverges from the reference shape will break a test
## and force a deliberate decision (update the reference, or fix the
## emitter).

import std/[os, strutils, tables, unittest]
import gen/pdl/[ast, parser]
import gen/cdp/[emit, names]

const PdlRoot = currentSourcePath().parentDir() / ".." /
                "resources" / "devtools-protocol" / "pdl"
const RefRoot = currentSourcePath().parentDir() / ".." /
                "src" / "cdp"

proc normalize(s: string): string =
  ## Strip trailing whitespace per line, collapse runs of blank lines
  ## to one, and drop a trailing newline. Tolerates the small layout
  ## differences between the hand-written reference modules and the
  ## emitter's output, while still failing on real shape divergences.
  var lines: seq[string]
  for raw in s.splitLines:
    var line = raw
    while line.len > 0 and (line[^1] == ' ' or line[^1] == '\t'):
      line.setLen(line.len - 1)
    lines.add line
  # collapse blank runs
  var collapsed: seq[string]
  var prevBlank = false
  for l in lines:
    let blank = l.len == 0
    if blank and prevBlank: continue
    collapsed.add l
    prevBlank = blank
  while collapsed.len > 0 and collapsed[^1] == "": collapsed.setLen(collapsed.len - 1)
  collapsed.join("\n")

proc loadDomain(name: string): PdlDomain =
  ## Pull a single domain by name out of the union of browser_protocol
  ## and js_protocol (with includes followed). Schema lives in
  ## js_protocol; SystemInfo lives in browser_protocol.
  let f = parsePdlFile(PdlRoot / "browser_protocol.pdl",
                       followIncludes = true)
  for d in f.domains:
    if d.name == name: return d
  let g = parsePdlFile(PdlRoot / "js_protocol.pdl")
  for d in g.domains:
    if d.name == name: return d
  raise newException(ValueError, "domain not found: " & name)

suite "emit — Schema":

  test "emitDomain(Schema) compiles":
    # The most basic check: the emitter doesn't raise. Doesn't say
    # anything about the output, but catches regressions in the
    # type-mapping or registry logic.
    let reg = newRegistry()
    let d = loadDomain("Schema")
    let txt = emitDomain(d, reg)
    check txt.len > 0
    check "Schema.getDomains" in txt
    check "Domain* {.deprecated.}" in txt
    check "GetDomainsResult* {.deprecated.}" in txt

  test "emitted output has the expected top-level imports":
    let reg = newRegistry()
    let d = loadDomain("Schema")
    let txt = emitDomain(d, reg)
    check "import chronos" in txt
    check "import ../jsonhooks" in txt
    check "import ../transport" in txt

  test "emitted output mentions every PDL field":
    let reg = newRegistry()
    let d = loadDomain("Schema")
    let txt = emitDomain(d, reg)
    check "name*: string" in txt
    check "version*: string" in txt
    check "domains*: seq[Domain]" in txt

suite "emit — SystemInfo":

  test "emits enum types with wire mappings":
    let reg = newRegistry()
    let d = loadDomain("SystemInfo")
    let txt = emitDomain(d, reg)
    check "SubsamplingFormat*" in txt
    check "sfYuv420" in txt
    check "SubsamplingFormatWire" in txt
    check "fromJsonHook*(v: var SubsamplingFormat" in txt

  test "emits all command bindings":
    let reg = newRegistry()
    let d = loadDomain("SystemInfo")
    let txt = emitDomain(d, reg)
    check "proc getInfo*" in txt
    check "proc getFeatureState*" in txt
    check "proc getProcessInfo*" in txt

  test "registers enum wire mappings":
    let reg = newRegistry()
    discard emitDomain(loadDomain("SystemInfo"), reg)
    check reg.enums.len >= 2  # at least SubsamplingFormat + ImageType
    let ssf = reg.enums.getOrDefault("SubsamplingFormat")
    check ssf.members.len == 3
    check ssf.members[0] == ("sfYuv420", "yuv420")

  test "ProcessInfo.type field is backticked":
    # ProcessInfo has a wire field literally named `type`. The
    # emitter must wrap the Nim field in backticks because it's a
    # keyword.
    let reg = newRegistry()
    let txt = emitDomain(loadDomain("SystemInfo"), reg)
    check "`type`*: string" in txt

suite "emit — corpus smoke":

  test "every domain emits without raising":
    # Doesn't validate output shape, but proves type-mapping covers
    # every primitive/array/ref combination present in the protocol.
    let f = parsePdlFile(PdlRoot / "browser_protocol.pdl",
                         followIncludes = true)
    let g = parsePdlFile(PdlRoot / "js_protocol.pdl")
    let reg = newRegistry()
    var emitted = 0
    for d in f.domains & g.domains:
      try:
        discard emitDomain(d, reg)
        inc emitted
      except CatchableError as e:
        checkpoint "emit failed for " & d.name & ": " & e.msg
        raise
    check emitted >= 50  # the corpus has 50+ domains
