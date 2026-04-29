## ex_02_call_browser_getVersion — open a CDP connection and call
## `Browser.getVersion`. The end-to-end smoke test for the runtime.
##
## (`Schema.getDomains` would have been an even smaller demo, but it
## lives at page-target scope, and the debugger endpoint chrome opens
## for us is browser-scope. `Browser.getVersion` is the canonical
## "ping" that needs no setup.)
##
## Usage::
##
##   # Spawn a fresh headless Chrome ourselves (no args at all):
##   nim c -d:ssl -r examples/raw/ex_02_call_browser_getVersion.nim
##
##   # Use an already-running browser:
##   nim c -d:ssl -r examples/raw/ex_02_call_browser_getVersion.nim -- --discover
##
##   # Override host/port, in either mode:
##   ... -- --port 9333
##   ... -- --discover --host 127.0.0.1 --port 9222
##
## Set ``NCDP_CHROME=/path/to/chrome`` if your binary isn't on PATH.

import std/[parseopt, strformat, strutils]
import chronos
import cdp/[chrome, transport]
import cdp/gen/browser

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
        echo "usage: ex_02 [--launch|--discover] [--host=H] [--port=N]"
        quit 0
      else: quit "unknown option: --" & p.key
    of cmdArgument: quit "unexpected positional: " & p.key

proc printVersion(client: CDPClient) {.async: (raises: [CatchableError]).} =
  let v = await client.getVersion()
  echo &"  product:         {v.product}"
  echo &"  revision:        {v.revision}"
  echo &"  protocolVersion: {v.protocolVersion}"
  echo &"  jsVersion:       {v.jsVersion}"
  echo &"  userAgent:       {v.userAgent}"

proc runDiscover(args: Args) {.async: (raises: [CatchableError]).} =
  let url = await chrome.discover(args.host, args.port)
  echo "discovered: ", url
  let client = await transport.connect(url)
  try:
    await printVersion(client)
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
      await printVersion(client)
    finally:
      await transport.close(client)
  finally:
    await chrome.terminate(cp)

when isMainModule:
  let args = parseArgs()
  case args.mode
  of mLaunch: waitFor runLaunch(args)
  of mDiscover: waitFor runDiscover(args)
