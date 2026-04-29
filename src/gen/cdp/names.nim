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
  ## If the snake-cased name would be a Nim keyword (CDP has a
  ## `Cast` domain → `cast`), append ``_domain`` to disambiguate;
  ## Nim's ``import`` statement parses module names as identifiers
  ## and won't accept backticked or keyword names.
  result = toSnake(domain)
  if isNimKeyword(result):
    result &= "_domain"

proc typeName*(domain, name: string): string =
  ## Globally-unique Nim type name for a PDL type. Because every
  ## generated type lives in a single shared `gen/types.nim` module
  ## (the only way to break PDL's cross-domain type cycles in Nim's
  ## flat module-import model), names must be unique across the
  ## corpus — PDL has duplicate type names across domains
  ## (Network.RequestId vs Fetch.RequestId, etc.).
  ##
  ## So: prefix the bare PDL name with the (Pascal-cased) domain name.
  ## ``Network.RequestId`` → ``NetworkRequestId``;
  ## ``DOMSnapshot.NodeId`` → ``DomSnapshotNodeId``.
  toPascal(domain) & capFirst(name)

# ---------------------------------------------------------- enum prefix ---

proc enumMemberName*(typeName, wireMember: string): string =
  ## With pure enums (see `pragmas` in emit.nim), members are
  ## accessed as ``Type.member`` and do not pollute the module's
  ## flat namespace. We can therefore use the bare wire spelling,
  ## Pascal-cased, and rely on Nim's qualification rules for
  ## disambiguation.
  ##
  ## * `(SubsamplingFormat, "yuv420")`  → ``Yuv420``
  ## * `(ResourceType, "Document")`     → ``Document``
  ## * `(InitiatorType, "console-api")` → ``ConsoleApi``
  ##
  ## ``typeName`` is unused now but kept in the signature so the
  ## call sites stay readable and so future schemes (e.g. handling
  ## a `_` numeric prefix for enum members starting with digits)
  ## can use the type for context.
  discard typeName
  toPascal(wireMember)

# ---------------------------------------------------------- fields --------

type
  FieldName* = object
    nim*: string         ## bare identifier, e.g. `type` or `kind`
    needsBackticks*: bool
      ## true iff `nim` is a Nim keyword and must be quoted at the
      ## declaration AND access sites.

proc mangleField*(wireName: string): FieldName =
  ## Field mangling for object members. CDP wire spelling is already
  ## camelCase; we pass through, but flag Nim keywords so the emitter
  ## can wrap with backticks. We deliberately do NOT prefix or rename
  ## keyword fields — the wire name has to round-trip through JSON,
  ## and `json.toJson` uses the (backticked) field name verbatim.
  result.nim = wireName
  result.needsBackticks = isNimKeyword(wireName)

type
  ParamName* = object
    ## Result of `mangleParam`. ``nim`` is the identifier to use in
    ## the proc signature and any local references. ``wire`` is the
    ## original PDL name to use as the JSON key. Most of the time
    ## these are equal; they diverge for parameters that would
    ## shadow `result` (the implicit async return) or that are Nim
    ## keywords.
    nim*: string
    wire*: string
    needsBackticks*: bool

proc mangleParam*(wireName: string): ParamName =
  ## Like `mangleField` but for command **parameters**. Adds two
  ## extra rules on top of the field rules:
  ##
  ## 1. A parameter literally named ``result`` shadows the implicit
  ##    async return that chronos's macro injects into every async
  ##    proc — even void ones. Backticks don't save us; the symbol
  ##    is always shadowed. Rename to ``resultArg``. The JSON wire
  ##    key keeps the original spelling.
  ## 2. Otherwise, treat as a field: pass through, backtick if
  ##    keyword.
  result.wire = wireName
  if wireName == "result":
    result.nim = "resultArg"
    result.needsBackticks = false
  else:
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
    ## Raised by `recordEnum` when two members of the SAME enum
    ## normalize to the same Nim identifier — Nim would reject the
    ## type with a redefinition error (see
    ## `/references/Nim/tests/enum/tredefinition.nim`).
    ## Cross-enum collisions are NOT a problem because generated
    ## enums are emitted as `{.pure.}` — members live under
    ## `EnumType.Member`, not the flat module namespace.

proc recordEnum*(reg: NameRegistry; typeName: string;
                 members: openArray[(string, string)]) =
  ## Adds the wire-mapping entry for `typeName`. Raises
  ## `EnumCollisionError` if any two members within this one enum
  ## alias under Nim's identifier rules.
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
