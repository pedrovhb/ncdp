## Stress test: walk the entire PDL corpus, mangle every enum's
## members, and assert no collisions and no Nim-keyword leaks. This
## is the cheapest way to surface name-mangling bugs that only the
## real protocol triggers.

import std/[os, sets, unittest]
import gen/pdl/[ast, parser]
import gen/cdp/names

const PdlRoot = currentSourcePath().parentDir() / ".." /
                "resources" / "devtools-protocol" / "pdl"

proc gatherInlineEnums(domain, owner: string;
                       props: seq[PdlProperty];
                       acc: var seq[(string, string, seq[string])]) =
  for p in props:
    if p.typ of PdlEnumType:
      var ms: seq[string]
      for m in PdlEnumType(p.typ).members: ms.add m.name
      acc.add (domain, owner & "_" & p.name, ms)

proc collectEnums(d: PdlDomain;
                  acc: var seq[(string, string, seq[string])]) =
  ## Append `(domain, typeName, [wireMembers])` for every named or
  ## inline enum reachable from `d`. Inline enums on properties /
  ## parameters / returns get a synthetic type name `<owner>_<field>`
  ## so the mangler exercises the full enum-prefix path.
  for t in d.types:
    if t of PdlEnumDecl:
      let e = PdlEnumDecl(t)
      var ms: seq[string]
      for m in e.members: ms.add m.name
      acc.add (d.name, t.name, ms)
  for t in d.types:
    if t of PdlObjectDecl:
      gatherInlineEnums(d.name, t.name, PdlObjectDecl(t).properties, acc)
  for c in d.commands:
    gatherInlineEnums(d.name, c.name & "Params", c.parameters, acc)
    gatherInlineEnums(d.name, c.name & "Result", c.returns, acc)
  for ev in d.events:
    gatherInlineEnums(d.name, ev.name & "Params", ev.parameters, acc)

suite "names — corpus stress":

  test "every PDL enum mangles without collisions":
    let f = parsePdlFile(PdlRoot / "browser_protocol.pdl",
                          followIncludes = true)
    let g = parsePdlFile(PdlRoot / "js_protocol.pdl")

    var enums: seq[(string, string, seq[string])]
    for d in f.domains: collectEnums(d, enums)
    for d in g.domains: collectEnums(d, enums)

    check enums.len > 0

    var totalMembers = 0
    let reg = newRegistry()
    for (dom, typ, wires) in enums:
      var pairs: seq[(string, string)]
      var seen = initHashSet[string]()
      for w in wires:
        if w in seen: continue # duplicate wire spelling within enum
        seen.incl w
        pairs.add (enumMemberName(typ, w), w)
      try:
        reg.recordEnum(dom & "." & typ, pairs)
        totalMembers += pairs.len
      except EnumCollisionError as e:
        checkpoint "collision in " & dom & "." & typ & ": " & e.msg
        raise

    # Sanity: a healthy run covers thousands of enum members.
    check totalMembers > 500

  test "no mangled member is a Nim keyword":
    let f = parsePdlFile(PdlRoot / "browser_protocol.pdl",
                          followIncludes = true)
    let g = parsePdlFile(PdlRoot / "js_protocol.pdl")

    var enums: seq[(string, string, seq[string])]
    for d in f.domains: collectEnums(d, enums)
    for d in g.domains: collectEnums(d, enums)

    for (dom, typ, wires) in enums:
      for w in wires:
        let m = enumMemberName(typ, w)
        if isNimKeyword(m):
          checkpoint "in " & dom & "." & typ & ": '" & w &
                     "' mangled to keyword '" & m & "'"
          check false
