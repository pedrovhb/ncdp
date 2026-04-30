import std/[base64, strutils, unittest]

import chronos
import cdp/chrome
import ncdp/[aria, browser]

const ArticleText = """
Reader mode should keep this article body and remove the surrounding clutter.
The page includes navigation links, a sidebar promotion, and footer text that
should not dominate a compact observation for an agent. This paragraph is long
enough to help Mozilla Readability choose the article container confidently.

The second paragraph repeats the central topic in ordinary prose. It describes
how reduced snapshots should expose the main story while keeping actionable
links inside the article connected to the original live page. That live mapping
matters because clickRef sends real Chrome DevTools Protocol mouse input.

The final paragraph adds more natural language content so the default character
threshold is satisfied without relying on markup tricks. A browser automation
script can still ask for the full page when it needs navigation, forms, or other
controls outside the detected article.
"""

const ReadabilityHtml = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Readable Article Fixture</title>
  <style>
    body { margin: 0; font-family: sans-serif; }
    nav, aside, footer { padding: 1rem; }
    article { max-width: 42rem; margin: 2rem auto; }
    a { display: inline-block; padding: .5rem; }
    .css-hidden { display: none; }
    .no-click { pointer-events: none; }
  </style>
</head>
<body>
  <nav aria-label="Site navigation">
    <a href="#noise">Navigation Noise</a>
  </nav>
  <article>
    <h1>Readable Article Fixture</h1>
    <p>""" & ArticleText & """</p>
    <p><span class="css-hidden">Hidden Article Text</span></p>
    <p><a href="#article-link" onclick="window.articleClicked = true">Article Link</a></p>
    <p><a class="no-click" href="#dead-link">Dead Link</a></p>
  </article>
  <aside>Sidebar Promo should only appear in the full-page snapshot.</aside>
  <footer>Footer Boilerplate</footer>
  <script>window.articleClicked = false;</script>
</body>
</html>
"""

proc readabilityUrl(): string =
  "data:text/html;charset=utf-8;base64," & base64.encode(ReadabilityHtml)

proc newTestBrowser(): Future[Browser] {.async: (raises: [CatchableError]).} =
  var opts = initLaunchOptions()
  opts.port = 29223
  opts.extraArgs = @["--no-sandbox"]
  result = await launchBrowser(opts)

proc articleLinkRef(page: Page): Future[string] {.
    async: (raises: [CatchableError]).} =
  for row in await page.actionRefs():
    if row.label == "Article Link":
      return row.refId
  raise newException(NcdpError, "Article Link ref not found")

proc runReadabilitySnapshots(): Future[tuple[reduced, full, clicked: string;
                                            deadAction, deadLinkListed: bool]] {.
    async: (raises: [CatchableError]).} =
  let browser = await newTestBrowser()
  var page: Page = nil
  try:
    page = await browser.newPage(readabilityUrl())
    result.reduced = await page.ariaSnapshot()
    result.full = await page.ariaSnapshot(
      initAriaOptions(root = AriaSnapshotRoot.FullPage))
    let refId = await page.articleLinkRef()
    for row in await page.actionRefs():
      if row.label == "Dead Link":
        result.deadAction = true
    for link in await page.links():
      if link.text == "Dead Link" and link.refId.len == 0:
        result.deadLinkListed = true
    discard await page.clickRef(refId)
    result.clicked = await page.evalString("String(window.articleClicked)")
  finally:
    if not page.isNil:
      await page.close()
    await browser.close()

suite "ARIA Readability integration":
  test "default snapshot is reduced and refs target live elements":
    let observed = waitFor runReadabilitySnapshots()
    check "Reader mode should keep this article body" in observed.reduced
    check "Article Link" in observed.reduced
    check "Dead Link" in observed.reduced
    check "Hidden Article Text" notin observed.reduced
    check "Sidebar Promo" notin observed.reduced
    check "Navigation Noise" in observed.full
    check "Sidebar Promo" in observed.full
    check not observed.deadAction
    check observed.deadLinkListed
    check observed.clicked == "true"
