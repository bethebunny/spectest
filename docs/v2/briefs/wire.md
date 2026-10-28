# Brief: wire

The spec language's own equalities, its order and its text for values, as functions
on `Value`.

**Owns:** `src/value/` except `value.mojo`, which is a contract (add accessors only),
and `tests/mojo/value/` (add to `test_value.mojo` only).

**Read first:** `docs/language.md` (Types and values; Expressions, the equality rule),
`src/value/value.mojo`, `src/value/bigint.mojo`, `src/value/number_text.mojo`,
`docs/v2/mojo.md`. v1's behavior is the reference: `spectest/values.py`, the
`same`, `eq` and ordering code in `spectest/prelude/` and `spectest/eval.py`,
and `format_value` in `spectest/eval.py`.

## Deliver

1. `value/equality.mojo`:
   - `canonical_eq(a, b) raises -> Bool`, the `==` of the language, for the types the
     language gives canonical equality: bool, string, bytes, int, real, qerr, enums,
     and lists, tuples, options, maps and records whose components have it. Maps and
     records compare without regard to order. A float, handle or error anywhere
     inside raises: the checker keeps such `==` out of specs, and this is the guard.
   - `same(a, b) -> Bool`: bit-identical equality on every kind. Floats by format and
     bits, handles by id, maps and records without regard to order.
   - `hash_canonical(value, mut hasher)`, consistent with `canonical_eq`, and
     `hash_same`, consistent with `same` (map pairs combine in an order-free way).
2. `value/order.mojo`: `compare(a, b) raises -> Int` (-1, 0 or 1), the language's `Ord`:
   integers of every width and reals by value (an INT and a REAL compare
   mathematically, with -inf and +inf at the ends), `false < true`, strings by code
   point (the byte order of UTF-8), bytes by unsigned byte, tuples and lists
   lexicographically with a proper prefix first. Any other kind raises.
   `is_ord(value) -> Bool`.
3. `value/text.mojo`: `format_value(value) raises -> String`, the text reports show,
   matching v1's `format_value`: `true`, `-12`, floats through
   `value.number_text.float_text` (a placeholder until numeric lands; don't test its
   digits), quoted strings with escapes, `b"..."` bytes, `[a, b]`, `(a, b)` and
   `(a,)`, maps as `{k: v}`, `none` and `some(x)`, records with their fields, enum
   members, handles as `<Class #id>`, errors with class and message, reals as v1
   prints them, qerr as `3`, `2nan` or `3 + 2nan`.

## Acceptance

`uv run pytest tests/mojo/value` passes, covering each kind for each function; maps
equal under reordering; a float inside a list making `canonical_eq` raise; `same`
telling -0.0 from 0.0 and two NaN payloads apart; `compare` across INT and REAL,
non-BMP strings (code point order, not UTF-16 order), prefixes, and raising on maps;
hash consistency on equal pairs; and the formatting table.

## Out of scope

Arithmetic (numeric), prelude functions such as `ieee_eq` and `qe` (prelude, wave 2),
typed decoding.
