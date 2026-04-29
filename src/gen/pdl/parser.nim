## Parser for Chrome DevTools Protocol PDL files.
##
## PDL is line-oriented with significant 2-space indentation. The parser
## works in two passes:
##
## 1. Lex the source into a stream of ``Line`` records: each carries its
##    indentation level (in spaces), tokens split on whitespace, the
##    original 1-based line number, and whether it is a ``#`` comment.
## 2. Walk the stream with a recursive-descent driver that uses indent
##    levels to delimit blocks (rather than explicit ``begin``/``end``).
##
## Doc comments are ``#`` lines whose run immediately precedes a
## declaration at the same indent level; they attach as ``doc`` on the
## declaration. Other comments are dropped.

import std/[options, os, strutils]
import ./ast

type
  PdlParseError* = object of CatchableError
    ## Raised on any malformed input. ``line`` is the 1-based source line
    ## that triggered the error.
    line*: int

  Line = object
    indent: int
    tokens: seq[string]
    raw: string             # text after indent, useful for comment bodies
    lineNo: int
    isComment: bool
    isBlank: bool

  Parser = ref object
    lines: seq[Line]
    pos: int
    pendingDoc: seq[string] # doc-comment block accumulated by ``advanceDoc``

# --------------------------------------------------------------- helpers ----

proc raiseAt(lineNo: int; msg: string) {.noreturn.} =
  var e = newException(PdlParseError, "line " & $lineNo & ": " & msg)
  e.line = lineNo
  raise e

proc countIndent(s: string): int =
  for c in s:
    if c == ' ': inc result
    elif c == '\t': raiseAt(0, "tabs are not allowed in PDL files")
    else: break

proc lex(source: string): seq[Line] =
  ## First pass: split ``source`` into ``Line`` records. Trailing blanks
  ## and pure-whitespace lines become ``isBlank`` entries that the driver
  ## skips, but they reset the doc-comment accumulator so that a stray
  ## comment block above a blank line doesn't latch onto the next decl.
  var lineNo = 0
  for raw in source.splitLines():
    inc lineNo
    let stripped = raw.strip(leading = false, trailing = true)
    if stripped.len == 0:
      result.add Line(lineNo: lineNo, isBlank: true)
      continue
    let indent = countIndent(stripped)
    let body = stripped[indent .. ^1]
    if body.startsWith("#"):
      # ``# foo`` -> docText "foo"; bare ``#`` -> empty docText.
      let docText =
        if body.len >= 2 and body[1] == ' ': body[2 .. ^1]
        elif body.len >= 2: body[1 .. ^1]
        else: ""
      result.add Line(
        indent: indent, raw: docText, lineNo: lineNo, isComment: true)
    else:
      result.add Line(
        indent: indent,
        tokens: body.splitWhitespace(),
        raw: body,
        lineNo: lineNo)

# ----------------------------------------------------- cursor primitives ----

proc atEnd(p: Parser): bool = p.pos >= p.lines.len

proc current(p: Parser): Line =
  if p.atEnd: raiseAt(0, "unexpected end of file")
  p.lines[p.pos]

proc skipBlanks(p: Parser) =
  ## Skip blank lines. Blank lines flush the pending doc block: a comment
  ## separated from its declaration by an empty line is treated as floating
  ## trivia and discarded.
  while not p.atEnd and p.lines[p.pos].isBlank:
    if p.pendingDoc.len > 0: p.pendingDoc.setLen(0)
    inc p.pos

proc collectDoc(p: Parser; atIndent: int) =
  ## Consume a contiguous run of comment lines at ``atIndent`` and stash
  ## them in ``pendingDoc``. The next declaration at the same indent will
  ## claim them via ``takeDoc``.
  while not p.atEnd and p.lines[p.pos].isComment and
        p.lines[p.pos].indent == atIndent:
    p.pendingDoc.add p.lines[p.pos].raw
    inc p.pos

proc takeDoc(p: Parser): seq[string] =
  result = p.pendingDoc
  p.pendingDoc = @[]

proc skipTrivia(p: Parser; atIndent: int) =
  ## Combination skip used at the top of every block-iteration step. Any
  ## comment block found here may belong to the next declaration, so it
  ## is preserved in ``pendingDoc`` rather than dropped.
  while not p.atEnd:
    let l = p.lines[p.pos]
    if l.isBlank:
      if p.pendingDoc.len > 0: p.pendingDoc.setLen(0)
      inc p.pos
    elif l.isComment and l.indent == atIndent:
      collectDoc(p, atIndent)
    elif l.isComment:
      # comment at a different indent — not attachable here, drop it
      inc p.pos
    else:
      break

