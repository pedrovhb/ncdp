## Shared JSON serialization machinery for the CDP bindings.
##
## This module provides three things every domain module imports:
##
## * `Binary` — a `distinct seq[byte]` newtype the codegen uses for PDL
##   `binary` fields. Ships with `to/fromJsonHook` overloads that
##   round-trip through base64, matching the CDP wire convention.
## * `dropNullFields` — a post-processor for outbound JSON-RPC frames.
##   `std/jsonutils` serialises `none(T)` as `null`; CDP servers accept
##   that, but the convention is to omit absent optional fields entirely.
##   The transport runs every outbound frame through this proc.
## * Re-exports of `std/jsonutils` and `std/json` so generated modules
##   only need `import ncdp/cdp/jsonhooks` to have `toJson` / `jsonTo`
##   / `Option` in scope.

import std/[base64, json, jsonutils, options, tables]
export json, jsonutils, options

const cdpDecodeOpts* = Joptions(
  allowExtraKeys: true,    ## Chrome adds fields without protocol bumps.
  allowMissingKeys: true)  ## Optional/Option[T] fields commonly absent.
  ## Default `Joptions` for inbound JSON decoding of CDP responses.
  ## Both flags are necessary in practice: Chrome ships fields we
  ## don't know yet without updating the protocol version, and
  ## omits any field whose value is "default" (including `Option`s
  ## that the wire wouldn't see at all when `none`).

type
  Binary* = distinct seq[byte]
    ## PDL `binary` field. Wire form: a base64-encoded string. In Nim
    ## the bytes are kept raw; conversion happens in the JSON hooks.

proc bytes*(b: Binary): lent seq[byte] {.inline.} = seq[byte](b)
proc `==`*(a, b: Binary): bool {.borrow.}
proc len*(b: Binary): int {.borrow.}

proc toJsonHook*(b: Binary; opt = initToJsonOptions()): JsonNode =
  ## Outbound: encode raw bytes to base64. CDP uses the standard
  ## (non-URL-safe) alphabet without padding stripping.
  let s = base64.encode(seq[byte](b))
  newJString(s)

proc fromJsonHook*(b: var Binary; n: JsonNode; opt = Joptions()) =
  ## Inbound: decode a base64 string back to bytes. Anything other than
  ## a `JString` is a protocol-level error and is surfaced through the
  ## same `ValueError` channel `jsonutils` uses for type mismatches.
  if n.kind != JString:
    raise newException(ValueError,
      "expected base64 string for Binary, got " & $n.kind)
  let raw = base64.decode(n.getStr())
  var data = newSeq[byte](raw.len)
  for i in 0 ..< raw.len: data[i] = byte(raw[i])
  b = Binary(data)

proc dropNullFields*(node: JsonNode) {.raises: [].} =
  ## Recursively strip `null`-valued keys from every object inside
  ## `node`. CDP commands omit unset optional parameters rather than
  ## sending `"foo": null`, so the transport runs this once on each
  ## outbound frame before serializing.
  case node.kind
  of JObject:
    var doomed: seq[string]
    for k, v in node.pairs:
      if v.kind == JNull: doomed.add(k)
      else: dropNullFields(v)
    for i in 0 ..< doomed.len: node.fields.del(doomed[i])
  of JArray:
    for child in node.items: dropNullFields(child)
  else: discard
