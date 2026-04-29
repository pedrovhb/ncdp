## Render a parsed PDL domain into the source text of a Nim module.
##
## We render to **strings**, not to NimNode trees. NimNode + ``repr`` is
## a great fit for compile-time macros where the output is consumed by
## the compiler immediately, but it's a poor fit for "produce a file a
## human will read" — ``repr`` doesn't preserve doc-comment placement,
## blank-line grouping, or comment alignment, all of which matter for
## the hand-written reference modules we're supposed to match
## byte-for-byte.
##
## The shape we target is the one nailed down by `src/cdp/schema.nim`
## and `src/cdp/system_info.nim`. See the doc comments at the top of
## each for the conventions.
##
## ## Type mapping
##
## | PDL                         | Nim                              |
## |-----------------------------|----------------------------------|
## | ``string``                  | ``string``                       |
## | ``integer``                 | ``int``                          |
## | ``number``                  | ``float``                        |
## | ``boolean``                 | ``bool``                         |
## | ``any``                     | ``JsonNode``                     |
## | ``binary``                  | ``Binary``                       |
## | ``object`` (no type)        | ``JsonNode``                     |
## | ``array of T``              | ``seq[T]``                       |
## | ``Domain.Name`` (qualified) | ``domain.Name`` (cross-module)   |
## | ``Name`` (unqualified)      | ``Name``                         |
## | optional ``T``              | ``Option[T]``                    |
##
## ## Module layout produced
##
## ```
## ## <doc header>
## import chronos
## import std/[json, jsonutils, options]
## import ./jsonhooks
## import ./transport
## import ./<other-domain>   # only if the domain refs another domain's types
##
## type
##   <enums (top-level + lifted-from-inline)>
##   <objects + aliases>
##   <command result types>
##   <event params types>
##
## const
##   <one wire-mapping array per enum>
##
## <to/fromJsonHook overload pair per enum>
##
## <one proc per command>
## <one on<Event> registration proc per event>
## ```
##
## Cross-domain refs are collected during emission and prepended to
## the import block.

import std/[algorithm, options, sets, strutils]
import ../pdl/ast
import ./names

# ---------------------------------------------------------------- types ---

type
  EnumBlock = object
    ## Three rendered chunks for one enum: the `Name* = enum ...` lines
    ## (no leading `type` keyword), the `const NameWire: array[...]` block,
    ## and the `to/fromJsonHook` proc pair. Kept separate because they
    ## need to land in different sections of the output module.
    nimType: string
    typeDecl: string
    wireConst: string
    hooks: string

  EmitCtx = ref object
    ## Per-domain emission state. Tracks cross-domain references so
    ## the import block at the top of the module can be derived.
    domain: PdlDomain
    imports: HashSet[string]    # domain *file* basenames to import
    registry: NameRegistry
    lifted: seq[EnumBlock]      # synthetic enums lifted from inline PDL enums
    liftedNames: HashSet[string]
    inlineEnumOwner: string     # set by callers of emitType to name a lift target

# --------------------------------------------------------- helpers --------

proc renderDoc(doc: seq[string]; indentN: int): string =
  if doc.len == 0: return ""
  let pad = " ".repeat(indentN)
  for line in doc:
    result.add pad & "## " & line & "\n"

proc pragmas(experimental, deprecated: bool;
             extras: openArray[string] = []): string =
  ## Renders a Nim pragma list. Only `deprecated` is a real pragma —
  ## PDL's `experimental` flag is informational metadata, not a Nim
  ## language feature, so it doesn't appear here. (Could be surfaced
  ## as a doc-comment line in the future.)
  var parts: seq[string]
  if deprecated: parts.add "deprecated"
  for e in extras: parts.add e
  if parts.len == 0: return ""
  " {." & parts.join(", ") & ".}"

# --------------------------------------------------------- type rendering -

proc emitPrimitive(t: PdlPrimitiveType): string =
  case t.kind
  of ppString:  "string"
  of ppInteger: "int"
  of ppNumber:  "float"
  of ppBoolean: "bool"
  of ppAny:     "JsonNode"
  of ppBinary:  "Binary"
  of ppObject:  "JsonNode"

