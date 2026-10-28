# Brief: numeric

Exact numbers for the host: extended reals, exact conversions between floats and
reals, numeric literals, and the text of floats and reals.

**Owns:** `src/value/` (`bigint.mojo` and `float_formats.mojo` are contracts: add only;
in `number_text.mojo` replace the placeholder body of `float_text`, keeping its signature),
`tests/mojo/value/`.

**Read first:** `docs/language.md` (Types and values, Numbers), `docs/v2/mojo.md`,
`src/value/*.mojo`. v1 is the reference: `parse_number` in
`spectest/lang/lexer.py`, `format_float` and `shortest_digits` in
`spectest/prelude/floats.py`, and `spectest/prelude/reals.py`.

## Deliver

1. `value/real.mojo`: `struct Real`, an exact rational in lowest terms with a
   positive denominator, or +inf or -inf (denominator 0, numerator 1 or -1), so its
   numerator and denominator are exactly what `Value.real` stores. Construction from
   ints and fractions; `+ - * /` and negation, raising for x/0, inf - inf and 0 \* inf;
   a total order over the extended reals; `floor`, `ceil` and `trunc` to `BigInt`
   (raising on infinities); `is_integer`; `sign`; `abs`.
2. `value/floats.mojo`, on a `FloatFormat` and a bit pattern:
   - classification: `is_nan`, `is_inf`, `is_zero`, `is_subnormal`, `is_normal`,
     `is_finite`, `signbit`;
   - `to_real(format, bits) raises -> Real`, exact; infinities map to the infinite
     reals, and a NaN raises "promoting a NaN";
   - `round_to(format, r: Real) -> UInt64`: round half to even, overflow to the
     signed infinity, gradual underflow to subnormals, and a zero result taking the
     sign of `r` (+0 for an exact 0);
   - `exactly(format, r: Real) -> Optional[UInt64]`: the pattern holding exactly `r`,
     if there is one (+0 for 0);
   - `next_up` and `next_down` on patterns, as IEEE 754's nextUp and nextDown.
3. `value/literal.mojo`: `parse_number(text) raises -> Real` with a flag or a second
   function telling integer literals from others: decimal integers, decimals and
   exponents (`1.5`, `1e-3`, `2.5E+10`), hex integers (`0xff`), hex floats
   (`0x1p-26`, `0x1.8p3`), `_` between digits. Exact, as v1's `parse_number`.
4. `value/number_text.mojo`: `float_text(format_id, bits)` exactly as v1's `format_float`:
   the shortest decimal that reads back to the same value in its own format, in the
   style of Python's float `repr` (`1.0`, `0.1`, `1e-05`, `1e+16`, `-0.0`), `inf` and
   `-inf`, `nan` for the canonical quiet NaN and `nan:0x...` (the full pattern) for any
   other. `real_text(r)` as v1 prints reals.

## Acceptance

`uv run pytest tests/mojo/value` passes, covering:

- every f16 and every bf16 pattern (65,536 each): `round_to(to_real(x)) == x` for
  each non-NaN, and `float_text` reads back (through `parse_number` and `round_to`)
  to the same pattern, with no shorter decimal that would;
- f32 and f64 on at least 100,000 patterns each from a fixed-seed generator, the same
  two properties, and for f64 `float_text` equal to Python's `repr`, checked against
  a table generated with Python and checked in under `tests/mojo/value/data/`
  (commit the small generating script beside it);
- rounding at ties, at the overflow threshold, at the subnormal boundary and below
  the smallest subnormal, and signed zeros;
- `exactly` and `next_up` and `next_down` at zeros, infinities and the extremes;
- literals: v1's cases from `tests/lang/test_lang_lexer.py`, plus malformed ones.

Keep the exhaustive tests fast: 65,536 patterns should take well under a second
compiled. Mark nothing slow unless it is.

## Out of scope

Prelude functions (`ulp`, `qe`, `wrap`, `fits`, `round<T>`) built on these, which come
in wave 2.
