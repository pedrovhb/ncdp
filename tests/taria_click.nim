import std/[base64, strutils, unittest]

import chronos
import cdp/chrome
import ncdp/[aria, browser]

const CoveredLinkHtml = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>covered link click repro</title>
  <style>
    body { margin: 0; font-family: sans-serif; }
    a { display: inline-block; margin: 80px; padding: 20px; }
    #overlay {
      position: fixed;
      inset: 0;
      z-index: 10;
      background: rgba(0, 0, 0, .01);
    }
  </style>
</head>
<body>
  <a href="#target" onclick="window.targetClicked = true">Target Link</a>
  <div id="overlay" onclick="window.overlayClicked = true"></div>
  <script>
    window.targetClicked = false;
    window.overlayClicked = false;
  </script>
</body>
</html>
"""

proc coveredLinkUrl(): string =
  "data:text/html;charset=utf-8;base64," & base64.encode(CoveredLinkHtml)

proc newTestBrowser(): Future[Browser] {.async: (raises: [CatchableError]).} =
  var opts = initLaunchOptions()
  opts.port = 29222
  opts.extraArgs = @["--no-sandbox"]
  result = await launchBrowser(opts)

proc targetLinkRef(page: Page): Future[string] {.
    async: (raises: [CatchableError]).} =
  discard await page.ariaSnapshot()
  for row in await page.actionRefs():
    if row.label == "Target Link":
      return row.refId
  raise newException(NcdpError, "Target Link ref not found")

proc runCoveredLinkBlocked(): Future[tuple[msg, target, overlay: string]] {.
    async: (raises: [CatchableError]).} =
  let browser = await newTestBrowser()
  var page: Page = nil
  try:
    page = await browser.newPage(coveredLinkUrl())
    let refId = await page.targetLinkRef()
    try:
      result.msg = await page.clickRef(refId)
    except CatchableError as e:
      result.msg = e.msg
    result.target = await page.evalString("String(window.targetClicked)")
    result.overlay = await page.evalString("String(window.overlayClicked)")
  finally:
    if not page.isNil:
      await page.close()
    await browser.close()

suite "ARIA click integration":
  test "covered link click is rejected before overlay receives input":
    let observed = waitFor runCoveredLinkBlocked()
    check "click intercepted" in observed.msg
    check "#overlay" in observed.msg
    check observed.target == "false"
    check observed.overlay == "false"
