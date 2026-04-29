## Render parsed PDL into the source text of Nim modules.
##
## ## Architecture: shared types + per-domain commands
##
## CDP's PDL has cross-domain type cycles (Network ↔ Page, DOM ↔ Page,
## etc.) that Nim's strict-acyclic module-import model can't represent
## as separate modules. We collapse the entire type graph into one
## module — ``src/cdp/gen/types.nim`` — where Nim's intra-module
## forward references work naturally. Per-domain modules then carry
## just the commands and event registrations and ``import ./types``.
##
## To stay collision-free in the flat namespace, every generated
## type name is **prefixed with its PDL domain**:
## ``Network.RequestId`` → ``NetworkRequestId``,
## ``DOMSnapshot.NodeIndex`` → ``DomSnapshotNodeIndex``. PDL has
## several duplicate type names across domains (RequestId, CallFrame,
## DialogType, ...) which the prefix disambiguates.
##
## ## Output shape
##
## ```
## # gen/types.nim
## ## Generated types — every PDL type from every generated domain.
## import chronos
## import std/[json, jsonutils, options]
## import ../jsonhooks
##
## type
##   <every enum, prefixed with its domain>
##   <every object, alias, *Result, *Params>
##
## const
##   <one wire array per enum>
##
## <to/fromJsonHook for each enum>
## ```
##
## ```
## # gen/<domain>.nim
## ## Generated bindings for the CDP `<Domain>` domain.
## import chronos
## import std/[json, jsonutils, options]
## import ../transport
## import ./types
##
## <one proc per command>
## <one on<Event> registration proc per event>
## ```
##
## ## PDL → Nim type mapping
##
## | PDL                         | Nim                           |
## |-----------------------------|-------------------------------|
## | ``string``                  | ``string``                    |
## | ``integer``                 | ``int``                       |
## | ``number``                  | ``float``                     |
## | ``boolean``                 | ``bool``                      |
## | ``any``                     | ``JsonNode``                  |
## | ``binary``                  | ``Binary`` (from jsonhooks)   |
## | ``object`` (no type)        | ``JsonNode``                  |
## | ``array of T``              | ``seq[T]``                    |
## | ``Domain.Name``             | ``DomainName`` (prefixed)     |
## | ``Name`` (same domain)      | ``DomainName`` (prefixed)     |
## | optional ``T``              | ``Option[T]``                 |

import std/[options, sets, strutils]
import ../pdl/ast
import ./names

# ---------------------------------------------------------------- types ---

type
  EnumBlock = object
    ## Three rendered chunks for one enum: the `Name* = enum ...` lines
    ## (no leading `type` keyword), the `const NameWire: array[...]` body
    ## row, and the `to/fromJsonHook` proc pair. Kept separate because
    ## they need to land in different sections of the output module.
    nimType: string
    typeDecl: string
    wireConst: string
    hooks: string
    deprecated: bool

  EmitCtx = ref object
    ## Per-domain emission state used while walking PDL types and
    ## producing the corresponding Nim. The ``registry`` is shared
    ## across the whole types-module emission so enum collision
    ## detection and wire-mapping bookkeeping work corpus-wide.
    domain: PdlDomain
    registry: NameRegistry
    lifted: seq[EnumBlock]
    liftedNames: HashSet[string]
    inlineEnumOwner: string

# --------------------------------------------------------- helpers --------

proc renderDoc(doc: seq[string]; indentN: int): string =
  if doc.len == 0: return ""
  let pad = " ".repeat(indentN)
  for line in doc:
    result.add pad & "## " & line & "\n"

proc pragmas(deprecated: bool; extras: openArray[string] = []): string =
  ## PDL's ``experimental`` is informational, not a Nim language
  ## feature, so it isn't emitted. ``deprecated`` is a real Nim
  ## pragma and is honored.
  var parts: seq[string]
  if deprecated: parts.add "deprecated"
  for e in extras: parts.add e
  if parts.len == 0: return ""
  " {." & parts.join(", ") & ".}"

# --------------------------------------------------------- type mapping ---

const HandWrittenDomains*: array[0, string] = []
  ## Empty after the codegen pipeline matured. No domain currently
  ## has a hand-written counterpart; everything is generated.

proc isHandWritten(name: string): bool =
  for h in HandWrittenDomains:
    if h == name: return true
  false

proc resultTypeName*(domain, cmd: string): string =
  ## ``getInfo`` in domain ``SystemInfo`` → ``SystemInfoGetInfoResult``.
  ## (Mostly used by command-emitter and result-emitter so they agree.)
  toPascal(domain) & toPascal(cmd) & "Result"

