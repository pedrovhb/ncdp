## Tests for the codegen name-mangling rules. The cases here are
## seeded from real PDL identifiers — see `splitWireWord` in
## `src/gen/cdp/names.nim` for the conventions.

import std/[tables, unittest]
import gen/cdp/names

suite "splitWireWord":

  test "kebab and snake separators":
    check splitWireWord("console-api") == @["console", "api"]
    check splitWireWord("a_rate") == @["a", "rate"]
    check splitWireWord("auto_subframe") == @["auto", "subframe"]

  test "camelCase humps":
    check splitWireWord("getDomains") == @["get", "domains"]
    check splitWireWord("frameAttached") == @["frame", "attached"]

  test "PascalCase humps":
    check splitWireWord("RemoteObject") == @["remote", "object"]
    check splitWireWord("AccessDenied") == @["access", "denied"]

  test "acronyms before lowercase":
    check splitWireWord("GPUDevice") == @["gpu", "device"]
    check splitWireWord("XMLHttpRequest") == @["xml", "http", "request"]
    check splitWireWord("DOMSnapshot") == @["dom", "snapshot"]

  test "trailing acronym":
    check splitWireWord("getDOM") == @["get", "dom"]

  test "digit suffix rides preceding word":
    check splitWireWord("yuv420") == @["yuv420"]
    check splitWireWord("rfc7234") == @["rfc7234"]

  test "single word":
    check splitWireWord("color") == @["color"]
    check splitWireWord("Color") == @["color"]

  test "empty":
    check splitWireWord("").len == 0

suite "case conversions":

  test "toPascal":
    check toPascal("console-api") == "ConsoleApi"
    check toPascal("getDomains") == "GetDomains"
    check toPascal("GPUDevice") == "GpuDevice"
    check toPascal("yuv420") == "Yuv420"

  test "toCamel":
    check toCamel("console-api") == "consoleApi"
    check toCamel("RemoteObject") == "remoteObject"
    check toCamel("getDomains") == "getDomains"

  test "toSnake":
    check toSnake("DOMSnapshot") == "dom_snapshot"
    check toSnake("Page") == "page"
    check toSnake("SystemInfo") == "system_info"

suite "module file names":

  test "module names are snake_case":
    check moduleFileName("Page") == "page"
    check moduleFileName("DOMSnapshot") == "dom_snapshot"
    check moduleFileName("SystemInfo") == "system_info"
    check moduleFileName("IO") == "io"

suite "enum members":

  test "wire spellings become Pascal-cased members":
    # Pure enums (see emit.nim) mean members live under
    # `Type.Member`, so the bare wire spelling is enough — no need
    # for a per-type prefix.
    check enumMemberName("SubsamplingFormat", "yuv420") == "Yuv420"
    check enumMemberName("ImageType", "jpeg") == "Jpeg"
    check enumMemberName("InitiatorType", "console-api") == "ConsoleApi"
    check enumMemberName("ResourceType", "Document") == "Document"
    check enumMemberName("AnyType", "auto_subframe") == "AutoSubframe"

suite "field mangling":

  test "passes through ordinary names":
    let f = mangleField("kind")
    check f.nim == "kind"
    check not f.needsBackticks

  test "flags Nim keywords":
    let f = mangleField("type")
    check f.nim == "type"
    check f.needsBackticks
    let g = mangleField("method")
    check g.needsBackticks
    let h = mangleField("static")
    check h.needsBackticks

  test "result is treated as reserved":
    # `result` is the implicit return variable in every proc;
    # using it as a field name would shadow it. We treat it as
    # keyword-equivalent.
    let f = mangleField("result")
    check f.needsBackticks

suite "keyword detection":

  test "common keywords":
    check isNimKeyword("type")
    check isNimKeyword("method")
    check isNimKeyword("var")
    check isNimKeyword("let")

  test "non-keywords":
    check not isNimKeyword("foo")
    check not isNimKeyword("Type")  # case-sensitive
    check not isNimKeyword("getDomains")

suite "registry round-trip":

  test "recordEnum stores mapping":
    let reg = newRegistry()
    reg.recordEnum("SubsamplingFormat", [
      ("Yuv420", "yuv420"),
      ("Yuv422", "yuv422"),
      ("Yuv444", "yuv444"),
    ])
    check reg.enums.hasKey("SubsamplingFormat")
    check reg.enums["SubsamplingFormat"].members.len == 3
    check reg.enums["SubsamplingFormat"].members[0] == ("Yuv420", "yuv420")

  test "recordEnum raises on Nim-aliasing members":
    # `xAutoBookmark` and `xAuto_Bookmark` are the same Nim identifier
    # (style-insensitive past the first char). Two PDL wire spellings
    # that mangle to such a pair would silently fuse — refuse loudly.
    let reg = newRegistry()
    expect EnumCollisionError:
      reg.recordEnum("Bogus", [
        ("xAutoBookmark", "autoBookmark"),
        ("xAuto_Bookmark", "auto_bookmark"),
      ])

suite "Nim identifier equality":

  test "style insensitivity past first char":
    check nimSameIdent("autoBookmark", "auto_bookmark")
    check nimSameIdent("autoBookmark", "AUTOBOOKMARK") == false
      # First char case is significant.
    check nimSameIdent("fooBar", "foobar")
    check nimSameIdent("fooBar", "Foobar") == false