const HandWrittenDomains* = ["Schema", "SystemInfo"]
  ## Domains whose modules live at `src/cdp/<domain>.nim` rather than
  ## the generated `src/cdp/gen/<domain>.nim`. Cross-domain refs to
  ## these resolve one directory up.

proc isHandWritten(name: string): bool =
  for h in HandWrittenDomains:
    if h == name: return true
  false

proc emitRef(ctx: EmitCtx; t: PdlRefType): string =
  if t.domain.isSome and t.domain.get != ctx.domain.name:
    let other = t.domain.get
    let path = if isHandWritten(other): "../" & moduleFileName(other)
               else: "./" & moduleFileName(other)
    ctx.imports.incl path
    return moduleFileName(other) & "." & typeName(other, t.name)
  typeName(ctx.domain.name, t.name)

proc renderEnumBlock(nimType: string;
                     members: seq[PdlEnumMember];
                     pairs: seq[(string, string)];
                     experimental, deprecated: bool;
                     doc: seq[string]): EnumBlock =
  result.nimType = nimType
  result.typeDecl = "  " & nimType & "*" & pragmas(experimental, deprecated) &
                    " = enum\n"
  if doc.len > 0:
    result.typeDecl.add renderDoc(doc, 4)
  for i, m in members:
    if m.doc.len > 0:
      result.typeDecl.add renderDoc(m.doc, 4)
    result.typeDecl.add "    " & pairs[i][0] & "\n"

  result.wireConst = "  " & nimType & "Wire: array[" & nimType &
                     ", string] = [\n"
  for (_, w) in pairs:
    result.wireConst.add "    \"" & w & "\",\n"
  result.wireConst.add "  ]\n"

  result.hooks = "proc toJsonHook*(v: " & nimType &
                 "; opt = initToJsonOptions()): JsonNode =\n"
  result.hooks.add "  newJString(" & nimType & "Wire[v])\n\n"
  result.hooks.add "proc fromJsonHook*(v: var " & nimType &
                   "; n: JsonNode; opt = Joptions()) =\n"
  result.hooks.add "  if n.kind != JString:\n"
  result.hooks.add "    raise newException(ValueError, \"" & nimType &
                   ": expected string\")\n"
  result.hooks.add "  let s = n.getStr()\n"
  result.hooks.add "  for k, w in " & nimType & "Wire:\n"
  result.hooks.add "    if w == s: v = k; return\n"
  result.hooks.add "  raise newException(ValueError, \"" & nimType &
                   ": unknown value \" & s)\n\n"

proc registerEnum(ctx: EmitCtx; nimType: string;
                  members: seq[PdlEnumMember];
                  experimental, deprecated: bool;
                  doc: seq[string]): EnumBlock =
  var pairs: seq[(string, string)]
  for m in members:
    pairs.add (enumMemberName(nimType, m.name), m.name)
  ctx.registry.recordEnum(nimType, pairs)
  renderEnumBlock(nimType, members, pairs, experimental, deprecated, doc)

proc emitType(ctx: EmitCtx; t: PdlType): string

proc liftInlineEnum(ctx: EmitCtx; t: PdlEnumType): string =
  ## Lift an anonymous PDL enum to a synthetic named type. Caller
  ## must have set ``ctx.inlineEnumOwner`` to the desired Nim type
  ## name (Pascal-cased, e.g. ``GoMode``). Idempotent — repeated lifts
  ## with the same name reuse the prior emission.
  let nimType = ctx.inlineEnumOwner
  if nimType.len == 0:
    raise newException(ValueError,
      "inline enum encountered with no owner context — emitter bug")
  if nimType notin ctx.liftedNames:
    ctx.liftedNames.incl nimType
    let blk = registerEnum(ctx, nimType, t.members,
                            experimental = false, deprecated = false,
                            doc = @[])
    ctx.lifted.add blk
  nimType

proc emitArray(ctx: EmitCtx; t: PdlArrayType): string =
  "seq[" & ctx.emitType(t.element) & "]"