proc eventParamsTypeName*(domain, ev: string): string =
  ## ``frameAttached`` in ``Page`` → ``PageFrameAttachedParams``.
  toPascal(domain) & toPascal(ev) & "Params"

proc emitType(ctx: EmitCtx; t: PdlType): string

proc emitPrimitive(t: PdlPrimitiveType): string =
  case t.kind
  of ppString:  "string"
  of ppInteger: "int"
  of ppNumber:  "float"
  of ppBoolean: "bool"
  of ppAny:     "JsonNode"
  of ppBinary:  "Binary"
  of ppObject:  "JsonNode"

proc emitRef(ctx: EmitCtx; t: PdlRefType): string =
  ## Resolve a (possibly cross-domain) PDL type reference to its
  ## generated Nim name. The shared types module means every
  ## reference is just a bare name — no module-qualifier path —
  ## thanks to the domain prefix.
  let dom = if t.domain.isSome: t.domain.get else: ctx.domain.name
  if isHandWritten(dom):
    raise newException(ValueError,
      "generated code references hand-written domain " & dom &
      " — not currently supported. Add an import in emitRef.")
  typeName(dom, t.name)

proc emitArray(ctx: EmitCtx; t: PdlArrayType): string =
  "seq[" & ctx.emitType(t.element) & "]"

proc renderEnumBlock(nimType: string;
                     members: seq[PdlEnumMember];
                     pairs: seq[(string, string)];
                     deprecated: bool;
                     doc: seq[string]): EnumBlock =
  ## Emits the enum as `{.pure.}` so members live under
  ## ``TypeName.Member`` rather than the module's flat namespace.
  ## Without `.pure.`, two CDP enums with shared member spellings
  ## (e.g. SmartCardEmulation's `Disposition` and `ResultCode` both
  ## have `reset-card`) would collide in the shared types module.
  ## See `/references/Nim/doc/manual.md:1318` on `pure`.
  result.nimType = nimType
  result.deprecated = deprecated
  # Manually compose the pragma; `pragmas()` doesn't take a list of
  # always-on pragmas. Order: deprecated first if present, then pure.
  var pragParts: seq[string]
  if deprecated: pragParts.add "deprecated"
  pragParts.add "pure"
  let pragStr = " {." & pragParts.join(", ") & ".}"
  result.typeDecl = "  " & nimType & "*" & pragStr & " = enum\n"
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
                  deprecated: bool;
                  doc: seq[string]): EnumBlock =
  var pairs: seq[(string, string)]
  for m in members:
    pairs.add (enumMemberName(nimType, m.name), m.name)
  ctx.registry.recordEnum(nimType, pairs)
  renderEnumBlock(nimType, members, pairs, deprecated, doc)

proc liftInlineEnum(ctx: EmitCtx; t: PdlEnumType): string =
  ## Anonymous PDL enum at a property/parameter site → synthetic named
  ## type ``<Owner><Field>``. ``ctx.inlineEnumOwner`` carries the
  ## already-domain-prefixed Pascal name from the caller.
  let nimType = ctx.inlineEnumOwner
  if nimType.len == 0:
    raise newException(ValueError,
      "inline enum encountered with no owner context — emitter bug")
  if nimType notin ctx.liftedNames:
    ctx.liftedNames.incl nimType
    let blk = registerEnum(ctx, nimType, t.members,
                            deprecated = false, doc = @[])
    ctx.lifted.add blk
  nimType

proc emitType(ctx: EmitCtx; t: PdlType): string =
  if t of PdlPrimitiveType: emitPrimitive(PdlPrimitiveType(t))
  elif t of PdlArrayType:    emitArray(ctx, PdlArrayType(t))
  elif t of PdlRefType:      emitRef(ctx, PdlRefType(t))
  elif t of PdlEnumType:     liftInlineEnum(ctx, PdlEnumType(t))
  else:
    raise newException(ValueError, "unknown PdlType subtype")

# --------------------------------------------------------- objects --------

proc emitProperty(ctx: EmitCtx; p: PdlProperty; ownerNimType: string): string =
  ## One field line. ``ownerNimType`` is the (already domain-prefixed)
  ## Nim name of the enclosing object, used to derive the lift target
  ## for any inline enum on this field.
  let f = mangleField(p.name)
  let nm = if f.needsBackticks: "`" & f.nim & "`" else: f.nim
  ctx.inlineEnumOwner = ownerNimType & toPascal(p.name)
  var typStr = ctx.emitType(p.typ)
  ctx.inlineEnumOwner = ""
  if p.optional: typStr = "Option[" & typStr & "]"
  result = "    " & nm & "*: " & typStr & "\n"
  if p.doc.len > 0:
    result.add renderDoc(p.doc, 6)

