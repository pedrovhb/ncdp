---
name: ARIA click hit-testing
description: ARIA refs may be semantically clickable while physically unreachable; clickRef must validate CDP mouse points with document.elementFromPoint.
type: project
---

`ncdp/aria.clickRef` sends real CDP mouse input, so the target must be the
topmost element at the click coordinate. ARIA snapshots can still expose
background links/buttons while a cookie dialog, iframe, modal backdrop, sticky
header, ad layer, or transparent overlay physically intercepts pointer input.

Do not treat "listed as clickable in the ARIA tree" as equivalent to
"reachable by a mouse click". The helper should scroll the element into view,
settle layout, inspect `getClientRects()`, and only return a point whose
`document.elementFromPoint(x, y)` result is the target element or one of its
descendants. If no candidate point passes the hit test, report a click
interception error with the topmost element summary instead of dispatching
input and returning a misleading success.

Regression coverage lives in `tests/taria_click.nim`. It is Chrome-backed and
opt-in rather than part of `nimble test`; run it with:

```sh
nim c -r --hints:off tests/taria_click.nim
```