proc emitType(ctx: EmitCtx; t: PdlType): string =
  if t of PdlPrimitiveType: emitPrimitive(PdlPrimitiveType(t))
  elif t of PdlArrayType:    emitArray(ctx, PdlArrayType(t))
  elif t of PdlRefType:      emitRef(ctx, PdlRefType(t))
  elif t of PdlEnumType:     liftInlineEnum(ctx, PdlEnumType(t))
  else:
    raise newException(ValueError, "unknown PdlType subtype")

# --------------------------------------------------------- objects --------

proc emitProperty(ctx: EmitCtx; p: PdlProperty; ownerPrefix: string): string =
  ## One field line in an object body, with its trailing doc lines.
  ## ``ownerPrefix`` names the enclosing type (Pascal-cased) so that
  ## any inline enum on this property can be lifted to a synthetic
  ## type ``<owner><Field>``.
  let f = mangleField(p.name)
  let nm = if f.needsBackticks: "`" & f.nim & "`" else: f.nim
  ctx.inlineEnumOwner = ownerPrefix & toPascal(p.name)
  var typStr = ctx.emitType(p.typ)
  ctx.inlineEnumOwner = ""
  if p.optional: typStr = "Option[" & typStr & "]"
  result = "    " & nm & "*: " & typStr & "\n"
  if p.doc.len > 0:
    result.add renderDoc(p.doc, 6)

proc emitObject(ctx: EmitCtx; o: PdlObjectDecl): string =
  let nimType = typeName(ctx.domain.name, o.name)
  let dep = o.deprecated or ctx.domain.deprecated
  let exp = o.experimental or ctx.domain.experimental
  result = "  " & nimType & "*" & pragmas(exp, dep) & " = ref object\n"
  if o.doc.len > 0:
    result.add renderDoc(o.doc, 4)
  for p in o.properties:
    result.add ctx.emitProperty(p, nimType)

proc emitAlias(ctx: EmitCtx; a: PdlAliasDecl): string =
  let nimType = typeName(ctx.domain.name, a.name)
  let base = ctx.emitType(a.base)
  let dep = a.deprecated or ctx.domain.deprecated
  let exp = a.experimental or ctx.domain.experimental
  result = "  " & nimType & "*" & pragmas(exp, dep) & " = " & base & "\n"
  if a.doc.len > 0:
    result.add renderDoc(a.doc, 4)

# --------------------------------------------------------- commands -------

proc emitResult(ctx: EmitCtx; cmd: PdlCommand): string =
  if cmd.returns.len == 0: return ""
  let nimType = capitalizeAscii(cmd.name) & "Result"
  let dep = cmd.deprecated or ctx.domain.deprecated
  let exp = cmd.experimental or ctx.domain.experimental
  result = "  " & nimType & "*" & pragmas(exp, dep) & " = ref object\n"
  result.add "    ## Result of `" & ctx.domain.name & "." & cmd.name & "`.\n"
  for p in cmd.returns:
    result.add ctx.emitProperty(p, nimType)

