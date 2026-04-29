## Focused tests for Chrome launcher helpers that do not start Chrome.

import std/[strutils, unittest]
import cdp/chrome

suite "chrome helpers":

  test "newTab URL is encoded as one query component":
    let path = newTabPathForTest("https://example.com/search?q=a b&x=1#frag")
    check path.startsWith("/json/new?")
    let payload = path["/json/new?".len .. ^1]
    check "?" notin payload
    check "&" notin payload
    check "#" notin payload
    check " " notin payload
    check "%3F" in payload
    check "%26" in payload
    check "%23" in payload
    check "+" in payload

  test "launch options discard Chrome output by default":
    check initLaunchOptions().chromeOutput == coDiscard
