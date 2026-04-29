## Compile-acceptance for emitter output. Drives the full driver into
## ``src/cdp/gen`` (an ignored generated-output directory) and shells
## out to `nim check` on the bundled importer so a single nim invocation
## walks the entire generated module graph.
##
## This catches what string-shape tests miss: missing imports,
## malformed pragmas, undeclared identifiers, raises-set violations,
## etc. — anything that breaks Nim semantics.

import std/[os, osproc, unittest]
import gen/cdp/driver

const ProjectRoot = currentSourcePath().parentDir() / ".."

suite "emit — compile":

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
