## Name mangling: PDL identifiers → idiomatic Nim identifiers.
##
## The PDL grammar uses several spelling conventions on the wire:
##
## * Domain names — already PascalCase (`Page`, `DOMSnapshot`).
## * Type names — PascalCase (`RemoteObject`, `GPUDevice`).
## * Command and event names — camelCase (`getDomains`, `frameAttached`).
## * Parameter and field names — camelCase, occasionally with a Nim
##   keyword as the spelling (`type`, `method`, `static`, `result`, ...).
## * Enum members — wildly inconsistent: `camelCase`, `PascalCase`,
##   `kebab-case` (`console-api`, `auto_subframe`), `snake_case`
##   (`a_rate`, `auto_bookmark`), and plain lowercase (`yuv420`).
##
## The job of this module is to produce stable, valid, conflict-free
## Nim identifiers from those wire spellings AND remember the mapping
## both ways so JSON hooks can reverse it. Stability matters because
## downstream code imports these names; idempotence matters because
## codegen reruns must produce identical output.
##
## ## Rules
##
## 1. **Domains, types**: pass through unchanged (already PascalCase).
##    `Page` → `Page`, `GPUDevice` → `GPUDevice`. The only adjustment
##    is on the domain *module* file name, which is `snake_case`d
##    (`DOMSnapshot` → `dom_snapshot.nim`) for filesystem hygiene.
## 2. **Commands, events**: pass through unchanged
##    (`getDomains` → `getDomains`).
## 3. **Field / parameter names**: pass through, but if the result is
##    a Nim keyword, wrap in backticks (`type` → `` `type` ``).
##    Tracked at codegen time, not here — `mangleField` returns the
##    bare name and a `needsBackticks` flag.
## 4. **Enum members**: prefix with a 2-3 letter type-name abbreviation
##    (lowercased), then camelize the wire spelling. The type prefix
##    avoids collisions when two enums share a member spelling
##    (`Page.PermissionType.geolocation` vs `Network.SomeFlag.geo`).
##    Example: type `SubsamplingFormat`, member `yuv420` →
##    `sfYuv420`. type `ResourcePriority`, member `VeryHigh` →
##    `rpVeryHigh`. type `ConsoleAPICalled.Type` (anonymous), member
##    `console-api` (under our naming for `type`-of-event) →
##    something like `casConsoleApi` once the type gets a name.
##
## ## Reverse map
##
## Every enum-member mangling is recorded in a per-type table so the
## generated `to/fromJsonHook` overload can emit the original wire
## spelling. The table is keyed by Nim type name and indexed by the
## enum's *ordinal*. See `EnumWireMap` below.

import std/[strutils, tables]

# ----------------------------------------------------- Nim identity -------
#
# Nim treats identifiers as equal if they have the same first character
# and the rest is equal under: lowercase + drop-underscores. So
# `auto_bookmark`, `autoBookmark`, and `autobookmark` all name the same
# symbol — but `AutoBookmark` is different (first char differs).
#
# `std/strutils.nimIdentNormalize` is the canonical lowering. We use it
# to detect collisions in generated enum-member sets at codegen time:
# two PDL members whose mangled forms normalize to the same string would
# silently fuse in the emitted enum.

proc nimSameIdent*(a, b: string): bool =
  ## True iff `a` and `b` denote the same Nim identifier.
  nimIdentNormalize(a) == nimIdentNormalize(b)

# ---------------------------------------------------------- keywords ------

const NimKeywords* = [
  "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct",
  "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
  "for", "from", "func", "if", "import", "in", "include", "interface", "is",
  "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
  "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return",
  "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
  "when", "while", "xor", "yield",
  # Not technically keywords but special:
  "result"
]

proc isNimKeyword*(s: string): bool =
  for k in NimKeywords:
    if k == s: return true
  false

# ---------------------------------------------------------- helpers -------

proc isAsciiUpper(c: char): bool {.inline.} = c >= 'A' and c <= 'Z'
proc isAsciiLower(c: char): bool {.inline.} = c >= 'a' and c <= 'z'
proc isAsciiDigit(c: char): bool {.inline.} = c >= '0' and c <= '9'
proc isAsciiLetter(c: char): bool {.inline.} = isAsciiUpper(c) or isAsciiLower(c)

