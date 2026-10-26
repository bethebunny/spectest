# sorting findings

This is what spectest found when it ran sorting.spec against Python's built-ins, numpy and three seeded bugs. Each finding gives:
- the clause;
- the counterexample;
- an independent check;
- why it does or does not violate the spec.

The plain test functions at the end of examples/sorting/test_sorting.py assert these findings without spectest. The spec was not changed.

Environment: Python 3.13.9, numpy 2.5.4, Hypothesis 6.170.9, pytest 9.1.1, on x86-64 Linux (WSL2). The CPU has AVX2, so numpy's `X86_V3` dispatch target is found; it has no AVX-512.

## 1. The real implementations pass every clause

- **test_builtin** passes all 28 items at 500 examples each. It binds:
  - `sorted` as `sort`;
  - `sorted(xs, key=itemgetter(0))` as `sort_by_first`;
  - `list.sort` as `sort_in_place`, on a `MutableList` bound to Python lists.

  The instantiations are T = i64 and T = string, and (K, V) = (i64, string) and (string, i64).
- **test_numpy** passes all 14 items. It binds:
  - `np.sort` on an int64 array; the array reads back as `list<i64>`;
  - the pairs reordered by `np.argsort(keys, kind="stable")`;
  - `ndarray.sort` on a `MutableList` bound to int64 arrays.

  The instantiations are T = i64 and (K, V) = (i64, string).
- **A deep run** of both conformances (3,000 examples per item, `--spectest-seed=11`) gave 0 fail, 0 skip and 0 spec error on all 42 items.
- **Strings** order the same way on both sides. The prelude's `is_sorted` compares strings by code point, as Python does.

## 2. numpy's default argsort reorders equal keys (test_numpy_default_kind)

**Clause.** `sort_by_first.stable[K=i64, V=string]`: `all(p in xs: filter(q in result: q.0 == p.0) == filter(q in xs: q.0 == p.0))`.

**Counterexample.**
- Input: xs = [(1, ""), (1, ""), (0, ""), (0, "0")].
- Result: [(0, "0"), (0, ""), (1, ""), (1, "")]. The two pairs with key 0 come out in reverse order.
- 51 examples passed before it, at 500 examples per item.
- At 100 examples per item, spectest stopped at a 6-element list with the same defect. Plain Hypothesis on `st.lists(st.tuples(...))` also stops at 4 or 5 elements on some seeds, so this comes from how the bug behaves, not from spectest's generators. Later runs, with long lists and spectest's shrinking pass, report 5-element lists such as [(1, "0"), (0, ""), (1, ""), (1, ""), (0, "")].

**Independent check.** `test_numpy_default_argsort_is_unstable_on_short_arrays`:
- `np.argsort([1, 1, 0, 0])` is [3, 2, 1, 0];
- `kind="stable"` gives [2, 3, 0, 1].

**Why it violates the spec.** `stable` requires the pairs with each key to keep their input order. numpy documents its default kind ("quicksort") as not stable, so this is a real difference, not a numpy bug.

**Mechanism.** On x86-64 with AVX2, numpy 2.5.4 dispatches 64-bit argsort to a SIMD sort, which reorders equal keys from 4 elements on. Measured over key patterns from {0, 1, 2}:
- 7 of the 81 patterns of length 4 come out reordered;
- 4,902 of the 6,561 patterns of length 8 do;
- no pattern of length 3 or less does.

**Can spectest's list sizes expose the portable sort?** Yes, since spectest draws some long lists. Setting `NPY_DISABLE_CPU_FEATURES=X86_V3` turns that dispatch off, and numpy then uses its portable sort. That sort is stable on short arrays only:
- `test_numpy_portable_argsort_is_stable_on_short_arrays` runs in a subprocess with the variable set. Every weak order of up to 6 keys, every {0, 1, 2} pattern of length 7 and 8, and 16 equal keys sort stably; 17 equal keys do not.
- Most of spectest's lists have at most `Sizes.max_list` = 8 elements. With only those (`sizes=Sizes(long_share=0)`, as `explore_sorting.py::test_explore_default_kind` sets), the conformance passed all 5 items at 5,000 examples per item (91 s), and the explore conformance passes at 2,000.
- A sixteenth of the top-level lists are long, 17 to 100 elements (`Sizes.long_share`). With them, test_numpy_default_kind fails `stable` on the portable sort too, at seeds 0 to 4, each time on 17 pairs with key 0: 16 of them (0, "") and one (0, "0"), which the sort moves.
- `explore_sorting.py::test_longer_lists_expose_the_default_kind` runs the conformance with lists of up to 40 elements (`sizes=Sizes(max_list=40, long_share=0)`). Its minimized counterexample has 17 pairs on the portable sort and 5 on the SIMD sort.

