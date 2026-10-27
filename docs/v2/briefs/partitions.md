# Brief: partitions

Compiles partition classes and other set expressions to partition sets, and proves
what the language promises about them: classes are disjoint and cover the domain
that `requires` admits.

**Owns:** `host/partitions/`, `tests/host/partitions/`.

**Read first:** `docs/language.md` (Declarations: partitions; the partition sets in
the prelude list), `host/sets/` (the landed set library), `host/numeric/` (`Real`,
`round_to`, `exactly`, `next_up`, `parse_number`), `host/syntax/`, `host/check/types.mojo`,
`host/check/spec.mojo`, `docs/v2/mojo.md`. v1 is the reference: `src/spectest/sets.py`
(compiling set expressions, `float_range`, `int_range`, `admitted`, and the checks)
and `tests/sets/`.

## Deliver

1. `float_range(mut ctx, format, lo: Optional[Real], hi: Optional[Real]) -> BitSet`:
   the non-NaN values v with lo <= v < hi, by numeric value, so both zeros count as 0.
   An absent bound leaves that end open, including its infinity. Also
   `float_equal(mut ctx, format, c: Real) -> BitSet` (both zeros for 0).
2. `compile_set(mut ctx, ast: Ast, mut types: Types, elem_type: Int, node: Int,
   classes) raises -> BitSet`: a set expression of the syntax tree as a set of
   `elem_type`'s bit patterns. That covers `T.nan`, `T.inf`, `T.zero`,
   `T.subnormal`, `T.normal`, `T.finite`, `T.positive` and `T.negative`;
   `T.range(a, b)` with literal bounds or `none`; `T.pattern("...")`; `{v, ...}`;
   `|`, `&`, `-` and parentheses; and names of earlier classes of the same partition
   (`classes` maps names to their sets). It works on fixed-width types (floats, fixed
   integers, bool) and reads the tree directly, as v1's compiler does, so it needs no
   name resolution. Errors are `path:line:col: message`, with v1's texts.
3. `admitted(mut ctx, spec: Spec, fn: Int, param: Int) raises -> Optional[BitSet]`:
   the values of a fixed-width parameter that the function's `requires` clauses
   admit, when they can be read as sets (v1's analysis), else None.
4. `compile_partitions(mut ctx, spec: Spec) raises -> PartitionSets`. For every
   partition of every function:
   - over a fixed-width parameter, each class's set;
   - the check that classes are disjoint, which on failure names both classes and an
     example member;
   - the check that their union equals the admitted domain (the whole type when
     `requires` says nothing set-like), which on failure says how many values are
     missing and gives an example;
   - for other parameter types, a mark that the class is a predicate.
   Errors are raised together, as one message of `path:line:col: message` lines.
   Warnings are returned with the sets. `PartitionSets` gives the set of class `k` of
   partition `p` of function `f`.

The checker that builds `Spec` is written at the same time. For tests, build the
`Spec`s you need by hand from `parse_spec` output: functions, parameter types from the
TYPE nodes, partitions with their node ids, and `requires` clauses. Put that helper in
`host/partitions/testing.mojo`. Test files can only import from the include roots.

## Acceptance

`uv run pytest tests/host/partitions` passes, covering:

- v1's set compilation tests (`tests/sets/`), ported;
- `float_range` on every format at zeros, infinities, subnormal edges and open ends,
  checked against brute force over all f16 patterns;
- disjointness and coverage failures with their messages, and `requires` narrowing
  the domain (`requires not is_nan(x)` makes a partition without a NaN class
  complete);
- the partitions of the fixed-width parameters in `examples/libm/libm.spec` and
  `trials/bitpattern/bitpattern.spec`, compiled and passing both checks through the
  hand-built `Spec`;
- speed: compiling every partition of `libm.spec` takes under 5 ms (print it).

## Out of scope

Typing (the checker), predicate classes' evaluation (evaluator, wave 2b), generation.
