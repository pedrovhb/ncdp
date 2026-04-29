# Nim `raises` effect system — research for CDP code generator

## 1. Anatomy: the exception hierarchy & what `raises` actually checks

Nim's three-way root hierarchy is defined in `/references/Nim/lib/system.nim`:

- `Exception`  (line 530) — base, inherits `RootObj`. Has fields `parent`, `name`, `msg`, `trace`.
- `Defect = object of Exception` (line 548) — "uncatchable" / programmer-error class.
- `CatchableError = object of Exception` (line 553) — recoverable errors.

So the tree is `Exception → {Defect, CatchableError}`. A bare `Exception` is *neither* a `Defect` nor a `CatchableError`; it's a third sibling at the root [^1]. `IOError`, `ValueError`, `OSError`, `KeyError`, `ResourceExhaustedError` are all `CatchableError`. `ArithmeticDefect`, `IndexDefect`, `AssertionDefect`, `OverflowDefect`, `NilAccessDefect`, `RangeDefect`, etc. are `Defect`s [^2].

`{.raises: [E1, E2].}` means **"the proc may raise only E1, E2, or *subtypes* of them"**, not exact types. This is implemented by `subtypeRelation` in `compiler/sempass2.nim:1607`: each real raised type is matched against the spec via `safeInheritanceDiff(real, specEntry) <= 0`.

Critically, **Defects are exempt from `raises` tracking**. `addRaiseEffect` (sempass2.nim:488) only records a raised type if `not isDefectException(e.typ)` (line 497). `isDefectException` (`compiler/types.nim:1598`) walks up the base-class chain looking for `system.Defect`. So you never list Defects in `raises:` — they pass through invisibly.

Try/except *narrows* the inferred raises set via `catches` (sempass2.nim:531). `catches(e)` removes from `tracked.exc` any entry that's a *subtype* of `e`. So `except CatchableError` removes all CatchableError descendants but leaves bare `Exception` untouched; `except Exception` (or bare `except:`) catches everything (including bare `Exception` and any rogue ancestor).

## 2. The `cast(raises: [...])` block pragma

Defined in `compiler/sempass2.nim`. The flow: `nkPragmaBlock` handler at line 1506 calls `castBlock` (line 1239) which pattern-matches `wRaises` (line 1259) to populate `bc.exc`. Then `unapplyBlockContext` (line 1220) at block exit *truncates* `tracked.exc` back to the pre-block length and adds only the listed exceptions:

```
setLen(tracked.exc.sons, bc.oldExc)
for e in bc.exc:
    addRaiseEffect(tracked, e, e)
```

This is a **hard "trust me" override**: the inferred raises of the enclosed body are wholesale replaced by the cast's spec. `{.cast(raises: []).}: foo()` literally erases foo's effects. There are no rules — the cast is unchecked. It works inside async procs; it's just a nested pragma block in the AST.

## 3. `std/jsonutils.toJson` / `jsonTo` — why they "raise Exception"

`/references/Nim/lib/std/jsonutils.nim`:

- `jsonTo*[T]` (line 208) — has **no** explicit `{.raises.}` pragma.
- `fromJson*[T]` (line 183, 210) — same.
- `toJson*[T]` (line 301) — same.

When raises is unspecified, the compiler **infers** it from the body via `trackProc` (sempass2.nim:1739). `jsonTo`/`fromJson` are deeply generic and recursive (they dispatch through `fromJsonHook`, `fieldPairs`, `accessField`, `parseEnum`, etc.). The transitive call graph reaches code that can raise things the compiler cannot prove — recursion through generic instances and ultimately code that itself has no explicit raises and bottoms out with `raise (ref Exception)(...)` somewhere — so the inferred set contains the bare type `system.Exception`.

The error message text — "X can raise an unlisted exception: Y" — is produced at `sempass2.nim:1637-1638`. `Y` is `typeToString(r.typ)` of the actual inferred raised type. So when you see `… an unlisted exception: Exception`, **the literal `system.Exception` type is in the inferred set**, not "some unknown exception". That's why `except CatchableError as e` doesn't satisfy the checker: bare `Exception` is not a subtype of `CatchableError`.

## 4. Chronos `async: (raises: [...])` body transform

`/references/chronos/chronos/internal/asyncmacro.nim`, `wrapInTryFinally` (line 42). For every entry in your `raises:` whitelist it generates one `except` branch. Special cases:

- `Defect` is **always** added (line 145) and re-raised (line 79) — never converted to `Future.fail`, since defects mean the program is hosed.
- `CatchableError` and `CancelledError` get dedicated branches (lines 82-101).
- A **bare `Exception`** entry is only allowed when `handleException = true` (line 110-111); it then synthesizes `(ref AsyncExceptionError)(msg: ..., parent: exc)` and stores *that* in the future (since futures can only carry `CatchableError`).

If your raises whitelist is `[CDPError, CDPTransportError, CancelledError]`, chronos generates `except CDPError`, `except CDPTransportError`, `except CancelledError`, and `except Defect: raise`. **Nothing catches `system.Exception`**. The whitelist is checked by Nim against the macro-expanded body's inferred raises. Since `jsonTo` infers raises containing `Exception`, the check fails with the exact message you observed.

## 5. Why your generated code fails

