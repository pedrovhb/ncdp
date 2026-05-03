# Package
version       = "0.1.1"
author        = "pedro"
description   = "Nim Chrome DevTools Protocol bindings — code generator and runtime"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.2.8"
requires "chronos >= 4.2.2"
requires "chronicles >= 0.12.2"
requires "https://github.com/pedrovhb/nws_client.git == 0.1.0"

task gen, "Regenerate CDP bindings from bundled PDL files":
  exec "nim c -r --hints:off src/gen/cdp/driver.nim"

task bundleMarkdown, "Bundle the browser-side Readability HTML-to-Markdown helper":
  exec "deno bundle --platform browser --no-check --output resources/readability/markdown.js resources/readability/markdown.ts"

task docs, "Generate local API docs into htmldocs/":
  exec "nim doc --project --index:on --outdir:htmldocs src/ncdp.nim"
  exec "nim doc --index:on --outdir:htmldocs src/cdp/transport.nim"
  exec "nim doc --index:on --outdir:htmldocs src/cdp/jsonhooks.nim"

task examples, "Compile numbered examples without running Chrome":
  exec "nim c --hints:off examples/ex_01_browser_get_version.nim"
  exec "nim c --hints:off examples/ex_02_page_goto_eval_screenshot.nim"
  exec "nim c --hints:off examples/ex_03_aria_snapshot.nim"
  exec "nim c --hints:off examples/raw/ex_01_parse_summary.nim"
  exec "nim c --hints:off examples/raw/ex_02_call_browser_getVersion.nim"
  exec "nim c --hints:off examples/raw/ex_03_browser_via_codegen.nim"
  exec "nim c --hints:off examples/raw/ex_04_navigate_eval_screenshot.nim"
  exec "nim c --hints:off examples/raw/ex_05_aria_snapshot.nim"

task fullCompileCheck, "Run slow generated-corpus nim check":
  exec "nim c -r -d:ncdpFullCompileCheck --hints:off tests/temit_compile.nim"

task test, "Run the test suite":
  exec "nim c -r --hints:off tests/tpdl_parser.nim"
  exec "nim c -r --hints:off tests/tchrome.nim"
  exec "nim c -r --hints:off tests/ttransport.nim"
  exec "nim c -r --hints:off tests/tnames.nim"
  exec "nim c -r --hints:off tests/tnames_corpus.nim"
  exec "nim c -r --hints:off tests/temit.nim"
  exec "nim c -r --hints:off tests/temit_compile.nim"