proc posOf(l: Line): PdlPos =
  PdlPos(line: l.lineNo, col: l.indent + 1)

# ---------------------------------------------------- modifier parsing ------

const TopModifiers = ["experimental", "deprecated"]

proc consumeModifiers(toks: seq[string]; idx: var int):
    tuple[experimental, deprecated: bool] =
  ## Strip leading ``experimental`` and ``deprecated`` keywords (in any
  ## order, each at most once) from ``toks`` starting at ``idx``.
  while idx < toks.len and toks[idx] in TopModifiers:
    case toks[idx]
    of "experimental": result.experimental = true
    of "deprecated": result.deprecated = true
    else: discard
    inc idx

# --------------------------------------------------- type-reference parser --

proc parseTypeRef(toks: seq[string]; idx: var int; lineNo: int): PdlType =
  ## Parses the type expression starting at ``toks[idx]``. Recognises:
  ##   * ``array of <ref>``
  ##   * primitives (``string``, ``integer``, ``number``, ``boolean``,
  ##     ``any``, ``binary``, ``object``)
  ##   * qualified or unqualified named refs (``Foo`` / ``Domain.Foo``)
  if idx >= toks.len:
    raiseAt(lineNo, "expected a type")
  let tok = toks[idx]
  inc idx
  if tok == "array":
    if idx >= toks.len or toks[idx] != "of":
      raiseAt(lineNo, "expected 'of' after 'array'")
    inc idx
    let inner = parseTypeRef(toks, idx, lineNo)
    return PdlArrayType(element: inner, pos: PdlPos(line: lineNo))
  let prim = primKindFromName(tok)
  if prim.isSome:
    return PdlPrimitiveType(kind: prim.get, pos: PdlPos(line: lineNo))
  let dot = tok.find('.')
  if dot >= 0:
    return PdlRefType(
      domain: some(tok[0 ..< dot]),
      name: tok[dot + 1 .. ^1],
      pos: PdlPos(line: lineNo))
  PdlRefType(domain: none(string), name: tok, pos: PdlPos(line: lineNo))

# ------------------------------------------------------------ enum block ----

proc parseEnumMembers(p: Parser; minIndent: int): seq[PdlEnumMember] =
  ## Reads identifiers — one per line — at the indent of the first member.
  ## The required indent must be ``>= minIndent``; the actual indent is
  ## locked in by the first member, since some upstream PDL files indent
  ## enum members 4 spaces inside an ``enum`` block instead of 2.
  var memberIndent = -1
  while true:
    if memberIndent == -1:
      # First member not yet seen — we don't know which indent the doc
      # comments will live at, so collect anything at ``minIndent`` or
      # deeper as candidate doc-comment trivia and let the next decl
      # claim it via ``takeDoc``.
      while not p.atEnd:
        let l = p.lines[p.pos]
        if l.isBlank:
          if p.pendingDoc.len > 0: p.pendingDoc.setLen(0)
          inc p.pos
        elif l.isComment and l.indent >= minIndent:
          p.pendingDoc.add l.raw
          inc p.pos
        elif l.isComment:
          inc p.pos     # comment outdented past the enum — drop
        else:
          break
    else:
      skipTrivia(p, memberIndent)
    if p.atEnd or p.current.indent < minIndent: break
    let l = p.current
    if memberIndent == -1:
      memberIndent = l.indent
    elif l.indent != memberIndent:
      if l.indent < memberIndent: break
      raiseAt(l.lineNo, "inconsistent indent inside enum")
    if l.tokens.len != 1:
      raiseAt(l.lineNo, "enum member must be a single identifier")
    result.add PdlEnumMember(
      name: l.tokens[0], pos: posOf(l), doc: p.takeDoc())
    inc p.pos

# ------------------------------------------------ property / parameter ------