proc capFirst(s: string): string =
  if s.len == 0: return s
  result = s
  if isAsciiLower(result[0]):
    result[0] = chr(ord(result[0]) - 32)

proc lowerFirst(s: string): string =
  if s.len == 0: return s
  result = s
  if isAsciiUpper(result[0]):
    result[0] = chr(ord(result[0]) + 32)

# ---------------------------------------------------------- splits --------

proc splitWireWord*(s: string): seq[string] =
  ## Split a wire-spelling identifier into lowercased words.
  ##
  ## Handles three flavours observed in CDP PDL:
  ##
  ## * Hyphen / underscore separators: `console-api` → `@["console","api"]`,
  ##   `a_rate` → `@["a","rate"]`.
  ## * camelCase / PascalCase humps: `getDomains` → `@["get","domains"]`,
  ##   `RemoteObject` → `@["remote","object"]`.
  ## * Acronym runs are kept whole when followed by lower-case:
  ##   `GPUDevice` → `@["gpu","device"]`, `XMLHttpRequest` →
  ##   `@["xml","http","request"]`.
  ## * Digit runs ride with the preceding letters: `yuv420` →
  ##   `@["yuv420"]`, not `@["yuv","420"]`.
  ##
  ## All emitted parts are pure ASCII lowercase. Empty input returns
  ## `@[]`.
  result = @[]
  if s.len == 0: return
  # Track the *original* case of the last consumed character so the
  # buffer's content (always lowercased) doesn't mislead the run-detection
  # logic. `prev` is `'\0'` at start.
  var i = 0
  var buf = ""
  var prev = '\0'
  while i < s.len:
    let c = s[i]
    if c == '-' or c == '_':
      if buf.len > 0: result.add buf; buf = ""
      prev = '\0'
      inc i
      continue
    if isAsciiUpper(c):
      if buf.len > 0 and (isAsciiLower(prev) or isAsciiDigit(prev)):
        # lower→upper or digit→upper: definitely a word boundary.
        result.add buf; buf = ""
      elif buf.len > 0 and isAsciiUpper(prev):
        # upper→upper: inside an acronym run. Only break if the NEXT
        # char is lower — then this upper starts the next word and the
        # acronym ended at `prev`.
        if i + 1 < s.len and isAsciiLower(s[i+1]):
          result.add buf; buf = ""
      buf.add chr(ord(c) + 32) # lowercase
    elif isAsciiLower(c) or isAsciiDigit(c):
      buf.add c
    else:
      discard # unexpected punctuation
    prev = c
    inc i
  if buf.len > 0: result.add buf

# ---------------------------------------------------------- public --------

proc toPascal*(s: string): string =
  ## `console-api` → `ConsoleApi`, `getDomains` → `GetDomains`,
  ## `GPUDevice` → `GpuDevice`. Stable under repeat application.
  for w in splitWireWord(s):
    result.add capFirst(w)

proc toCamel*(s: string): string =
  ## `console-api` → `consoleApi`, `RemoteObject` → `remoteObject`.
  let parts = splitWireWord(s)
  if parts.len == 0: return ""
  result = parts[0]
  for i in 1 ..< parts.len:
    result.add capFirst(parts[i])

proc toSnake*(s: string): string =
  ## `DOMSnapshot` → `dom_snapshot`. Used for module file names.
  splitWireWord(s).join("_")

# ---------------------------------------------------------- domains -------

proc moduleFileName*(domain: string): string =
  ## Domain `DOMSnapshot` → file basename `dom_snapshot` (no `.nim`).
  toSnake(domain)

proc typeName*(domain, name: string): string =
  ## PDL type name passes through as Nim type name. Domain qualifier
  ## is unused in the same-domain case but kept here for symmetry —
  ## cross-domain refs are emitted as `otherDomain.TypeName` directly
  ## by the emitter, not by a global rename.
  ##
  ## We do force a non-empty result; PDL guarantees uppercase-first
  ## type names but a defensive capFirst guards against future drift.
  capFirst(name)

