## Codegen orchestrator: parses the bundled PDL files, walks domains
## in dependency order, and writes one Nim module per domain into a
## **dedicated output directory**, by default ``src/cdp/gen/``.
##
## Generated files always live under their own directory so they can
## never clobber hand-written modules at the ``src/cdp/`` level (the
## runtime — ``transport.nim``, ``chrome.nim``, ``logging.nim`` — and
## the two reference domains used as codegen-acceptance fixtures
## — ``schema.nim``, ``system_info.nim``).
##
## The driver is idempotent: a file is only rewritten when its
## emitted content differs from what's already on disk.

import std/[algorithm, os, sets, strutils, tables]
import ../pdl/[ast, parser]
import ./[emit, names]

const ReservedDomains = ["Schema", "SystemInfo"]
  ## Hand-written reference modules at ``src/cdp/<name>.nim`` that the
  ## emitter is supposed to reproduce. Re-emitting would clobber the
  ## reference; acceptance tests diff against them instead.

type
  GenOptions* = object
    pdlRoot*: string
    outDir*: string
    dryRun*: bool
    onlyDomains*: seq[string]

  GenReport* = object
    written*: seq[string]
    unchanged*: seq[string]
    skipped*: seq[string]

proc topoSort(domains: seq[PdlDomain]): seq[PdlDomain] =
  ## Stable topological sort by ``dependsOn``. Alphabetical
  ## tiebreaking keeps output stable across runs.
  var byName = initTable[string, PdlDomain]()
  for d in domains: byName[d.name] = d
  var indeg = initTable[string, int]()
  for d in domains: indeg[d.name] = 0
  for d in domains:
    for dep in d.dependsOn:
      if dep in byName:
        indeg[d.name] = indeg[d.name] + 1

  var ready: seq[string]
  for d in domains:
    if indeg[d.name] == 0: ready.add d.name
  ready.sort()

  while ready.len > 0:
    let n = ready[0]
    ready.delete(0)
    let d = byName[n]
    result.add d
    var unlocked: seq[string]
    for other in domains:
      if n in other.dependsOn and other.name in indeg:
        indeg[other.name] = indeg[other.name] - 1
        if indeg[other.name] == 0: unlocked.add other.name
    if unlocked.len > 0:
      unlocked.sort()
      for u in unlocked: ready.add u

  if result.len < domains.len:
    # Cycle — fall back to original order. CDP doesn't have cycles in
    # practice; this is a defensive guardrail.
    result = domains

proc loadAllDomains(pdlRoot: string): seq[PdlDomain] =
  let f = parsePdlFile(pdlRoot / "browser_protocol.pdl",
                        followIncludes = true)
  let g = parsePdlFile(pdlRoot / "js_protocol.pdl")
  for d in f.domains: result.add d
  for d in g.domains: result.add d

proc isReserved(name: string): bool =
  for r in ReservedDomains:
    if r == name: return true
  false

proc writeIfChanged(path, content: string): bool =
  if fileExists(path):
    if readFile(path) == content: return false
  writeFile(path, content)
  true

proc generate*(opts: GenOptions): GenReport =
  let domains = topoSort(loadAllDomains(opts.pdlRoot))
  let registry = newRegistry()
  let only = block:
    var s = initHashSet[string]()
    for n in opts.onlyDomains: s.incl n
    s

  if not opts.dryRun: createDir(opts.outDir)
  for d in domains:
    let path = opts.outDir / (moduleFileName(d.name) & ".nim")
    if isReserved(d.name) or
       (only.len > 0 and d.name notin only):
      result.skipped.add path
      continue
    let text = emitDomain(d, registry)
    if opts.dryRun:
      result.unchanged.add path
      continue
    if writeIfChanged(path, text):
      result.written.add path
    else:
      result.unchanged.add path

# --------------------------------------------------------------- CLI ------

when isMainModule:
  import std/parseopt

  proc usage() =
    echo "Usage: cdp_gen [--pdl=<dir>] [--out=<dir>] [--dry-run] [--only=Domain,Domain]"
    echo ""
    echo "Defaults: --pdl=resources/devtools-protocol/pdl --out=src/cdp/gen"
    quit(1)

  var opts = GenOptions(
    pdlRoot: "resources/devtools-protocol/pdl",
    outDir: "src/cdp/gen")
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "pdl": opts.pdlRoot = val
      of "out": opts.outDir = val
      of "dry-run", "n": opts.dryRun = true
      of "only":
        for n in val.split(','):
          if n.len > 0: opts.onlyDomains.add n
      of "help", "h": usage()
      else: usage()
    of cmdArgument: usage()
    of cmdEnd: discard

  let report = generate(opts)
  echo "wrote ", report.written.len, " files, ",
       report.unchanged.len, " unchanged, ",
       report.skipped.len, " skipped"
  for p in report.written: echo "  W ", p
