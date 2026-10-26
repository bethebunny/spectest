# Brief: wire

The spec language's own equalities, its order and its text for values, as functions
on `Value`.

**Owns:** `host/wire/` except `value.mojo`, which is a contract (add accessors only),
and `tests/host/wire/` (add to `test_value.mojo` only).

**Read first:** `docs/language.md` (Types and values; Expressions, the equality rule),
`host/wire/value.mojo`, `host/numeric/bigint.mojo`, `host/numeric/text.mojo`,
`docs/v2/mojo.md`. v1's behavior is the reference: `src/spectest/values.py`, the
`same`, `eq` and ordering code in `src/spectest/prelude/` and `src/spectest/eval.py`,
and `format_value` in `src/spectest/eval.py`.

## Deliver

1. `wire/equality.mojo`:
   - `canonical_eq(a, b) raises -> Bool`, the `==` of the language, for the types the
     language gives canonical equality: bool, string, bytes, int, real, qerr, enums,
     and lists, tuples, options, maps and records whose components have it. Maps and
     records compare without regard to order. A float, handle or error anywhere
     inside raises: the checker keeps such `==` out of specs, and this is the guard.
   - `same(a, b) -> Bool`: bit-identical equality on every kind. Floats by format and
     bits, handles by id, maps and records without regard to order.
   - `hash_canonical(value, mut hasher)`, consistent with `canonical_eq`, and
     `hash_same`, consistent with `same` (map pairs combine in an order-free way).
2. `wire/order.mojo`: `compare(a, b) raises -> Int` (-1, 0 or 1), the language's `Ord`:
   integers of every width and reals by value (an INT and a REAL compare
   mathematically, with -inf and +inf at the ends), `false < true`, strings by code
   point (the byte order of UTF-8), bytes by unsigned byte, tuples and lists
   lexicographically with a proper prefix first. Any other kind raises.
   `is_ord(value) -> Bool`.
3. `wire/format.mojo`: `format_value(value) raises -> String`, the text reports show,
   matching v1's `format_value`: `true`, `-12`, floats through
   `numeric.text.float_text` (a placeholder until numeric lands; don't test its
   digits), quoted strings with escapes, `b"..."` bytes, `[a, b]`, `(a, b)` and
   `(a,)`, maps as `{k: v}`, `none` and `some(x)`, records with their fields, enum
   members, handles as `<Class #id>`, errors with class and message, reals as v1
   prints them, qerr as `3`, `2nan` or `3 + 2nan`.

## Acceptance

`uv run pytest tests/host/wire` passes, covering each kind for each function; maps
equal under reordering; a float inside a list making `canonical_eq` raise; `same`
telling -0.0 from 0.0 and two NaN payloads apart; `compare` across INT and REAL,
non-BMP strings (code point order, not UTF-16 order), prefixes, and raising on maps;
hash consistency on equal pairs; and the formatting table.

## Out of scope

Arithmetic (numeric), prelude functions such as `ieee_eq` and `qe` (prelude, wave 2),
typed decoding.