proc parseProperty(p: Parser; baseIndent: int): PdlProperty =
  ## Parses one property/parameter line and, if its type is ``enum``, the
  ## indented enum-member block that follows it. ``baseIndent`` is the
  ## indent of the property line itself.
  let l = p.current
  var idx = 0
  var optional = false
  var experimental = false
  var deprecated = false
  # Order in the wild: experimental/deprecated may appear before or after
  # ``optional``, so accept any interleaving.
  while idx < l.tokens.len:
    case l.tokens[idx]
    of "experimental": experimental = true; inc idx
    of "deprecated": deprecated = true; inc idx
    of "optional": optional = true; inc idx
    else: break
  if idx >= l.tokens.len:
    raiseAt(l.lineNo, "expected a type in property declaration")

  result = PdlProperty(
    pos: posOf(l), doc: p.takeDoc(),
    optional: optional, experimental: experimental, deprecated: deprecated)

  if l.tokens[idx] == "enum":
    # Anonymous enum property: ``[optional] enum <name>`` followed by an
    # indented list of members.
    inc idx
    if idx >= l.tokens.len:
      raiseAt(l.lineNo, "enum property is missing a name")
    result.name = l.tokens[idx]
    inc idx
    if idx != l.tokens.len:
      raiseAt(l.lineNo, "trailing tokens after enum property name")
    inc p.pos
    let members = parseEnumMembers(p, baseIndent + 2)
    result.typ = PdlEnumType(members: members, pos: posOf(l))
    return

  let typ = parseTypeRef(l.tokens, idx, l.lineNo)
  if idx >= l.tokens.len:
    raiseAt(l.lineNo, "expected a name after type")
  result.name = l.tokens[idx]
  inc idx
  if idx != l.tokens.len:
    raiseAt(l.lineNo, "trailing tokens after property name")
  result.typ = typ
  inc p.pos

  # A ``string`` property may be refined by an inline ``enum`` block at
  # ``baseIndent + 2``. We replace the type with a ``PdlEnumType`` so that
  # downstream consumers don't need to look two places.
  skipTrivia(p, baseIndent + 2)
  if not p.atEnd and p.current.indent == baseIndent + 2 and
      p.current.tokens.len == 1 and p.current.tokens[0] == "enum":
    inc p.pos
    let members = parseEnumMembers(p, baseIndent + 4)
    result.typ = PdlEnumType(members: members, pos: result.typ.pos)

proc parsePropertyBlock(p: Parser; childIndent: int): seq[PdlProperty] =
  while true:
    skipTrivia(p, childIndent)
    if p.atEnd or p.current.indent < childIndent: break
    if p.current.indent > childIndent:
      raiseAt(p.current.lineNo, "unexpected indent")
    result.add parseProperty(p, childIndent)

# ------------------------------------------------------- type declaration ---

proc parseTypeDecl(p: Parser; baseIndent: int;
                   experimental, deprecated: bool;
                   doc: seq[string]): PdlTypeDecl =
  ## Called after ``[experimental] [deprecated] type`` has been seen on
  ## ``p.current``. Consumes the type-decl line and any indented body
  ## (``properties`` or ``enum``) and returns one of the three
  ## ``PdlTypeDecl`` subclasses.
  let l = p.current
  let toks = l.tokens
  # toks looks like: [..., "type", Name, "extends", baseTokens...]
  var i = 0
  while i < toks.len and toks[i] != "type": inc i
  if i >= toks.len: raiseAt(l.lineNo, "internal: 'type' keyword missing")
  inc i
  if i >= toks.len: raiseAt(l.lineNo, "expected type name")
  let name = toks[i]; inc i
  if i >= toks.len or toks[i] != "extends":
    raiseAt(l.lineNo, "expected 'extends' after type name")
  inc i
  if i >= toks.len: raiseAt(l.lineNo, "expected base type after 'extends'")

  if toks[i] == "object":
    if i + 1 != toks.len:
      raiseAt(l.lineNo, "trailing tokens after 'object'")
    inc p.pos
    var props: seq[PdlProperty]
    skipTrivia(p, baseIndent + 2)
    # ``properties`` block is optional — some object types have no fields.
    if not p.atEnd and p.current.indent == baseIndent + 2 and
        p.current.tokens == @["properties"]:
      inc p.pos
      props = parsePropertyBlock(p, baseIndent + 4)
    return PdlObjectDecl(
      name: name, experimental: experimental, deprecated: deprecated,
      pos: posOf(l), doc: doc, properties: props)

  # Non-object base. After consuming the base type, an inline ``enum``
  # block (one indent deeper) promotes this to a named enum type.
  let base = parseTypeRef(toks, i, l.lineNo)
  if i != toks.len:
    raiseAt(l.lineNo, "trailing tokens after type base")
  inc p.pos
  skipTrivia(p, baseIndent + 2)
  if not p.atEnd and p.current.indent == baseIndent + 2 and
      p.current.tokens == @["enum"]:
    inc p.pos
    let members = parseEnumMembers(p, baseIndent + 4)
    return PdlEnumDecl(
      name: name, experimental: experimental, deprecated: deprecated,
      pos: posOf(l), doc: doc, members: members)
  return PdlAliasDecl(
    name: name, experimental: experimental, deprecated: deprecated,
    pos: posOf(l), doc: doc, base: base)

