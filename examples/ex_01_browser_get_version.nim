## ex_01_browser_get_version — the smallest high-level browser smoke test.
##
## Usage::
##
##   nim c -d:ssl -r examples/ex_01_browser_get_version.nim
##   nim c -d:ssl -r examples/ex_01_browser_get_version.nim -- --discover

import std/[parseopt, strformat, strutils]
import chronos
import ncdp/browser

type
  Mode = enum mLaunch, mDiscover

  Args = object
    mode: Mode
    host: string
    port: int

proc parseArgs(): Args =
  result = Args(mode: mLaunch, host: "127.0.0.1", port: 9222)
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      if p.key.len == 0: continue # separator from ``nim c -r file -- ...``
      case p.key
      of "discover", "d": result.mode = mDiscover
      of "launch", "l": result.mode = mLaunch
      of "host": result.host = p.val
      of "port": result.port = parseInt(p.val)
      of "help", "h":
        echo "usage: ex_01 [--launch|--discover] [--host=H] [--port=N]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc openBrowser(args: Args): Future[Browser] {.
    async: (raises: [CatchableError]).} =
  case args.mode
  of mLaunch:
    result = await launchBrowser(args.host, args.port)
  of mDiscover:
    result = await connectBrowser(args.host, args.port)

proc main() {.async: (raises: [CatchableError]).} =
  let args = parseArgs()
  let br = await openBrowser(args)
  try:
    let v = await br.version()
    echo &"product:         {v.product}"
    echo &"revision:        {v.revision}"
    echo &"protocolVersion: {v.protocolVersion}"
    echo &"jsVersion:       {v.jsVersion}"
    echo &"userAgent:       {v.userAgent}"
  finally:
    await br.close()

when isMainModule:
  waitFor main()
