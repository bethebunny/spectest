# sorting

`sorting.spec` specifies three functions:
- a value-to-value `sort<T: Ord>`;
- a stable `sort_by_first<K: Ord, V: Eq>` over pairs;
- an in-place `sort_in_place<T: Ord>` on a `MutableList<T>` model, with `modifies` and `old()`.

The case exercises:
- generic declarations with bounds, including the checks that reject unordered instantiations such as `T = f64`;
- comprehensions (`filter`, `map` and `all` in the stability clause);
- predicate partitions of a list (empty, single, unique, duplicates);
- one mutable model bound to two different Python types.

## Files

- `sorting.spec`: the requirement.
- `sorting_impls.py`:
  - numpy adapters;
  - the `MutableList` bindings for Python lists and int64 arrays;
  - the seeded bugs;
  - a probe of numpy's default argsort.
- `test_sorting.py`: four conformances, and plain tests that check FINDINGS.md without spectest.
- `explore_sorting.py`: questions outside the default run. It does not match `test_*.py`, so pytest collects it only when named.
- `REPORT.md`: written by the report command below.
- `FINDINGS.md`: what the runs found, with independent checks.

## Conformances

| Conformance | Binds | Instantiations | Expected |
| --- | --- | --- | --- |
| `test_builtin` | `sorted`; `sorted(key=itemgetter(0))`; `list.sort` on Python lists | T = i64, string; (K, V) = (i64, string), (string, i64) | all 28 items pass |
| `test_numpy` | `np.sort` on int64 arrays; pairs reordered by `np.argsort(keys, kind="stable")`; `ndarray.sort` on int64 arrays | T = i64; (K, V) = (i64, string) | all 14 items pass |
| `test_numpy_default_kind` | pairs reordered by `np.argsort(keys)` (the default kind) | (K, V) = (i64, string) | `sort_by_first.stable` fails: numpy's SIMD sort (x86-64 with AVX2) reorders equal keys from 4 elements on, and its portable sort from 17, which spectest's long lists reach; the other 4 items pass |
| `test_seeded_bugs` | `sorted(set(xs))`; a reversed descending sort; a sort of a copy | T = i64; (K, V) = (i64, string) | `sort.permutation`, `sort_by_first.stable` and `sort_in_place.ordered` fail; the other 11 items pass |

## Running

```
uv run pytest examples/sorting
uv run pytest examples/sorting --spectest-report=examples/sorting/REPORT.md
```

On x86-64 with AVX2, expect `65 passed, 4 xfailed` in about 80 s.

Where numpy's default argsort is stable on short arrays:
- `test_numpy_default_kind::sort_by_first[K=i64,V=string].stable` is still an expected failure, on a list of 17 pairs;
- `test_numpy_default_argsort_is_unstable_on_short_arrays` is skipped;
- expect `64 passed, 4 xfailed, 1 skipped`.

`test_numpy_portable_argsort_is_stable_on_short_arrays` runs on x86-64 only. It sets `NPY_DISABLE_CPU_FEATURES` itself, and fails when the whole run already has it set.

Failing items store their counterexamples under `.spectest/`. A rerun replays them first, so the report's counts for the expected failures then come from that one replay. Delete `.spectest/counterexamples/<hash of sorting.spec>` to search afresh.

## Explore

```
uv run pytest examples/sorting/explore_sorting.py -s
NPY_DISABLE_CPU_FEATURES=X86_V3 uv run pytest examples/sorting/explore_sorting.py -s
```

On x86-64 with AVX2, the first command gives 2 failures, which are answers rather than bugs:
- `test_explore_default_kind::sort_by_first[K=i64,V=string].stable` fails on a 4-element list. This conformance turns long lists off (`sizes=Sizes(long_share=0)`), so its lists have at most 8 elements.
- `test_explore_utf16_order::sort[T=string].ordered` fails on `["𐀀", "\u{e000}"]`, after about 3,000 passing examples. Ord on strings is code-point order, which UTF-16 code-unit order is not.
- `test_longer_lists_expose_the_default_kind` passes and prints the minimized counterexample of a conformance with lists of up to 40 elements: 5 pairs.

With `NPY_DISABLE_CPU_FEATURES=X86_V3`, numpy uses its portable sort:
- the default-kind items all pass at 2,000 examples, because lists of at most 8 elements cannot expose it;
- the longer-lists test's counterexample has 17 pairs;
- the UTF-16 conformance fails as above.

Each command takes about 60 to 110 s.