type
  TypeChunk = object
    ## A single type declaration plus a deprecation flag. The
    ## assembler in ``emitTypesModule`` groups consecutive non-
    ## deprecated chunks into one ``type`` block and emits each
    ## deprecated chunk in its own ``{.push warning[Deprecated]: off.}``
    ## bracket so deprecated *uses* of deprecated types (a deprecated
    ## field referencing another deprecated type, etc.) don't trip
    ## the consumer with a Nim warning.
    text: string
    deprecated: bool

proc emitObject(ctx: EmitCtx; o: PdlObjectDecl): TypeChunk =
  let nimType = typeName(ctx.domain.name, o.name)
  result.deprecated = o.deprecated or ctx.domain.deprecated
  result.text = "  " & nimType & "*" & pragmas(result.deprecated) &
                " = ref object\n"
  if o.doc.len > 0:
    result.text.add renderDoc(o.doc, 4)
  for p in o.properties:
    result.text.add ctx.emitProperty(p, nimType)

proc emitAlias(ctx: EmitCtx; a: PdlAliasDecl): TypeChunk =
  let nimType = typeName(ctx.domain.name, a.name)
  let base = ctx.emitType(a.base)
  result.deprecated = a.deprecated or ctx.domain.deprecated
  result.text = "  " & nimType & "*" & pragmas(result.deprecated) &
                " = " & base & "\n"
  if a.doc.len > 0:
    result.text.add renderDoc(a.doc, 4)

# --------------------------------------------------- result/params types --

proc emitResultType(ctx: EmitCtx; cmd: PdlCommand): TypeChunk =
  if cmd.returns.len == 0: return TypeChunk()
  let nimType = resultTypeName(ctx.domain.name, cmd.name)
  result.deprecated = cmd.deprecated or ctx.domain.deprecated
  result.text = "  " & nimType & "*" & pragmas(result.deprecated) &
                " = ref object\n"
  result.text.add "    ## Result of `" & ctx.domain.name & "." &
                  cmd.name & "`.\n"
  for p in cmd.returns:
    result.text.add ctx.emitProperty(p, nimType)

proc emitEventParamsType(ctx: EmitCtx; ev: PdlEvent): TypeChunk =
  let nimType = eventParamsTypeName(ctx.domain.name, ev.name)
  result.deprecated = ev.deprecated or ctx.domain.deprecated
  result.text = "  " & nimType & "*" & pragmas(result.deprecated) &
                " = ref object\n"
  if ev.doc.len > 0:
    result.text.add renderDoc(ev.doc, 4)
  if ev.parameters.len == 0 and ev.doc.len == 0:
    result.text.add "    ## (no parameters)\n"
  for p in ev.parameters:
    result.text.add ctx.emitProperty(p, nimType)

# --------------------------------------------------------- commands -------

