## ex_02_page_goto_eval_screenshot — recommended Page facade workflow.
##
## Opens a page, navigates, evaluates JavaScript, and captures a screenshot
## without exposing generated-CDP option plumbing.
##
## Usage::
##
##   nim c -d:ssl -r examples/ex_02_page_goto_eval_screenshot.nim
##   nim c -d:ssl -r examples/ex_02_page_goto_eval_screenshot.nim -- --url=https://news.ycombinator.com
##   nim c -d:ssl -r examples/ex_02_page_goto_eval_screenshot.nim -- --discover

import std/[parseopt, strformat, strutils]
import chronos
import ncdp/browser

type
  Mode = enum mLaunch, mDiscover

  Args = object
    mode: Mode
    host: string
    port: int
    url: string
    outPath: string

proc parseArgs(): Args =
  result = Args(mode: mLaunch, host: "127.0.0.1", port: 9222,
                url: "https://example.com",
                outPath: "/tmp/ncdp-screenshot.png")
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
      of "url": result.url = p.val
      of "out", "o": result.outPath = p.val
      of "help", "h":
        echo "usage: ex_02 [--launch|--discover] [--host=H] [--port=N] " &
             "[--url=URL] [--out=PATH]"
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
    let page = await br.newPage()
    try:
      await page.goto(args.url)

      let title = await page.evalString("document.title")
      echo &"title: {title}"

      let body = await page.evalString(
        "document.body ? document.body.innerText.slice(0, 200) : ''")
      echo "body excerpt: |"
      for line in body.splitLines:
        echo "  ", line

      await page.screenshot(args.outPath)
      echo &"screenshot: {args.outPath}"
    finally:
      await page.close()
  finally:
    await br.close()

when isMainModule:
  waitFor main()
