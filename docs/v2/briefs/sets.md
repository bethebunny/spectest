# Brief: sets

Partition sets for the host, built directly on bitpattern's Mojo core: sets of
fixed-width bit patterns, the named sets of the float and integer types, and the
queries that generation and the checker need.

**Owns:** `src/partition/`, `tests/mojo/partition/`. `src/vendor/bitpattern` is used as is:
don't edit it.

**Read first:** `src/vendor/bitpattern/arena/*.mojo` (the decision-diagram arena:
`interval`, `diagram`, `exactly_these`, `union`, `intersection`, `difference`,
`complement`, `subset`, `disjoint`, `nth`, `rank`, `accepts`, counting), `docs/v2/mojo.md`,
`tests/mojo/vendor/test_arena.mojo`. Semantics come from v1 and bitpattern's Python
layer: `spectest/sets.py` (named sets, `float_range`, `int_range`, patterns), and
`git -C ~/bitpattern show v0.3.0:bitpattern/codecs/float.py` (and `intset.py`,
`pattern.py`).

## Deliver

1. `struct SetContext`, owning one `Arena` (no pausing: `never_pause`), with every
   operation as a method. Sets are `BitSet` values, a width and a root `Id`, valid
   only with the context that made them. No garbage collection: a context lives as
   long as one spec run.
2. Builders, for widths up to 64 with members as `UInt64`:
   - `empty(width)`, `full(width)`, `interval(lo, hi, width)` for [lo, hi),
     `exactly(values, width)`;
   - `pattern(text, width) raises`, in the pattern syntax v1's `T.pattern("...")`
     accepts (bitpattern's);
   - `int_range(width, signed, lo, hi)`: integers in [lo, hi) as two's-complement
     patterns, either bound optional (`Optional[BigInt]`), clamped to the type;
   - `float_named(format, name) raises` for `nan`, `inf`, `zero`, `subnormal`,
     `normal`, `finite`, `positive` and `negative` (by sign bit, so zeros and NaNs
     count), as bitpattern's float codecs define them;
   - `float_magnitudes(format, lo, hi, negative)`: patterns whose magnitude (the bits
     below the sign) is in [lo, hi), with the sign bit set or clear. v1's
     `float_range` is built from two of these once reals can be converted (wave 2).
3. Algebra: `union`, `intersection`, `difference`, `complement` (within the width).
4. Queries: `is_empty`, `equal`, `subset`, `disjoint`, `count -> BigUInt`,
   `contains(bits)`, `nth(n: BigUInt) -> UInt64` (the n-th member in increasing
   order, which is how generation samples), `rank(bits) -> BigUInt`, and
   `members(limit) raises -> List[UInt64]` for sets small enough to list.

## Acceptance

`uv run pytest tests/mojo/partition` passes, covering:

- the f16 named sets against a brute-force count over all 65,536 patterns done in the
  test with plain bit tests;
- for every format, `nan`, `inf`, `zero`, `subnormal` and `normal` disjoint with
  union `full`, and `positive` and `negative` splitting `full`;
- the f64 normal count, 18,428,729,675,200,069,632;
- `int_range` on i8 (all of [-128, 128); [-5, 5) has 10 members and holds 0xFB but
  not 0x05), on u64 near 2\*\*64, and with open ends;
- patterns, including v1's cases from `tests/sets/test_sets_compile.py` that apply;
- `nth` and `rank` as inverses on assorted sets, and the laws of the algebra;
- speed: building every named set of every format takes under 5 ms (print it).

## Out of scope

Compiling set expressions from the syntax tree, and anything needing exact reals
(`float_range` with real bounds, `T.range` on floats): those come with the checker and
numeric in wave 2.