proc emitCommand(ctx: EmitCtx; cmd: PdlCommand): string =
  let pName = cmd.name
  let domainName = ctx.domain.name
  let resultType =
    if cmd.returns.len == 0: ""
    else: resultTypeName(domainName, cmd.name)
  let futType = if resultType == "": "Future[void]"
                else: "Future[" & resultType & "]"

  var sigArgs = "client: CDPClient"
  for p in cmd.parameters:
    let mp = mangleParam(p.name)
    let nm = if mp.needsBackticks: "`" & mp.nim & "`" else: mp.nim
    # Lift target for any inline enum on a parameter.
    ctx.inlineEnumOwner = toPascal(domainName) & toPascal(pName) &
                          "Params" & toPascal(p.name)
    var typ = ctx.emitType(p.typ)
    ctx.inlineEnumOwner = ""
    if p.optional: typ = "Option[" & typ & "]"
    sigArgs.add "; " & nm & ": " & typ

  let dep = cmd.deprecated or ctx.domain.deprecated
  let pragmaStr = "{." &
    (if dep: "deprecated, " else: "") &
    "async: (raises: [CDPError, CDPTransportError, CancelledError]).}"

  let nimProcName = if isNimKeyword(pName): "`" & pName & "`" else: pName
  result = "proc " & nimProcName & "*(" & sigArgs & "): " & futType &
           " " & pragmaStr & " =\n"
  if cmd.doc.len > 0:
    result.add renderDoc(cmd.doc, 2)

  # Body. See docs/internal/nim-raises-research.md for why we wrap
  # `toJson`/`jsonTo` in nested `cast(gcsafe)` + `cast(raises:
  # [CatchableError])` blocks: jsonutils' inferred raises set
  # transitively contains literal `system.Exception` (a sibling of
  # `CatchableError`, not a subtype), which `except CatchableError`
  # does NOT cover. The cast suppresses the inferred Exception at
  # the call site so the surrounding handler can do its work.
  if cmd.parameters.len == 0:
    if resultType == "":
      result.add "  let raw {.used.} = await client.sendCommand(\"" &
                 domainName & "." & pName & "\")\n"
    else:
      result.add "  let raw = await client.sendCommand(\"" &
                 domainName & "." & pName & "\")\n"
      result.add "  try:\n"
      result.add "    {.cast(gcsafe).}:\n"
      result.add "      {.cast(raises: [CatchableError]).}:\n"
      result.add "        result = jsonTo(raw, " & resultType & ", cdpDecodeOpts)\n"
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
      let mp = mangleParam(p.name)
      let access = if mp.needsBackticks: "`" & mp.nim & "`" else: mp.nim
      if p.optional:
        result.add "        if " & access & ".isSome:\n"
        result.add "          params[\"" & mp.wire &
                   "\"] = toJson(" & access & ".get)\n"
      else:
        result.add "        params[\"" & mp.wire & "\"] = toJson(" &
                   access & ")\n"
    result.add "  except CatchableError as e:\n"
    result.add "    raise newException(CDPError,\n"
    result.add "      \"" & domainName & "." & pName &
               ": encode failed: \" & e.msg)\n"
    if resultType == "":
      result.add "  let raw {.used.} = await client.sendCommand(\"" &
                 domainName & "." & pName & "\", params)\n"
    else:
      result.add "  let raw = await client.sendCommand(\"" &
                 domainName & "." & pName & "\", params)\n"
      result.add "  try:\n"
      result.add "    {.cast(gcsafe).}:\n"
      result.add "      {.cast(raises: [CatchableError]).}:\n"
      result.add "        result = jsonTo(raw, " & resultType & ", cdpDecodeOpts)\n"
      result.add "  except CatchableError as e:\n"
      result.add "    raise newException(CDPError,\n"
      result.add "      \"" & domainName & "." & pName &
                 ": malformed response: \" & e.msg)\n"
  result.add "\n"

# --------------------------------------------------------- events ---------

proc emitEventRegistration(ctx: EmitCtx; ev: PdlEvent): string =
  let domainName = ctx.domain.name
  let paramsType = eventParamsTypeName(domainName, ev.name)
  let cap = capitalizeAscii(ev.name)
  result = "proc on" & cap & "*(client: CDPClient;\n"
  result.add "                  cb: proc(params: " & paramsType &
             ") {.gcsafe, raises: [].}) =\n"
  if ev.doc.len > 0:
    result.add renderDoc(ev.doc, 2)
  result.add "  client.addEventListener(\"" & domainName & "." & ev.name &
             "\", proc(params: JsonNode) {.gcsafe, raises: [].} =\n"
  result.add "    var typed: " & paramsType & "\n"
  result.add "    {.cast(gcsafe).}:\n"
  result.add "      {.cast(raises: []).}:\n"
  result.add "        try: typed = jsonTo(params, " & paramsType & ", cdpDecodeOpts)\n"
  result.add "        except CatchableError: return\n"
  result.add "    cb(typed))\n\n"

# --------------------------------------------------- per-domain types -----

type
  DomainTypes = object
    ## All type-shaped output produced by walking one domain. The
    ## types-module emitter concatenates these across every domain
    ## and groups by deprecation flag at assembly time.
    enums: seq[EnumBlock]
    chunks: seq[TypeChunk]   # objects, aliases, *Result, *Params

