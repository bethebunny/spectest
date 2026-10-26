# spectest report: sorting

- **Spec:** `sorting` (`/home/stef/spectest/examples/sorting/sorting.spec`)
- **Spec hash:** `b67cc966000c3aee48a078fccaabc27b2ca52a631f71f75057bc6e6caa7ce6e2`
- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9
- **Platform:** CPython 3.13.9, Linux 6.18.54.1-microsoft-standard-WSL2, x86_64
- **Packages:** numpy 2.5.4, gmpy2 2.3.2
- **Items:** 61: 57 passed, 4 expected failures
- **Clause results:** 61: 57 passed, 4 expected failures

## Results

| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive | Time |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=i64].permutation` | `sort[T=i64].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.16s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=i64].ordered` | `sort[T=i64].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.95s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=i64]#type` | `sort[T=i64]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.12s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=i64]#raises` | `sort[T=i64]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.06s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=string].permutation` | `sort[T=string].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.68s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=string].ordered` | `sort[T=string].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.44s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=string]#type` | `sort[T=string]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.16s |
| `examples/sorting/test_sorting.py::test_builtin::sort[T=string]#raises` | `sort[T=string]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.38s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=i64,V=string].permutation` | `sort_by_first[K=i64,V=string].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.05s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=i64,V=string].ordered` | `sort_by_first[K=i64,V=string].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.41s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=i64,V=string].stable` | `sort_by_first[K=i64,V=string].stable` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 4.41s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=i64,V=string]#type` | `sort_by_first[K=i64,V=string]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.67s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=i64,V=string]#raises` | `sort_by_first[K=i64,V=string]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.93s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=string,V=i64].permutation` | `sort_by_first[K=string,V=i64].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.66s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=string,V=i64].ordered` | `sort_by_first[K=string,V=i64].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.45s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=string,V=i64].stable` | `sort_by_first[K=string,V=i64].stable` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.21s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=string,V=i64]#type` | `sort_by_first[K=string,V=i64]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.56s |
| `examples/sorting/test_sorting.py::test_builtin::sort_by_first[K=string,V=i64]#raises` | `sort_by_first[K=string,V=i64]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.75s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=i64]#1` | `sort_in_place[T=i64]#1` | modifies | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.52s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=i64].permutation` | `sort_in_place[T=i64].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.40s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=i64].ordered` | `sort_in_place[T=i64].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.47s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=i64]#type` | `sort_in_place[T=i64]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.20s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=i64]#raises` | `sort_in_place[T=i64]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.45s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=string]#1` | `sort_in_place[T=string]#1` | modifies | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.91s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=string].permutation` | `sort_in_place[T=string].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.09s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=string].ordered` | `sort_in_place[T=string].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 1.97s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=string]#type` | `sort_in_place[T=string]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.05s |
| `examples/sorting/test_sorting.py::test_builtin::sort_in_place[T=string]#raises` | `sort_in_place[T=string]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.06s |
| `examples/sorting/test_sorting.py::test_numpy::sort[T=i64].permutation` | `sort[T=i64].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.80s |
| `examples/sorting/test_sorting.py::test_numpy::sort[T=i64].ordered` | `sort[T=i64].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.13s |
| `examples/sorting/test_sorting.py::test_numpy::sort[T=i64]#type` | `sort[T=i64]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.17s |
| `examples/sorting/test_sorting.py::test_numpy::sort[T=i64]#raises` | `sort[T=i64]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.14s |
| `examples/sorting/test_sorting.py::test_numpy::sort_by_first[K=i64,V=string].permutation` | `sort_by_first[K=i64,V=string].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.68s |
| `examples/sorting/test_sorting.py::test_numpy::sort_by_first[K=i64,V=string].ordered` | `sort_by_first[K=i64,V=string].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.67s |
| `examples/sorting/test_sorting.py::test_numpy::sort_by_first[K=i64,V=string].stable` | `sort_by_first[K=i64,V=string].stable` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 3.49s |
| `examples/sorting/test_sorting.py::test_numpy::sort_by_first[K=i64,V=string]#type` | `sort_by_first[K=i64,V=string]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.59s |
| `examples/sorting/test_sorting.py::test_numpy::sort_by_first[K=i64,V=string]#raises` | `sort_by_first[K=i64,V=string]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.66s |
| `examples/sorting/test_sorting.py::test_numpy::sort_in_place[T=i64]#1` | `sort_in_place[T=i64]#1` | modifies | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.46s |
| `examples/sorting/test_sorting.py::test_numpy::sort_in_place[T=i64].permutation` | `sort_in_place[T=i64].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.50s |
| `examples/sorting/test_sorting.py::test_numpy::sort_in_place[T=i64].ordered` | `sort_in_place[T=i64].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.50s |
| `examples/sorting/test_sorting.py::test_numpy::sort_in_place[T=i64]#type` | `sort_in_place[T=i64]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.47s |
| `examples/sorting/test_sorting.py::test_numpy::sort_in_place[T=i64]#raises` | `sort_in_place[T=i64]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.44s |
| `examples/sorting/test_sorting.py::test_numpy_default_kind::sort_by_first[K=i64,V=string].permutation` | `sort_by_first[K=i64,V=string].permutation` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.77s |
| `examples/sorting/test_sorting.py::test_numpy_default_kind::sort_by_first[K=i64,V=string].ordered` | `sort_by_first[K=i64,V=string].ordered` | ensures | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.75s |
| `examples/sorting/test_sorting.py::test_numpy_default_kind::sort_by_first[K=i64,V=string].stable` | `sort_by_first[K=i64,V=string].stable` | ensures | hypothesis | expected fail | 53 | 1 | 0 | 0 | 0 | 1.29s |
| `examples/sorting/test_sorting.py::test_numpy_default_kind::sort_by_first[K=i64,V=string]#type` | `sort_by_first[K=i64,V=string]#type` | type | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.65s |
| `examples/sorting/test_sorting.py::test_numpy_default_kind::sort_by_first[K=i64,V=string]#raises` | `sort_by_first[K=i64,V=string]#raises` | raises | hypothesis | pass | 500 | 0 | 0 | 0 | 0 | 2.76s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort[T=i64].permutation` | `sort[T=i64].permutation` | ensures | hypothesis | expected fail | 3 | 1 | 0 | 0 | 0 | 0.52s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort[T=i64].ordered` | `sort[T=i64].ordered` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.62s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort[T=i64]#type` | `sort[T=i64]#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.50s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort[T=i64]#raises` | `sort[T=i64]#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.64s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_by_first[K=i64,V=string].permutation` | `sort_by_first[K=i64,V=string].permutation` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.52s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_by_first[K=i64,V=string].ordered` | `sort_by_first[K=i64,V=string].ordered` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.28s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_by_first[K=i64,V=string].stable` | `sort_by_first[K=i64,V=string].stable` | ensures | hypothesis | expected fail | 11 | 1 | 0 | 0 | 0 | 0.28s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_by_first[K=i64,V=string]#type` | `sort_by_first[K=i64,V=string]#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.60s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_by_first[K=i64,V=string]#raises` | `sort_by_first[K=i64,V=string]#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.56s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_in_place[T=i64]#1` | `sort_in_place[T=i64]#1` | modifies | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.46s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_in_place[T=i64].permutation` | `sort_in_place[T=i64].permutation` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.49s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_in_place[T=i64].ordered` | `sort_in_place[T=i64].ordered` | ensures | hypothesis | expected fail | 2 | 1 | 0 | 0 | 0 | 0.24s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_in_place[T=i64]#type` | `sort_in_place[T=i64]#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.41s |
| `examples/sorting/test_sorting.py::test_seeded_bugs::sort_in_place[T=i64]#raises` | `sort_in_place[T=i64]#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.43s |

## Coverage

Examples each clause judged (pass or fail), per partition class; a class with 0 examples was never exercised by that clause.

### `sort` with T=i64

| Clause | xs: empty | xs: single | xs: unique | xs: duplicates |
| --- | ---: | ---: | ---: | ---: |
| `test_builtin::sort[T=i64].permutation` | 2 | 60 | 123 | 315 |
| `test_builtin::sort[T=i64].ordered` | 2 | 57 | 130 | 311 |
| `test_builtin::sort[T=i64]#type` | 2 | 54 | 153 | 291 |
| `test_builtin::sort[T=i64]#raises` | 2 | 49 | 149 | 300 |
| `test_numpy::sort[T=i64].permutation` | 2 | 63 | 134 | 301 |
| `test_numpy::sort[T=i64].ordered` | 2 | 64 | 154 | 280 |
| `test_numpy::sort[T=i64]#type` | 2 | 58 | 141 | 299 |
| `test_numpy::sort[T=i64]#raises` | 2 | 61 | 119 | 318 |
| `test_seeded_bugs::sort[T=i64].permutation` | 2 | 1 | **0** | 1 |
| `test_seeded_bugs::sort[T=i64].ordered` | 2 | 13 | 20 | 65 |
| `test_seeded_bugs::sort[T=i64]#type` | 2 | 21 | 27 | 50 |
| `test_seeded_bugs::sort[T=i64]#raises` | 2 | 11 | 30 | 57 |

