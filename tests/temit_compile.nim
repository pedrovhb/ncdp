## Compile-adjacent checks for emitter output. The full generated-corpus
## ``nim check`` is intentionally opt-in because it is too slow for the
## default ``nimble test`` loop.
##
## This catches what string-shape tests miss: missing imports,
## malformed pragmas, undeclared identifiers, raises-set violations,
## etc. — anything that breaks Nim semantics.

import std/[os, strutils, unittest]
when defined(ncdpFullCompileCheck):
  import std/osproc
import gen/cdp/driver

const ProjectRoot = currentSourcePath().parentDir() / ".."

suite "emit — compile":

  test "only-domain generation includes dependency types":
    let outDir = ProjectRoot / "tests" / "tmp_gen_only_page"
    if dirExists(outDir): removeDir(outDir)
    try:
      let report = generate(GenOptions(
        pdlRoot: ProjectRoot / "resources" / "devtools-protocol" / "pdl",
        outDir: outDir,
        onlyDomains: @[
          "Page",
        ]))
      check report.written.len + report.unchanged.len > 0
      check fileExists(outDir / "types.nim")
      check fileExists(outDir / "page.nim")
      check not fileExists(outDir / "runtime.nim")
      let typesText = readFile(outDir / "types.nim")
      check "RuntimeExecutionContextId*" in typesText
      check "NetworkRequestId*" in typesText
      check "PageFrameAttachedParams*" in typesText
    finally:
      if dirExists(outDir): removeDir(outDir)

  when defined(ncdpFullCompileCheck):
    test "all generated modules pass nim check":
      let report = generate(GenOptions(
        pdlRoot: ProjectRoot / "resources" / "devtools-protocol" / "pdl",
        outDir: ProjectRoot / "src" / "cdp" / "gen"))
      check report.written.len + report.unchanged.len > 0

      # The importer file imports every module under src/cdp/gen/ in
      # one file so a single `nim check` walks the whole graph in a
      # single semantic pass.
      let cmd = "nim check --hints:off --warnings:off " &
                ProjectRoot / "tests" / "all_gen_compile.nim"
      let (output, code) = execCmdEx(cmd)
      if code != 0:
        checkpoint output
      check code == 0