proc emitCommand(ctx: EmitCtx; cmd: PdlCommand): string =
  let pName = cmd.name
  let domainName = ctx.domain.name
  let cap = capitalizeAscii(pName)
  let retType = if cmd.returns.len == 0: "void" else: cap & "Result"
  let futType = if retType == "void": "Future[void]"
                else: "Future[" & retType & "]"
  let paramOwner = cap & "Params"

  var sigArgs = "client: CDPClient"
  for p in cmd.parameters:
    let f = mangleField(p.name)
    let nm = if f.needsBackticks: "`" & f.nim & "`" else: f.nim
    ctx.inlineEnumOwner = paramOwner & toPascal(p.name)
    var typ = ctx.emitType(p.typ)
    ctx.inlineEnumOwner = ""
    if p.optional: typ = "Option[" & typ & "]"
    sigArgs.add "; " & nm & ": " & typ

  let dep = cmd.deprecated or ctx.domain.deprecated
  let pragmaStr = "{." &
    (if dep: "deprecated, " else: "") &
    "async: (raises: [CDPError, CDPTransportError, CancelledError]).}"

  result = "proc " & pName & "*(" & sigArgs & "): " & futType & " " &
           pragmaStr & " =\n"
  if cmd.doc.len > 0:
    result.add renderDoc(cmd.doc, 2)

  # The marshal calls (`toJson`, `jsonTo`) are wrapped in
  # ``{.cast(raises: [CatchableError]).}:`` because their inferred
  # raises set transitively contains the bare ``system.Exception``
  # type, which is a sibling of ``CatchableError`` (not a subtype) —
  # so a plain ``except CatchableError`` does not satisfy the strict
  # raises check on the async proc. The cast erases the inferred set
  # at that point, leaving only what we re-raise from inside it (a
  # CatchableError subtype if jsonutils raises one). The cast is also
  # gcsafe-effect-clearing, so we don't need a separate gcsafe cast.
  # See `/tmp/nim-raises-research.md` (and citations therein) for the
  # full story; tl;dr: jsonutils has no explicit `raises:` pragma.
  if cmd.parameters.len == 0:
    if retType == "void":
      result.add "  let raw {.used.} = await client.sendCommand(\"" &
                 domainName & "." & pName & "\")\n"
    else:
      result.add "  let raw = await client.sendCommand(\"" &
                 domainName & "." & pName & "\")\n"
      result.add "  try:\n"
      result.add "    {.cast(gcsafe).}:\n"
      result.add "      {.cast(raises: [CatchableError]).}:\n"
      result.add "        result = jsonTo(raw, " & retType & ")\n"
      result.add "  except CatchableError as e:\n"
      result.add "    raise newException(CDPError,\n"
      result.add "      \"" & domainName & "." & pName &
                 ": malformed response: \" & e.msg)\n"
  else:
    result.add "  let params = newJObject()\n"
    result.add "  try:\n"
    result.add "    {.cast(gcsafe).}:\n"
    result.add "      {.cast(raises: [CatchableError]).}:\n"
    for p in cmd.parameters:
      let f = mangleField(p.name)
      let access = if f.needsBackticks: "`" & f.nim & "`" else: f.nim
      if p.optional:
        result.add "        if " & access & ".isSome:\n"
        result.add "          params[\"" & p.name & "\"] = toJson(" & access & ".get)\n"
      else:
        result.add "        params[\"" & p.name & "\"] = toJson(" & access & ")\n"
    result.add "  except CatchableError as e:\n"
    result.add "    raise newException(CDPError,\n"
    result.add "      \"" & domainName & "." & pName &
               ": encode failed: \" & e.msg)\n"
    if retType == "void":
      result.add "  let raw {.used.} = await client.sendCommand(\"" &
                 domainName & "." & pName & "\", params)\n"
    else:
      result.add "  let raw = await client.sendCommand(\"" &
                 domainName & "." & pName & "\", params)\n"
      result.add "  try:\n"
      result.add "    {.cast(gcsafe).}:\n"
      result.add "      {.cast(raises: [CatchableError]).}:\n"
      result.add "        result = jsonTo(raw, " & retType & ")\n"
      result.add "  except CatchableError as e:\n"
      result.add "    raise newException(CDPError,\n"
      result.add "      \"" & domainName & "." & pName &
                 ": malformed response: \" & e.msg)\n"
  result.add "\n"

# --------------------------------------------------------- events ---------

proc emitEventParams(ctx: EmitCtx; ev: PdlEvent): string =
  let cap = capitalizeAscii(ev.name)
  let paramsType = cap & "Params"
  let dep = ev.deprecated or ctx.domain.deprecated
  let exp = ev.experimental or ctx.domain.experimental
  result = "  " & paramsType & "*" & pragmas(exp, dep) & " = ref object\n"
  if ev.doc.len > 0:
    result.add renderDoc(ev.doc, 4)
  if ev.parameters.len == 0 and ev.doc.len == 0:
    result.add "    ## (no parameters)\n"
  for p in ev.parameters:
    result.add ctx.emitProperty(p, paramsType)

