## ex_01_parse_summary — parse a PDL file and print a summary of every
## domain, type, command, and event found inside.
##
## Run with::
##
##   nim c -r examples/gen/ex_01_parse_summary.nim
##   nim c -r examples/gen/ex_01_parse_summary.nim resources/devtools-protocol/pdl/domains/Memory.pdl
##
## With no argument the example loads ``js_protocol.pdl`` from the bundled
## ``resources/`` tree, so it works out of the box from a fresh checkout.

import std/[options, os, strformat, strutils]
import ncdp

proc renderType(t: PdlType): string =
  ## Pretty-print a type reference in a form that resembles the original
  ## PDL syntax — handy for human-readable summaries.
  if t of PdlPrimitiveType:
    case PdlPrimitiveType(t).kind
    of ppString: "string"
    of ppInteger: "integer"
    of ppNumber: "number"
    of ppBoolean: "boolean"
    of ppAny: "any"
    of ppBinary: "binary"
    of ppObject: "object"
  elif t of PdlArrayType:
    "array of " & renderType(PdlArrayType(t).element)
  elif t of PdlRefType:
    let r = PdlRefType(t)
    if r.domain.isSome: r.domain.get & "." & r.name else: r.name
  elif t of PdlEnumType:
    "enum(" & $PdlEnumType(t).members.len & ")"
  else:
    "<unknown>"

proc badge(experimental, deprecated: bool): string =
  ## Small inline marker to call out experimental/deprecated declarations
  ## without breaking the column layout below.
  if experimental and deprecated: " [exp,dep]"
  elif experimental: " [exp]"
  elif deprecated: " [dep]"
  else: ""

proc summarize(d: PdlDomain) =
  echo &"domain {d.name}{badge(d.experimental, d.deprecated)}"
  if d.dependsOn.len > 0:
    echo "  depends on: ", d.dependsOn.join(", ")

  if d.types.len > 0:
    echo &"  types ({d.types.len}):"
    for t in d.types:
      let kind =
        if t of PdlObjectDecl:
          let o = PdlObjectDecl(t)
          &"object, {o.properties.len} props"
        elif t of PdlEnumDecl:
          let e = PdlEnumDecl(t)
          &"enum, {e.members.len} values"
        elif t of PdlAliasDecl:
          "alias of " & renderType(PdlAliasDecl(t).base)
        else:
          "<unknown>"
      echo &"    {t.name:<30} {kind}{badge(t.experimental, t.deprecated)}"

  if d.commands.len > 0:
    echo &"  commands ({d.commands.len}):"
    for c in d.commands:
      let sig = &"params={c.parameters.len} returns={c.returns.len}"
      let red = if c.redirect.isSome: " -> " & c.redirect.get else: ""
      echo &"    {c.name:<30} {sig}{red}{badge(c.experimental, c.deprecated)}"

  if d.events.len > 0:
    echo &"  events ({d.events.len}):"
    for e in d.events:
      echo &"    {e.name:<30} params={e.parameters.len}{badge(e.experimental, e.deprecated)}"

proc main() =
  let path =
    if paramCount() >= 1:
      paramStr(1)
    else:
      currentSourcePath().parentDir() / ".." / ".." /
        "resources" / "devtools-protocol" / "pdl" / "js_protocol.pdl"

  echo "parsing: ", path
  let f = parsePdlFile(path)

  if f.version.isSome:
    let v = f.version.get
    echo &"version: {v.major}.{v.minor}"
  if f.includes.len > 0:
    echo &"includes ({f.includes.len}):"
    for inc in f.includes: echo "  ", inc.path

  echo ""
  for d in f.domains:
    summarize(d)
    echo ""

when isMainModule:
  main()