proc collectDomainTypes(d: PdlDomain; registry: NameRegistry): DomainTypes =
  let ctx = EmitCtx(domain: d, registry: registry,
                    liftedNames: initHashSet[string]())

  for t in d.types:
    if t of PdlEnumDecl:
      let e = PdlEnumDecl(t)
      let dep = e.deprecated or d.deprecated
      result.enums.add registerEnum(
        ctx, typeName(d.name, e.name), e.members, dep, e.doc)
    elif t of PdlObjectDecl:
      result.chunks.add ctx.emitObject(PdlObjectDecl(t))
    elif t of PdlAliasDecl:
      result.chunks.add ctx.emitAlias(PdlAliasDecl(t))

  for c in d.commands:
    # Walk command parameters too — they can carry inline enums that
    # the per-domain emitter will reference via the synthetic type
    # name. The lift side-effect populates ctx.lifted; the property
    # walk's string output is discarded here (the actual signature
    # render happens in emitCommand).
    let owner = toPascal(d.name) & toPascal(c.name) & "Params"
    for p in c.parameters:
      discard ctx.emitProperty(p, owner)
    let r = ctx.emitResultType(c)
    if r.text.len > 0: result.chunks.add r

  for ev in d.events:
    result.chunks.add ctx.emitEventParamsType(ev)

  # Inline enums lifted during property walks land in ctx.lifted.
  for blk in ctx.lifted:
    result.enums.add blk

# --------------------------------------------------- module emitters -----

proc emitTypesModule*(domains: seq[PdlDomain];
                       registry: NameRegistry): string =
  ## Build the single shared types module — every PDL type from every
  ## generated domain. Reserved (hand-written) domains are skipped.
  result = "## Generated PDL types — every type, alias, command-result,\n"
  result.add "## and event-params type from every CDP domain we generate.\n"
  result.add "##\n"
  result.add "## Generated from `resources/devtools-protocol/pdl/`. Do not edit by hand.\n\n"
  result.add "import std/[json, jsonutils, options]\n"
  result.add "import ../jsonhooks\n"
  result.add "\n"

  var allEnums: seq[EnumBlock]
  var allChunks: seq[TypeChunk]
  for d in domains:
    if isHandWritten(d.name): continue
    let dt = collectDomainTypes(d, registry)
    for e in dt.enums: allEnums.add e
    for c in dt.chunks: allChunks.add c

  # The entire types module is generated code referencing other
  # generated code. Deprecated types frequently reference each other
  # (a deprecated event params type whose field is itself a
  # deprecated type, for example), and Nim warns at every such use.
  # We can't split into separate `type` blocks to bracket
  # deprecation, because Nim only allows mutual type references
  # within ONE `type` block. So: silence Deprecated warnings for the
  # whole types module. Consumer code (per-domain modules and user
  # code) still gets warnings on deprecated symbols they use
  # directly — only intra-types-module noise is suppressed.
  if allEnums.len > 0 or allChunks.len > 0:
    result.add "{.push warning[Deprecated]: off.}\n\n"
    result.add "type\n"
    for e in allEnums:
      result.add e.typeDecl
      result.add "\n"
    for c in allChunks:
      result.add c.text
    result.add "\n"

    if allEnums.len > 0:
      result.add "const\n"
      for e in allEnums:
        result.add e.wireConst
      result.add "\n"
      for e in allEnums:
        result.add e.hooks

    result.add "{.pop.}\n"

proc emitDomainModule*(d: PdlDomain; registry: NameRegistry): string =
  ## Per-domain commands + event-registration module. Imports the
  ## shared types module and the runtime transport.
  ##
  ## ``registry`` is the same one passed to ``emitTypesModule`` — used
  ## here only by lift paths inside command parameter walks (rare;
  ## most inline enums hang off properties which were already lifted
  ## during the types pass).
  let ctx = EmitCtx(domain: d, registry: registry,
                    liftedNames: initHashSet[string]())

  result = "## Generated bindings for the CDP `" & d.name & "` domain.\n"
  if d.doc.len > 0:
    result.add "##\n"
    for line in d.doc: result.add "## " & line & "\n"
  result.add "##\n"
  result.add "## Generated from `resources/devtools-protocol/pdl/`. Do not edit by hand.\n\n"
  result.add "import chronos\n"
  result.add "import std/[json, jsonutils, options]\n"
  result.add "import ../jsonhooks\n"
  result.add "import ../transport\n"
  result.add "import ./types\n"
  result.add "export types\n"
  result.add "\n"

  for c in d.commands:
    let dep = c.deprecated or d.deprecated
    if dep: result.add "{.push warning[Deprecated]: off.}\n"
    result.add ctx.emitCommand(c)
    if dep: result.add "{.pop.}\n"

  for ev in d.events:
    let dep = ev.deprecated or d.deprecated
    if dep: result.add "{.push warning[Deprecated]: off.}\n"
    result.add ctx.emitEventRegistration(ev)
    if dep: result.add "{.pop.}\n"