### `sort` with T=string

| Clause | xs: empty | xs: single | xs: unique | xs: duplicates |
| --- | ---: | ---: | ---: | ---: |
| `test_builtin::sort[T=string].permutation` | 2 | 51 | 133 | 314 |
| `test_builtin::sort[T=string].ordered` | 2 | 54 | 129 | 315 |
| `test_builtin::sort[T=string]#type` | 2 | 66 | 120 | 312 |
| `test_builtin::sort[T=string]#raises` | 2 | 49 | 138 | 311 |

## Counterexamples

### `test_numpy_default_kind::sort_by_first[K=i64,V=string].stable` (expected failure)

```text
sort_by_first[K=i64,V=string].stable (ensures) failed as expected (expect_fail)
  ensures stable: all(p in xs: filter(q in result: q.0 == p.0) == filter(q in xs: q.0 == p.0))
  in sort_by_first with K=i64, V=string

inputs:
  xs = [(0, ""), (0, ""), (0, "0"), (0, ""), (-1, "")]
observed:
  result = [(-1, ""), (0, ""), (0, "0"), (0, ""), (0, "")]
explanation:
  p = (0, "")
  filter(q in result: q.0 == p.0) = [(0, ""), (0, "0"), (0, ""), (0, "")]
  filter(q in xs: q.0 == p.0) = [(0, ""), (0, ""), (0, "0"), (0, "")]
verdicts: 53 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/sorting/test_sorting.py::test_numpy_default_kind::sort_by_first[K=i64,V=string].stable' --spectest-seed=0
```

