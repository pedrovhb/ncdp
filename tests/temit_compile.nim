## Validate that emitted module text actually compiles. Writes the
## generator output for Schema and SystemInfo into a `gen/` subdir of
## a tmpdir alongside copies of the runtime modules and shells out to
## `nim check`. Catches the bugs that pure string-shape tests miss
## (missing imports, wrong type spellings, malformed pragmas).

import std/[os, osproc, unittest]
import gen/pdl/[ast, parser]
import gen/cdp/[emit, names]

const PdlRoot = currentSourcePath().parentDir() / ".." /
                "resources" / "devtools-protocol" / "pdl"
const RtRoot = currentSourcePath().parentDir() / ".." / "src" / "cdp"

proc loadDomain(name: string): PdlDomain =
  let f = parsePdlFile(PdlRoot / "browser_protocol.pdl",
                       followIncludes = true)
  for d in f.domains:
    if d.name == name: return d
  let g = parsePdlFile(PdlRoot / "js_protocol.pdl")
  for d in g.domains:
    if d.name == name: return d
  raise newException(ValueError, name)

proc compileEmittedDomain(domainName: string): tuple[ok: bool; output: string] =
  let reg = newRegistry()
  let src = emitDomain(loadDomain(domainName), reg)
  let tmp = getTempDir() / ("ncdp-emit-" & domainName)
  let genSub = tmp / "gen"
  createDir(genSub)
  # Layout mirrors the real one: runtime/reference modules at the
  # same level as `gen/`, generated module inside `gen/`. Generated
  # imports (`../jsonhooks`, `../transport`, `../schema`, etc.) then
  # resolve correctly.
  for f in ["jsonhooks.nim", "transport.nim", "schema.nim",
            "system_info.nim", "browser.nim", "logging.nim",
            "chrome.nim"]:
    let dst = tmp / f
    if fileExists(RtRoot / f) and not fileExists(dst):
      writeFile(dst, readFile(RtRoot / f))
  let path = genSub / (moduleFileName(domainName) & ".nim")
  writeFile(path, src)
  let cmd = "nim check --hints:off --warnings:off --mm:orc " &
            "--path:" & RtRoot.parentDir() & " " &
            "--path:/app/nws_client/src " &
            "--define:chronicles_sinks=textlines[stderr,nocolors] " &
            path
  let (output, code) = execCmdEx(cmd)
  result = (code == 0, output)

suite "emit — compiles":

  test "Schema":
    let (ok, output) = compileEmittedDomain("Schema")
    if not ok:
      checkpoint output
    check ok

  test "SystemInfo":
    let (ok, output) = compileEmittedDomain("SystemInfo")
    if not ok:
      checkpoint output
    check ok

  # Runtime exercises the full surface: optional complex parameters
  # (Option[seq[CallArgument]]), enum returns, cross-domain refs.
  # This is the test that regressed when chronos's strict raises
  # tracking surfaced — keep it pinned to catch future drift.
  test "Runtime":
    let (ok, output) = compileEmittedDomain("Runtime")
    if not ok:
      checkpoint output
    check ok
