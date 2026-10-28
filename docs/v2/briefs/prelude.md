# Brief: prelude

The system prelude's functions, evaluated on `Value`s. The checker types them; this
package computes them.

**Owns:** `src/prelude/` (`src/spec/prelude_names.mojo` is a contract: append only),
`tests/mojo/prelude/`.

**Read first:** `docs/language.md` (Expressions, the prelude list),
`src/spec/prelude_names.mojo`, `src/value/` (Value, equalities, order),
`src/value/` (BigInt, Real, float conversions), `src/spec/types.mojo`,
`docs/v2/mojo.md`. v1 is the reference for every function: `spectest/prelude/`
(`floats.py`, `reals.py`, `ints.py`, `collections.py`, `cr.py`, `mp.py`) and
`tests/prelude/`.

## Deliver

1. `src/prelude/api.mojo`:

   ```mojo
   struct CallArgs(Movable):
       var args: List[Value]           # positional arguments
       var names: List[String]         # keyword argument names
       var keywords: List[Value]       # keyword argument values, same order
       var type_args: List[Int]        # `wrap<i32>(x)`: [the type id of i32]
       var arg_types: List[Int]        # static type of each positional argument

   def call(id: Int, args: CallArgs, types: Types) raises -> Value
   ```

   `call` evaluates every function in `prelude_names.mojo` by id, except `fresh`,
   `same_object` and `shares_memory`. Those ask the host about identity, so the
   evaluator answers them; `call` raises for them. An evaluation error (an index out
   of range, promoting a NaN, `unwrap` of none, a malformed call) raises an `Error`
   whose message names the function, as v1's `EvalError`s do.
2. Every function as v1 computes it: the float functions (`is_nan` ... `signbit`,
   `bits`, `next_up`, `next_down`, `ulp<T>`, `qe`, `steps`, `nans`, `ieee_eq`,
   `same`, `real`), fixed width (`wrap<T>`, `fits<T>`, `round<T>`), collections
   (`len`, `sorted` (stable, by the language's order), `is_sorted`,
   `is_permutation`, `is_subsequence`, `distinct`, `index_of`, `keys`, `values`,
   `range`, `eq` with its `float` and `order` knobs), options (`some`, `is_some`,
   `is_none`, `unwrap`), bytes and text (`le_uint`, `valid_utf8`, `codepoints`), and
   v2's two new ones, `bit_length` and `from_codepoints` (the inverse of
   `codepoints`; an invalid code point is an error).
3. `mp.*` and `cr.*` on MPFR through FFI. Load the system's `libmpfr.so.6`, or, if it
   is missing, the copy that gmpy2 ships in the venv (`site-packages/gmpy2.libs/`).
   `mp.*` returns the exact value of MPFR's 256-bit result as a real. `cr.*` returns
   the correctly rounded result in the argument's format, with IEEE 754's special
   cases, as v1's `cr.py` does.
4. As the language requires, no function delegates to the implementation it
   defines: `sorted` is not a library sort, and `valid_utf8` follows Table 3-7 of
   the Unicode Standard.

## Acceptance

`uv run pytest tests/mojo/prelude` passes, covering v1's prelude tests
(`tests/prelude/`), ported, and v2's two new functions. Keep test files small enough
to compile fast. Split by area (floats, ints, collections, text, cr and mp), and scale
large sample counts with `SPECTEST_STRENGTH` (see `docs/v2/mojo.md`).

## Out of scope

Typing (the checker); the identity functions; evaluation of expressions (the
evaluator, wave 2b).