### `test_seeded_bugs::sort[T=i64].permutation` (expected failure)

```text
sort[T=i64].permutation (ensures) failed as expected (expect_fail)
  ensures permutation: is_permutation(result, xs)
  in sort with T=i64

inputs:
  xs = [0, 0]
observed:
  result = [0]
partitions:
  xs: duplicates
explanation:
  result = [0]
  xs = [0, 0]
  is_permutation(result, xs) = false
verdicts: 3 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/sorting/test_sorting.py::test_seeded_bugs::sort[T=i64].permutation' --spectest-seed=0
```

### `test_seeded_bugs::sort_by_first[K=i64,V=string].stable` (expected failure)

```text
sort_by_first[K=i64,V=string].stable (ensures) failed as expected (expect_fail)
  ensures stable: all(p in xs: filter(q in result: q.0 == p.0) == filter(q in xs: q.0 == p.0))
  in sort_by_first with K=i64, V=string

inputs:
  xs = [(0, "0"), (0, "")]
observed:
  result = [(0, ""), (0, "0")]
explanation:
  p = (0, "0")
  filter(q in result: q.0 == p.0) = [(0, ""), (0, "0")]
  filter(q in xs: q.0 == p.0) = [(0, "0"), (0, "")]
verdicts: 11 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/sorting/test_sorting.py::test_seeded_bugs::sort_by_first[K=i64,V=string].stable' --spectest-seed=0
```

### `test_seeded_bugs::sort_in_place[T=i64].ordered` (expected failure)

```text
sort_in_place[T=i64].ordered (ensures) failed as expected (expect_fail)
  ensures ordered: is_sorted(xs.items)
  in sort_in_place with T=i64

inputs:
  xs = MutableList { items: [0, -1] }
observed:
  xs after = MutableList { items: [0, -1] } (unchanged)
explanation:
  xs.items = [0, -1]
  is_sorted(xs.items) = false
verdicts: 2 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/sorting/test_sorting.py::test_seeded_bugs::sort_in_place[T=i64].ordered' --spectest-seed=0
```
