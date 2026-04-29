## AST for Chrome DevTools Protocol PDL files.
##
## The hierarchy uses `ref object of RootObj` so visitors can dispatch with
## `method` and clients can extend nodes with extra annotations. Every node
## carries its source line for error reporting, and most declarations carry
## the doc-comment block that immediately preceded them in the source.

import std/options

type
  PdlPos* = object
    ## Source location of a node. ``line`` is 1-based, matching most editors
    ## and the line numbers ``nim c`` emits.
    line*: int
    col*: int

  PdlNode* = ref object of RootObj
    ## Base of every AST node. ``doc`` is the (possibly empty) doc-comment
    ## block attached to a declaration; trivia comments not attached to any
    ## declaration are dropped.
    pos*: PdlPos
    doc*: seq[string]

  # ---------------------------------------------------------------- types ----

  PdlPrimitiveKind* = enum
    ## The set of leaf types PDL recognises. ``ppAny`` is the wildcard
    ## (``any`` in PDL). ``ppBinary`` is base64-encoded bytes on the wire.
    ppString, ppInteger, ppNumber, ppBoolean, ppAny, ppBinary, ppObject

  PdlType* = ref object of PdlNode
    ## Reference to a type used in a property, parameter, return, or
    ## ``extends`` clause. Object variants live in concrete subclasses.

  PdlPrimitiveType* = ref object of PdlType
    kind*: PdlPrimitiveKind

  PdlArrayType* = ref object of PdlType
    ## ``array of <element>``.
    element*: PdlType

  PdlRefType* = ref object of PdlType
    ## A named type reference. ``domain`` is set when the reference is
    ## qualified (``Runtime.RemoteObject``), ``none`` for an unqualified
    ## reference within the current domain.
    domain*: Option[string]
    name*: string

  PdlEnumType* = ref object of PdlType
    ## An anonymous (inline) enum, attached to a property or parameter.
    members*: seq[PdlEnumMember]

  PdlEnumMember* = ref object of PdlNode
    name*: string

  # ----------------------------------------------------------- properties ----

  PdlProperty* = ref object of PdlNode
    ## A field of an object type, a parameter of a command or event, or a
    ## return value of a command. The same shape covers all three because
    ## PDL parses them identically.
    name*: string
    typ*: PdlType
    optional*: bool
    experimental*: bool
    deprecated*: bool

  # ------------------------------------------------------- type declarations -

  PdlTypeDecl* = ref object of PdlNode
    ## Base for any ``type Name extends ...`` declaration inside a domain.
    ## Concrete subclasses carry the body.
    name*: string
    experimental*: bool
    deprecated*: bool

  PdlAliasDecl* = ref object of PdlTypeDecl
    ## ``type Name extends <primitive-or-ref>`` with no body — a transparent
    ## alias over an existing type.
    base*: PdlType

  PdlObjectDecl* = ref object of PdlTypeDecl
    ## ``type Name extends object`` followed by a ``properties`` block.
    properties*: seq[PdlProperty]

  PdlEnumDecl* = ref object of PdlTypeDecl
    ## A named, top-level enum: ``type Name extends string`` followed by an
    ## ``enum`` block listing the allowed values.
    members*: seq[PdlEnumMember]

  # ----------------------------------------------------- commands & events ---

  PdlCommand* = ref object of PdlNode
    name*: string
    experimental*: bool
    deprecated*: bool
    redirect*: Option[string]   ## ``redirect <Domain>`` clause, if any
    parameters*: seq[PdlProperty]
    returns*: seq[PdlProperty]

  PdlEvent* = ref object of PdlNode
    name*: string
    experimental*: bool
    deprecated*: bool
    parameters*: seq[PdlProperty]

  # ------------------------------------------------------------- domains -----

  PdlDomain* = ref object of PdlNode
    name*: string
    experimental*: bool
    deprecated*: bool
    dependsOn*: seq[string]
    types*: seq[PdlTypeDecl]
    commands*: seq[PdlCommand]
    events*: seq[PdlEvent]

  PdlVersion* = ref object of PdlNode
    major*: int
    minor*: int

  PdlInclude* = ref object of PdlNode
    ## ``include path/to/other.pdl`` directive at top level. The path is
    ## stored verbatim; resolution is the caller's responsibility (see
    ## ``parsePdlFile``'s ``followIncludes`` parameter).
    path*: string

  PdlFile* = ref object of PdlNode
    ## Top-level container produced by parsing one ``.pdl`` source file.
    version*: Option[PdlVersion]
    domains*: seq[PdlDomain]
    includes*: seq[PdlInclude]

# ---------------------------------------------------------------- helpers ----

proc primType*(kind: PdlPrimitiveKind; pos = PdlPos()): PdlPrimitiveType =
  PdlPrimitiveType(kind: kind, pos: pos)

proc primKindFromName*(name: string): Option[PdlPrimitiveKind] =
  ## Maps a builtin type keyword to its enum tag, or ``none`` if ``name``
  ## is a user-defined reference. Used by the parser when resolving the
  ## right-hand side of a property declaration.
  case name
  of "string": some(ppString)
  of "integer": some(ppInteger)
  of "number": some(ppNumber)
  of "boolean": some(ppBoolean)
  of "any": some(ppAny)
  of "binary": some(ppBinary)
  of "object": some(ppObject)
  else: none(PdlPrimitiveKind)