proc emitEventRegistration(ctx: EmitCtx; ev: PdlEvent): string =
  let cap = capitalizeAscii(ev.name)
  let paramsType = cap & "Params"
  let domainName = ctx.domain.name
  result = "proc on" & cap & "*(client: CDPClient;\n"
  result.add "                  cb: proc(params: " & paramsType &
             ") {.gcsafe, raises: [].}) =\n"
  if ev.doc.len > 0:
    result.add renderDoc(ev.doc, 2)
  result.add "  client.addEventListener(\"" & domainName & "." & ev.name &
             "\", proc(params: JsonNode) {.gcsafe, raises: [].} =\n"
  # The marshal call sits inside ``cast(raises: [])`` so the inferred
  # ``Exception`` from jsonutils doesn't escape the listener's
  # ``raises: []`` contract. The local try/except converts any actual
  # decode failure into a silent drop — listener callbacks must not
  # raise out into the transport's dispatch loop.
  result.add "    var typed: " & paramsType & "\n"
  result.add "    {.cast(gcsafe).}:\n"
  result.add "      {.cast(raises: []).}:\n"
  result.add "        try: typed = jsonTo(params, " & paramsType & ")\n"
  result.add "        except CatchableError: return\n"
  result.add "    cb(typed))\n\n"

# --------------------------------------------------------- module --------

proc moduleHeader(d: PdlDomain): string =
  result = "## Bindings for the CDP `" & d.name & "` domain.\n"
  if d.doc.len > 0:
    result.add "##\n"
    for line in d.doc: result.add "## " & line & "\n"
  result.add "##\n"
  result.add "## Generated from `resources/devtools-protocol/pdl/`. Do not edit by hand.\n\n"

proc emitDomain*(d: PdlDomain; registry: NameRegistry): string =
  ## Emits the full text of `src/cdp/<domain>.nim` for `d`. Records
  ## any enum wire mappings into `registry`. Cross-domain imports are
  ## derived during emission and prepended to the output.
  let ctx = EmitCtx(domain: d, imports: initHashSet[string](),
                    registry: registry,
                    liftedNames: initHashSet[string]())

  # Pass: collect everything (and let inline-enum lifts populate
  # ctx.lifted as a side-effect of property/parameter walks).
  var topEnums: seq[EnumBlock]
  var objects = ""
  for t in d.types:
    if t of PdlEnumDecl:
      let e = PdlEnumDecl(t)
      let dep = e.deprecated or ctx.domain.deprecated
      let exp = e.experimental or ctx.domain.experimental
      topEnums.add registerEnum(ctx, typeName(d.name, e.name), e.members,
                                  exp, dep, e.doc)
    elif t of PdlObjectDecl:
      objects.add ctx.emitObject(PdlObjectDecl(t))
    elif t of PdlAliasDecl:
      objects.add ctx.emitAlias(PdlAliasDecl(t))

  var resultsOut = ""
  for c in d.commands:
    resultsOut.add ctx.emitResult(c)

  var eventsParamsOut = ""
  for ev in d.events:
    eventsParamsOut.add ctx.emitEventParams(ev)

  var commandsOut = ""
  for c in d.commands:
    commandsOut.add ctx.emitCommand(c)

  var eventsRegOut = ""
  for ev in d.events:
    eventsRegOut.add ctx.emitEventRegistration(ev)

  # Assemble.
  result = moduleHeader(d)
  result.add "import chronos\n"
  result.add "import std/[json, jsonutils, options]\n"
  result.add "import ../jsonhooks\n"
  result.add "import ../transport\n"
  var sortedImports = newSeq[string]()
  for m in ctx.imports: sortedImports.add m
  sortedImports.sort()
  for m in sortedImports:
    result.add "import " & m & "\n"
  result.add "\n"

  let allEnums = topEnums & ctx.lifted

  # Single `type` block holds enums, objects, command results, event params.
  let hasTypes = allEnums.len > 0 or objects.len > 0 or
                 resultsOut.len > 0 or eventsParamsOut.len > 0
  if hasTypes:
    result.add "type\n"
    for e in allEnums:
      result.add e.typeDecl
      result.add "\n"
    if objects.len > 0:
      result.add objects
    if resultsOut.len > 0:
      result.add resultsOut
    if eventsParamsOut.len > 0:
      result.add eventsParamsOut

  # `const` block with one wire array per enum.
  if allEnums.len > 0:
    result.add "\nconst\n"
    for e in allEnums:
      result.add e.wireConst
    result.add "\n"
    for e in allEnums:
      result.add e.hooks

  # Commands and event registrations.
  if commandsOut.len > 0:
    result.add commandsOut
  if eventsRegOut.len > 0:
    result.add eventsRegOut