# ------------------------------------------------------ command / event -----

proc parseSignatureBlock(p: Parser; baseIndent: int;
                         keyword: string): seq[PdlProperty] =
  ## Generic helper for ``parameters`` / ``returns`` blocks: if the next
  ## line at ``baseIndent + 2`` is exactly ``keyword``, consume it and
  ## return the indented property block; otherwise return ``@[]``.
  skipTrivia(p, baseIndent + 2)
  if not p.atEnd and p.current.indent == baseIndent + 2 and
      p.current.tokens == @[keyword]:
    inc p.pos
    return parsePropertyBlock(p, baseIndent + 4)
  @[]

proc parseRedirect(p: Parser; baseIndent: int): Option[string] =
  skipTrivia(p, baseIndent + 2)
  if not p.atEnd and p.current.indent == baseIndent + 2 and
      p.current.tokens.len == 2 and p.current.tokens[0] == "redirect":
    let target = p.current.tokens[1]
    inc p.pos
    return some(target)
  none(string)

proc parseCommand(p: Parser; baseIndent: int;
                  experimental, deprecated: bool;
                  doc: seq[string]): PdlCommand =
  let l = p.current
  let toks = l.tokens
  var i = 0
  while i < toks.len and toks[i] != "command": inc i
  inc i
  if i >= toks.len: raiseAt(l.lineNo, "expected command name")
  let name = toks[i]
  if i + 1 != toks.len:
    raiseAt(l.lineNo, "trailing tokens after command name")
  inc p.pos
  result = PdlCommand(
    name: name, experimental: experimental, deprecated: deprecated,
    pos: posOf(l), doc: doc)
  # ``redirect``, ``parameters``, and ``returns`` may appear in any order
  # but each at most once. Loop until we stop making progress.
  while true:
    let before = p.pos
    if result.redirect.isNone:
      result.redirect = parseRedirect(p, baseIndent)
    if result.parameters.len == 0:
      result.parameters = parseSignatureBlock(p, baseIndent, "parameters")
    if result.returns.len == 0:
      result.returns = parseSignatureBlock(p, baseIndent, "returns")
    if p.pos == before: break

proc parseEvent(p: Parser; baseIndent: int;
                experimental, deprecated: bool;
                doc: seq[string]): PdlEvent =
  let l = p.current
  let toks = l.tokens
  var i = 0
  while i < toks.len and toks[i] != "event": inc i
  inc i
  if i >= toks.len: raiseAt(l.lineNo, "expected event name")
  let name = toks[i]
  if i + 1 != toks.len:
    raiseAt(l.lineNo, "trailing tokens after event name")
  inc p.pos
  result = PdlEvent(
    name: name, experimental: experimental, deprecated: deprecated,
    pos: posOf(l), doc: doc)
  result.parameters = parseSignatureBlock(p, baseIndent, "parameters")

# ----------------------------------------------------------- domain body ----

proc parseDomainBody(p: Parser; domain: PdlDomain; baseIndent: int) =
  let childIndent = baseIndent + 2
  while true:
    skipTrivia(p, childIndent)
    if p.atEnd or p.current.indent < childIndent: break
    if p.current.indent > childIndent:
      raiseAt(p.current.lineNo, "unexpected indent in domain body")

    let l = p.current
    let doc = p.takeDoc()
    var idx = 0
    let mods = consumeModifiers(l.tokens, idx)
    if idx >= l.tokens.len:
      raiseAt(l.lineNo, "expected declaration after modifiers")
    let kw = l.tokens[idx]

    case kw
    of "depends":
      # ``depends on Other`` — only legal at the very top of a domain
      # body, but we accept it anywhere for tolerance.
      if l.tokens.len != idx + 3 or l.tokens[idx + 1] != "on":
        raiseAt(l.lineNo, "malformed 'depends on' clause")
      domain.dependsOn.add l.tokens[idx + 2]
      inc p.pos
    of "type":
      domain.types.add parseTypeDecl(
        p, childIndent, mods.experimental, mods.deprecated, doc)
    of "command":
      domain.commands.add parseCommand(
        p, childIndent, mods.experimental, mods.deprecated, doc)
    of "event":
      domain.events.add parseEvent(
        p, childIndent, mods.experimental, mods.deprecated, doc)
    else:
      raiseAt(l.lineNo, "unknown keyword '" & kw & "' in domain body")