# ---------------------------------------------------------- enum prefix ---

proc enumPrefix*(typeName: string): string =
  ## A 2-3 letter lowercase abbreviation derived from a type name.
  ## Used to namespace enum members so two enums can share a wire
  ## spelling without colliding in Nim's flat enum-member namespace.
  ##
  ## Strategy: take the first letter of each word in `typeName`,
  ## lowercase, capped at 3. If the type is one-word and short, fall
  ## back to the first 2 letters lowercased.
  ##
  ## * `SubsamplingFormat` → `sf`
  ## * `ImageType`         → `it`
  ## * `ResourcePriority`  → `rp`
  ## * `Color`             → `co`
  ## * `GPUDevice`         → `gd`
  let parts = splitWireWord(typeName)
  if parts.len >= 2:
    var p = ""
    for i in 0 ..< min(parts.len, 3):
      if parts[i].len > 0: p.add parts[i][0]
    return p
  if parts.len == 1 and parts[0].len >= 2:
    return parts[0][0..1]
  if parts.len == 1 and parts[0].len == 1:
    return parts[0]
  "x"

proc enumMemberName*(typeName, wireMember: string): string =
  ## `(SubsamplingFormat, "yuv420")` → `sfYuv420`.
  ## `(ResourceType, "Document")` → `rtDocument`.
  ## `(InitiatorType, "console-api")` → `itConsoleApi`.
  let pre = enumPrefix(typeName)
  pre & toPascal(wireMember)

# ---------------------------------------------------------- fields --------

type
  FieldName* = object
    nim*: string         ## bare identifier, e.g. `type` or `kind`
    needsBackticks*: bool
      ## true iff `nim` is a Nim keyword and must be quoted at the
      ## declaration AND access sites.

proc mangleField*(wireName: string): FieldName =
  ## Field / parameter mangling. CDP wire spelling is already
  ## camelCase; we pass through, but flag Nim keywords so the emitter
  ## can wrap with backticks. We deliberately do NOT prefix or rename
  ## keyword fields — the wire name has to round-trip through JSON,
  ## and `json.toJson` uses the (backticked) field name verbatim.
  result.nim = wireName
  result.needsBackticks = isNimKeyword(wireName)

# ---------------------------------------------------------- wire map ------

type
  EnumWireMap* = object
    ## Recorded for each generated Nim enum so its `to/fromJsonHook`
    ## can map between Nim ordinal and original wire spelling.
    typeName*: string
    members*: seq[(string, string)]
      ## (nimMemberName, wireSpelling), in declaration order.

  NameRegistry* = ref object
    ## Cross-module bookkeeping. Currently only enums; types and
    ## fields are emitted directly without a registry round-trip.
    enums*: Table[string, EnumWireMap]

proc newRegistry*(): NameRegistry =
  NameRegistry(enums: initTable[string, EnumWireMap]())

type
  EnumCollisionError* = object of CatchableError
    ## Raised by `recordEnum` when two member spellings normalize to
    ## the same Nim identifier. Indicates a name-mangling rule that
    ## must be revised before codegen can emit this enum.

proc recordEnum*(reg: NameRegistry; typeName: string;
                 members: openArray[(string, string)]) =
  ## Adds (or replaces) the wire-mapping entry for `typeName`. Raises
  ## `EnumCollisionError` if any two Nim member names alias under
  ## Nim's identifier-equality rules — that would silently fuse them
  ## in the emitted enum.
  var em = EnumWireMap(typeName: typeName)
  for m in members: em.members.add m
  for i in 0 ..< em.members.len:
    for j in i + 1 ..< em.members.len:
      if nimSameIdent(em.members[i][0], em.members[j][0]):
        raise newException(EnumCollisionError,
          "enum '" & typeName & "': members '" & em.members[i][0] &
          "' (wire '" & em.members[i][1] & "') and '" &
          em.members[j][0] & "' (wire '" & em.members[j][1] &
          "') alias under Nim's identifier rules")
  reg.enums[typeName] = em
