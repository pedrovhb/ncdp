## Round-trip and shape tests for the PDL parser. The bulk of coverage
## comes from parsing every ``.pdl`` file shipped under
## ``resources/devtools-protocol/pdl`` — if any file fails to parse, the
## suite fails with the offending line.

import std/[options, os, sequtils, strutils, unittest]
import gen/pdl/[ast, parser]

const PdlRoot = currentSourcePath().parentDir() / ".." /
                "resources" / "devtools-protocol" / "pdl"

suite "pdl parser — focused":

  test "version block":
    let f = parsePdl("""
version
  major 1
  minor 3
""")
    check f.version.isSome
    check f.version.get.major == 1
    check f.version.get.minor == 3

  test "minimal domain with one command":
    let f = parsePdl("""
domain Foo
  command ping
""")
    check f.domains.len == 1
    let d = f.domains[0]
    check d.name == "Foo"
    check d.commands.len == 1
    check d.commands[0].name == "ping"

  test "modifiers on domain and members":
    let f = parsePdl("""
experimental deprecated domain Foo
  experimental type Id extends string
  deprecated command go
  experimental event tick
""")
    let d = f.domains[0]
    check d.experimental and d.deprecated
    check d.types[0].experimental
    check d.types[0] of PdlAliasDecl
    check d.commands[0].deprecated
    check d.events[0].experimental

  test "object type with properties":
    let f = parsePdl("""
domain Foo
  type Point extends object
    properties
      # x coordinate
      integer x
      optional integer y
""")
    let t = f.domains[0].types[0]
    check t of PdlObjectDecl
    let o = PdlObjectDecl(t)
    check o.properties.len == 2
    check o.properties[0].name == "x"
    check o.properties[0].doc == @["x coordinate"]
    check o.properties[1].optional
    check o.properties[1].typ of PdlPrimitiveType
    check PdlPrimitiveType(o.properties[1].typ).kind == ppInteger

  test "named enum type":
    let f = parsePdl("""
domain Foo
  type Color extends string
    enum
      red
      green
      blue
""")
    let t = f.domains[0].types[0]
    check t of PdlEnumDecl
    let e = PdlEnumDecl(t)
    check e.members.mapIt(it.name) == @["red", "green", "blue"]

  test "inline enum on a property":
    let f = parsePdl("""
domain Foo
  command go
    parameters
      enum mode
        slow
        fast
""")
    let cmd = f.domains[0].commands[0]
    check cmd.parameters.len == 1
    check cmd.parameters[0].name == "mode"
    check cmd.parameters[0].typ of PdlEnumType
    check PdlEnumType(cmd.parameters[0].typ).members.mapIt(it.name) ==
      @["slow", "fast"]

  test "array of qualified ref":
    let f = parsePdl("""
domain Foo
  command go
    returns
      array of Runtime.RemoteObject things
""")
    let r = f.domains[0].commands[0].returns[0]
    check r.typ of PdlArrayType
    let inner = PdlArrayType(r.typ).element
    check inner of PdlRefType
    check PdlRefType(inner).domain == some("Runtime")
    check PdlRefType(inner).name == "RemoteObject"

  test "command with redirect":
    let f = parsePdl("""
domain Foo
  experimental deprecated command bar
    redirect Other
    parameters
      string x
""")
    let cmd = f.domains[0].commands[0]
    check cmd.redirect == some("Other")
    check cmd.parameters.len == 1

  test "depends on":
    let f = parsePdl("""
domain Foo
  depends on Bar
  depends on Baz
""")
    check f.domains[0].dependsOn == @["Bar", "Baz"]

  test "doc comments attach to the next declaration":
    let f = parsePdl("""
domain Foo
  # First line.
  # Second line.
  type T extends string
""")
    check f.domains[0].types[0].doc == @["First line.", "Second line."]

  test "blank line detaches doc block":
    let f = parsePdl("""
domain Foo
  # floating

  type T extends string
""")
    check f.domains[0].types[0].doc.len == 0

  test "raises on tab indent":
    expect PdlParseError:
      discard parsePdl("domain Foo\n\tcommand go\n")

  test "raises with line number on bad token":
    try:
      discard parsePdl("""
domain Foo
  type T extends object
    properties
      garbage
""")
      check false
    except PdlParseError as e:
      check e.line == 4

suite "pdl parser — corpus":

  test "every shipped .pdl file parses":
    var files: seq[string]
    files.add PdlRoot / "browser_protocol.pdl"
    files.add PdlRoot / "js_protocol.pdl"
    for path in walkDirRec(PdlRoot / "domains"):
      if path.endsWith(".pdl"): files.add path
    check files.len > 0

    for path in files:
      try:
        let f = parsePdlFile(path)
        # A file may have only includes (browser_protocol.pdl) or only
        # domains; it must have at least one of the two.
        check f.domains.len + f.includes.len > 0
      except PdlParseError as e:
        checkpoint "failed in " & path & ": " & e.msg
        raise

  test "browser_protocol.pdl with followIncludes pulls every domain":
    let f = parsePdlFile(
      PdlRoot / "browser_protocol.pdl", followIncludes = true)
    check f.domains.len > 30
    check f.domains.anyIt(it.name == "DOM")
    check f.domains.anyIt(it.name == "Network")

  test "Console domain shape from js_protocol.pdl":
    let f = parsePdlFile(PdlRoot / "js_protocol.pdl")
    let console = f.domains.filterIt(it.name == "Console")
    check console.len == 1
    check console[0].deprecated
    check console[0].dependsOn == @["Runtime"]
    let cm = console[0].types.filterIt(it.name == "ConsoleMessage")
    check cm.len == 1
    check cm[0] of PdlObjectDecl