# ------------------------------------------------------------ top level -----

proc parseVersion(p: Parser): PdlVersion =
  let head = p.current
  inc p.pos
  result = PdlVersion(pos: posOf(head), doc: p.takeDoc())
  let childIndent = head.indent + 2
  while true:
    skipTrivia(p, childIndent)
    if p.atEnd or p.current.indent < childIndent: break
    let l = p.current
    if l.tokens.len != 2:
      raiseAt(l.lineNo, "version field expects 'major N' or 'minor N'")
    let n = try: parseInt(l.tokens[1])
            except ValueError: raiseAt(l.lineNo, "version number must be an integer")
    case l.tokens[0]
    of "major": result.major = n
    of "minor": result.minor = n
    else: raiseAt(l.lineNo, "unknown version field '" & l.tokens[0] & "'")
    inc p.pos

proc parseDomain(p: Parser; experimental, deprecated: bool;
                 doc: seq[string]): PdlDomain =
  let l = p.current
  var i = 0
  while i < l.tokens.len and l.tokens[i] != "domain": inc i
  inc i
  if i >= l.tokens.len: raiseAt(l.lineNo, "expected domain name")
  let name = l.tokens[i]
  if i + 1 != l.tokens.len:
    raiseAt(l.lineNo, "trailing tokens after domain name")
  inc p.pos
  result = PdlDomain(
    name: name, experimental: experimental, deprecated: deprecated,
    pos: posOf(l), doc: doc)
  parseDomainBody(p, result, l.indent)

proc parsePdl*(source: string): PdlFile =
  ## Parse a ``.pdl`` source string. Raises ``PdlParseError`` on any
  ## syntactic problem; the exception's ``line`` field points at the
  ## offending source line.
  let p = Parser(lines: lex(source))
  result = PdlFile(pos: PdlPos(line: 1))
  while true:
    skipTrivia(p, 0)
    if p.atEnd: break
    let l = p.current
    if l.indent != 0:
      raiseAt(l.lineNo, "unexpected indent at top level")
    let doc = p.takeDoc()
    var idx = 0
    let mods = consumeModifiers(l.tokens, idx)
    if idx >= l.tokens.len:
      raiseAt(l.lineNo, "expected declaration after modifiers")
    case l.tokens[idx]
    of "version":
      if mods.experimental or mods.deprecated:
        raiseAt(l.lineNo, "'version' does not take modifiers")
      if result.version.isSome:
        raiseAt(l.lineNo, "duplicate 'version' block")
      result.version = some(parseVersion(p))
    of "include":
      if mods.experimental or mods.deprecated:
        raiseAt(l.lineNo, "'include' does not take modifiers")
      if idx + 2 != l.tokens.len:
        raiseAt(l.lineNo, "'include' expects exactly one path argument")
      result.includes.add PdlInclude(
        path: l.tokens[idx + 1], pos: posOf(l), doc: doc)
      inc p.pos
    of "domain":
      result.domains.add parseDomain(p, mods.experimental, mods.deprecated, doc)
    else:
      raiseAt(l.lineNo, "unknown top-level keyword '" & l.tokens[idx] & "'")

proc parsePdlFile*(path: string; followIncludes = false): PdlFile =
  ## Read ``path`` and parse it. When ``followIncludes`` is true, every
  ## ``include`` directive is resolved relative to ``path``'s directory,
  ## parsed recursively, and its domains are merged into the result;
  ## ``includes`` then lists the resolved (absolute) paths in load order.
  result = parsePdl(readFile(path))
  if not followIncludes or result.includes.len == 0: return
  let baseDir = path.parentDir()
  var resolved: seq[PdlInclude]
  for inc in result.includes:
    let child = parsePdlFile(baseDir / inc.path, followIncludes = true)
    for d in child.domains: result.domains.add d
    resolved.add PdlInclude(
      path: baseDir / inc.path, pos: inc.pos, doc: inc.doc)
  result.includes = resolved
