## ex_03_browser_via_codegen — drives a real chrome through the
## **codegen-produced** bindings under ``src/cdp/gen/``. End-to-end
## proof that the generator's output works against a live browser.
##
## Calls a few different commands to exercise the various code paths
## (no-params, optional params, complex result type).
##
## Usage::
##
##   nim c -d:ssl -r examples/raw/ex_03_browser_via_codegen.nim
##   nim c -d:ssl -r examples/raw/ex_03_browser_via_codegen.nim -- --discover
##
import std/[options, parseopt, strformat, strutils]
import chronos
import cdp/[chrome, transport]
import cdp/gen/browser as genBrowser
import cdp/gen/target as genTarget

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
        echo "usage: ex_03 [--launch|--discover] [--host=H] [--port=N]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc demo(client: CDPClient) {.async: (raises: [CatchableError]).} =
  echo "--- Browser.getVersion (no params, complex result) ---"
  let v = await genBrowser.getVersion(client)
  echo &"  product:         {v.product}"
  echo &"  revision:        {v.revision}"
  echo &"  protocolVersion: {v.protocolVersion}"
  echo &"  jsVersion:       {v.jsVersion}"

  echo "--- Target.getTargets (optional param, list result) ---"
  let targets = await genTarget.getTargets(
    client, filter = none(TargetTargetFilter))
  echo &"  {targets.targetInfos.len} target(s):"
  for t in targets.targetInfos:
    echo &"    [{t.`type`}] {t.title} — {t.url}"

proc runDiscover(args: Args) {.async: (raises: [CatchableError]).} =
  let url = await chrome.discover(args.host, args.port)
  echo "discovered: ", url
  let client = await transport.connect(url)
  try:
    await demo(client)
  finally:
    await transport.close(client)

proc runLaunch(args: Args) {.async: (raises: [CatchableError]).} =
  var opts = initLaunchOptions()
  opts.host = args.host
  opts.port = args.port
  let cp = await chrome.launch(opts)
  echo "launched: ", cp.wsUrl
  try:
    let client = await transport.connect(cp.wsUrl)
    try:
      await demo(client)
    finally:
      await transport.close(client)
  finally:
    await chrome.terminate(cp)

when isMainModule:
  let args = parseArgs()
  case args.mode
  of mLaunch: waitFor runLaunch(args)
  of mDiscover: waitFor runDiscover(args)
