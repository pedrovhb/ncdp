# Package
version       = "0.1.0"
author        = "pedro"
description   = "Nim Chrome DevTools Protocol bindings — code generator and runtime"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.2.8"
requires "chronos >= 4.2.2"
requires "chronicles >= 0.12.2"
# nws_client is consumed via a path switch in config.nims (see /app/nws_client).

task test, "Run the test suite":
  exec "nim c -r --hints:off tests/tpdl_parser.nim"
  exec "nim c -r --hints:off tests/ttransport.nim"
  exec "nim c -r --hints:off tests/tnames.nim"
  exec "nim c -r --hints:off tests/tnames_corpus.nim"
  exec "nim c -r --hints:off tests/temit.nim"
  exec "nim c -r --hints:off tests/temit_compile.nim"