Your `try` block has `except CatchableError as e: raise newException(CDPError, ...)`. This catches subtypes of CatchableError. It does not catch bare `Exception`. So after your try/except, the inferred raise set still contains `Exception`, and chronos's wrapper doesn't catch it either. Compiler emits `jsonTo(...) can raise an unlisted exception: Exception`.

Your inner `{.cast(gcsafe).}` is *only* about thread-safety; it does nothing for raises. You'd need `{.cast(raises: [...]).}` for that.

## 6. Recommended fix

Three options, ranked.

### Option A (recommended): wrap the marshal calls in `cast(raises: ...)` blocks

Localize the cast to just the json calls. The `await` stays out so cancellation is honored normally.

```nim
proc doSomething*(client: CDPClient; param: Option[seq[Foo]]): Future[FooResult] {.
    async: (raises: [CDPError, CDPTransportError, CancelledError]).} =
  let params = newJObject()
  try:
    {.cast(raises: [CDPError]).}:
      params["param"] = toJson(param.get)
  except CDPError as e: raise e
  except CatchableError as e:
    raise newException(CDPError, "Foo.doSomething: encode failed: " & e.msg)

  let raw = await client.sendCommand("Foo.doSomething", params)

  try:
    {.cast(raises: [CDPError]).}:
      result = jsonTo(raw, FooResult)
  except CDPError as e: raise e
  except CatchableError as e:
    raise newException(CDPError, "Foo.doSomething: decode failed: " & e.msg)
```

The cast asserts "treat this block as if it raises only `CDPError`". The inferred `Exception` is suppressed at the source. The surrounding try/except is just defensive — under the cast, neither branch will actually fire — so you can simplify to a plain unguarded call inside the cast if you don't need the wrapping. Cleanest:

```nim
{.cast(raises: [CatchableError]).}:
  result = jsonTo(raw, FooResult)
```

then a single `try/except CatchableError` at proc level translates to your CDPError. This is the **minimum-noise** generator emission.

### Option B: factor marshalling into a non-async helper with `raises: [CDPError]`

Generate a sibling helper `proc decodeFooResult(raw: JsonNode): FooResult {.raises: [CDPError].} =` whose body is `try: jsonTo(raw, FooResult) except Exception as e: raise newException(CDPError, e.msg)`. The `except Exception` (catch-all) inside the helper IS sufficient, since `safeInheritanceDiff(anything, Exception) <= 0`. The async proc then has clean inferred raises.

Trade-off: doubles the number of generated procs and adds a layer of indirection.

### Option C: declare the async proc with `(raises: [..., Exception], handleException: true)`

Lets chronos's macro install its own `except Exception` handler that converts to `AsyncExceptionError` (asyncmacro.nim:121-128). Trade-off: callers now see `AsyncExceptionError` instead of `CDPError`; loses the tidy custom-error contract you want.

**Pick A.** It's local, generated mechanically, and preserves the strict raises whitelist on the public proc signature. Use `cast(raises: [CatchableError])` around each `toJson` / `jsonTo` call, then a single proc-level `try/except CatchableError` to convert to `CDPError`.

---

[^1]: `Exception` declaration — `/references/Nim/lib/system.nim:530`; `Defect` — line 548; `CatchableError` — line 553.
[^2]: Concrete subclasses — `/references/Nim/lib/system/exceptions.nim:11-97`.
[^3]: Subtype check for raises — `/references/Nim/compiler/sempass2.nim:1607-1614` (`subtypeRelation`), iteration `checkRaisesSpec` lines 1616-1645.
[^4]: Defects exempt from inferred raises — `/references/Nim/compiler/sempass2.nim:496-498` (`addRaiseEffect`); test in `/references/Nim/compiler/types.nim:1598-1607` (`isDefectException`).
[^5]: `cast(raises: [...])` block semantics — `/references/Nim/compiler/sempass2.nim:1239-1270` (`castBlock`), `1216-1237` (`unapplyBlockContext`), invoked from `nkPragmaBlock` at line 1506-1524.
[^6]: try/except narrowing — `/references/Nim/compiler/sempass2.nim:531-549` (`catches`, `catchesAll`); driven by `trackTryStmt` at line 564.
[^7]: Error message construction — `/references/Nim/compiler/sempass2.nim:1637-1638` (`renderTree(rr) & " " & msg & typeToString(r.typ)`); call sites at lines 1655, 1793.
[^8]: `jsonTo` / `fromJson` / `toJson` lack explicit raises — `/references/Nim/lib/std/jsonutils.nim:183, 208, 210, 301`. `raiseJsonException` raises only `ValueError` (line 125-128) but the inferred set is dominated by transitive calls.
[^9]: chronos async wrapper — `/references/chronos/chronos/internal/asyncmacro.nim:42-170` (`wrapInTryFinally`); `Defect` always re-raised line 69-81, 145; `Exception` requires `handleException` mode line 110-129.
[^10]: `AsyncExceptionError` definition — `/references/chronos/chronos/internal/errors.nim:7-8`.
[^11]: Inferred raises take effect via `trackProc` — `/references/Nim/compiler/sempass2.nim:1739-1798`; `effects[exceptionEffects] = t.exc` at line 1798 when no spec given.