**Decision.**
- test_numpy_default_kind lists `sort_by_first.stable` in `expect_fail` on every machine: the default argsort fails it on both code paths.
- The probe `sorting_impls.short_unstable_keys()` (key patterns over {0, 1, 2} of at most 8 elements) still says which path this machine takes, for the plain tests.
- Long lists also mean that `sorted` and `list.sort` are tested beyond CPython's binary insertion sort: according to CPython's Objects/listobject.c (`merge_compute_minrun`), timsort sorts fewer than 64 elements as a single run, without merging, and long lists reach 100 elements. test_builtin still passes all 28 items.

## 3. Seeded bugs (test_seeded_bugs; all in expect_fail)

- **sort.permutation:** `sorted(set(xs))`.
  - xs = [0, 0] gives [0].
  - `sort.ordered`, `#type` and `#raises` pass.
  - Checked by `test_dedup_sort_drops_duplicates`.
- **sort_by_first.stable:** `sorted(xs, key=first, reverse=True)[::-1]`. A stable descending sort keeps the input order of equal keys, so reversing it orders the keys correctly and reverses each group of equal keys.
  - xs = [(0, "0"), (0, "")] gives [(0, ""), (0, "0")].
  - `permutation` and `ordered` pass.
  - Checked by `test_reversed_ties_sort_reverses_equal_keys`.
- **sort_in_place.ordered:** the bug sorts a copy and drops it.
  - xs = MutableList { items: [0, -1] } is left as it was.
  - Earlier runs showed -2 rather than -1: negative i64 values shrank to -2 (the runtime entry of docs/ISSUES.md).
  - Checked by `test_sort_a_copy_leaves_the_list_unchanged`.

  **Does sort_in_place.permutation pass, and why?** Yes, on all 100 examples. `is_permutation(xs.items, old(xs.items))` holds when nothing changes, because a list is a permutation of itself.
  - Only `ordered` sees the bug, and only on an unsorted input.
  - The `modifies xs` item (`sort_in_place#1`) also passes: `modifies` allows a change but does not require one, and with xs listed it has nothing to compare.
  - `#type` and `#raises` pass too.
  - The spec is still complete: `ordered` and `permutation` together allow only the sorted permutation of the old items, so every wrong result breaks one of them.

## 4. Explore: which order does Ord mean on strings?

`explore_sorting.py::test_explore_utf16_order` binds `sort` to a sort by UTF-16 code units, the string comparison of Java and JavaScript.
- It fails `sort.ordered[T=string]` on xs = ["𐀀", "\u{e000}"], after 1,403 passing examples.
- U+E000 comes before U+10000 by code point, but U+10000's high surrogate 0xD800 sorts before 0xE000.
- The prelude compares code points, which is also UTF-8 byte order.
- docs/language.md does not say which order `Ord` means on strings, bytes, bools or tuples (docs/ISSUES.md).

## 5. Static rules (plain tests)

- `test_conformance_rejects_f64_for_an_ord_parameter`: `spectest.conformance(spec, impls={"sort": sorted}, instantiate={"T": "f64"})` raises ConformanceError with exactly one problem: "instantiate: T = f64 has no total order, as sort<T: Ord> needs".
- `test_checker_rejects_equality_on_lists_of_floats`: a spec with `ensures same_list: result == xs` on `list<f64>` fails to load. The error is at float_sort.spec:4:22: "== is not defined on f64 (inside list<f64>): floats have no implicit equality. Use same(a, b) for bit-identical values, ieee_eq(a, b) for IEEE 754 equality, real(a) == real(b) to compare numerically, or eq(a, b, float=...) for collections".
