# spectest report: frames

- **Spec:** `frames` (`examples/frames/frames.spec`)
- **Spec hash:** `17db88635b51b10e9480caaaf4c2b5157d9e5a2325db9630fdf243d6a22e5410`
- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9
- **Platform:** CPython 3.13.9, Linux 6.18.54.1-microsoft-standard-WSL2, x86_64
- **Packages:** numpy 2.5.4, pandas 3.1.0, polars 2.1.0, gmpy2 2.3.2
- **Items:** 81: 75 passed, 6 expected failures
- **Clause results:** 81: 75 passed, 6 expected failures

## Results

| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive | Time |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/frames/test_frames.py::test_pandas::dropna.columns` | `dropna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.08s |
| `examples/frames/test_frames.py::test_pandas::dropna.rows` | `dropna.rows` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.12s |
| `examples/frames/test_frames.py::test_pandas::dropna.fresh` | `dropna.fresh` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.95s |
| `examples/frames/test_frames.py::test_pandas::dropna#type` | `dropna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.21s |
| `examples/frames/test_frames.py::test_pandas::dropna#raises` | `dropna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.01s |
| `examples/frames/test_frames.py::test_pandas::dropna#frame` | `dropna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.17s |
| `examples/frames/test_frames.py::test_pandas::dropna:Frame.unique_columns` | `dropna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.91s |
| `examples/frames/test_frames.py::test_pandas::dropna:Frame.rectangular` | `dropna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.99s |
| `examples/frames/test_frames.py::test_pandas::dropna:Frame.row_count` | `dropna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.86s |
| `examples/frames/test_frames.py::test_pandas::fillna.columns` | `fillna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.93s |
| `examples/frames/test_frames.py::test_pandas::fillna.rows` | `fillna.rows` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.09s |
| `examples/frames/test_frames.py::test_pandas::fillna.fresh` | `fillna.fresh` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.82s |
| `examples/frames/test_frames.py::test_pandas::fillna#type` | `fillna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.18s |
| `examples/frames/test_frames.py::test_pandas::fillna#raises` | `fillna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.94s |
| `examples/frames/test_frames.py::test_pandas::fillna#frame` | `fillna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.02s |
| `examples/frames/test_frames.py::test_pandas::fillna:Frame.unique_columns` | `fillna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.36s |
| `examples/frames/test_frames.py::test_pandas::fillna:Frame.rectangular` | `fillna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.04s |
| `examples/frames/test_frames.py::test_pandas::fillna:Frame.row_count` | `fillna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.12s |
| `examples/frames/test_frames.py::test_pandas::select#2` | `select#2` | raises | hypothesis | pass | 102 | 0 | 0 | 0 | 0 | 1.16s |
| `examples/frames/test_frames.py::test_pandas::select.columns` | `select.columns` | ensures | hypothesis | pass | 63 | 0 | 39 (raised) | 0 | 0 | 1.05s |
| `examples/frames/test_frames.py::test_pandas::select.rows` | `select.rows` | ensures | hypothesis | pass | 67 | 0 | 35 (raised) | 0 | 0 | 0.87s |
| `examples/frames/test_frames.py::test_pandas::select#type` | `select#type` | type | hypothesis | pass | 60 | 0 | 42 (raised) | 0 | 0 | 1.37s |
| `examples/frames/test_frames.py::test_pandas::select#raises` | `select#raises` | raises | hypothesis | pass | 102 | 0 | 0 | 0 | 0 | 1.01s |
| `examples/frames/test_frames.py::test_pandas::select#frame` | `select#frame` | frame | hypothesis | pass | 102 | 0 | 0 | 0 | 0 | 1.15s |
| `examples/frames/test_frames.py::test_pandas::select:Frame.unique_columns` | `select:Frame.unique_columns` | invariant | hypothesis | pass | 63 | 0 | 39 (other) | 0 | 0 | 1.41s |
| `examples/frames/test_frames.py::test_pandas::select:Frame.rectangular` | `select:Frame.rectangular` | invariant | hypothesis | pass | 50 | 0 | 52 (other) | 0 | 0 | 1.44s |
| `examples/frames/test_frames.py::test_pandas::select:Frame.row_count` | `select:Frame.row_count` | invariant | hypothesis | pass | 63 | 0 | 39 (other) | 0 | 0 | 1.08s |
| `examples/frames/test_frames.py::test_polars::dropna.columns` | `dropna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.85s |
| `examples/frames/test_frames.py::test_polars::dropna.rows` | `dropna.rows` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.04s |
| `examples/frames/test_frames.py::test_polars::dropna.fresh` | `dropna.fresh` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.05s |
| `examples/frames/test_frames.py::test_polars::dropna#type` | `dropna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.17s |
| `examples/frames/test_frames.py::test_polars::dropna#raises` | `dropna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.00s |
| `examples/frames/test_frames.py::test_polars::dropna#frame` | `dropna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.21s |
| `examples/frames/test_frames.py::test_polars::dropna:Frame.unique_columns` | `dropna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.04s |
| `examples/frames/test_frames.py::test_polars::dropna:Frame.rectangular` | `dropna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.99s |
| `examples/frames/test_frames.py::test_polars::dropna:Frame.row_count` | `dropna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.81s |
| `examples/frames/test_frames.py::test_polars::fillna.columns` | `fillna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.22s |
| `examples/frames/test_frames.py::test_polars::fillna.rows` | `fillna.rows` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.13s |
| `examples/frames/test_frames.py::test_polars::fillna.fresh` | `fillna.fresh` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.75s |
| `examples/frames/test_frames.py::test_polars::fillna#type` | `fillna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.06s |
| `examples/frames/test_frames.py::test_polars::fillna#raises` | `fillna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.06s |
| `examples/frames/test_frames.py::test_polars::fillna#frame` | `fillna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.05s |
| `examples/frames/test_frames.py::test_polars::fillna:Frame.unique_columns` | `fillna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.79s |
| `examples/frames/test_frames.py::test_polars::fillna:Frame.rectangular` | `fillna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.83s |
| `examples/frames/test_frames.py::test_polars::fillna:Frame.row_count` | `fillna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.92s |
| `examples/frames/test_frames.py::test_polars::select#2` | `select#2` | raises | hypothesis | expected fail | 0 | 1 | 0 | 0 | 0 | 0.01s |
| `examples/frames/test_frames.py::test_polars::select.columns` | `select.columns` | ensures | hypothesis | expected fail | 0 | 1 | 0 | 0 | 0 | 0.01s |
| `examples/frames/test_frames.py::test_polars::select.rows` | `select.rows` | ensures | hypothesis | expected fail | 5 | 1 | 2 (raised) | 0 | 0 | 0.05s |
| `examples/frames/test_frames.py::test_polars::select#type` | `select#type` | type | hypothesis | pass | 74 | 0 | 28 (raised) | 0 | 0 | 1.42s |
| `examples/frames/test_frames.py::test_polars::select#raises` | `select#raises` | raises | hypothesis | pass | 102 | 0 | 0 | 0 | 0 | 1.18s |
| `examples/frames/test_frames.py::test_polars::select#frame` | `select#frame` | frame | hypothesis | pass | 102 | 0 | 0 | 0 | 0 | 0.98s |
| `examples/frames/test_frames.py::test_polars::select:Frame.unique_columns` | `select:Frame.unique_columns` | invariant | hypothesis | pass | 58 | 0 | 44 (other) | 0 | 0 | 1.19s |
| `examples/frames/test_frames.py::test_polars::select:Frame.rectangular` | `select:Frame.rectangular` | invariant | hypothesis | pass | 62 | 0 | 40 (other) | 0 | 0 | 0.98s |
| `examples/frames/test_frames.py::test_polars::select:Frame.row_count` | `select:Frame.row_count` | invariant | hypothesis | pass | 60 | 0 | 42 (other) | 0 | 0 | 1.08s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna.columns` | `dropna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.16s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna.rows` | `dropna.rows` | ensures | hypothesis | expected fail | 17 | 1 | 0 | 0 | 0 | 1.38s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna.fresh` | `dropna.fresh` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.03s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna#type` | `dropna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.21s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna#raises` | `dropna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.05s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna#frame` | `dropna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.39s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna:Frame.unique_columns` | `dropna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.85s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna:Frame.rectangular` | `dropna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.09s |
| `examples/frames/test_frames.py::test_seeded_bugs::dropna:Frame.row_count` | `dropna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.92s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna.columns` | `fillna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.24s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna.rows` | `fillna.rows` | ensures | hypothesis | expected fail | 42 | 1 | 0 | 0 | 0 | 3.00s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna.fresh` | `fillna.fresh` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.05s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna#type` | `fillna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.74s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna#raises` | `fillna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.93s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna#frame` | `fillna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.17s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna:Frame.unique_columns` | `fillna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.88s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna:Frame.rectangular` | `fillna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.26s |
| `examples/frames/test_frames.py::test_seeded_bugs::fillna:Frame.row_count` | `fillna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.99s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna.columns` | `dropna.columns` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.03s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna.rows` | `dropna.rows` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.20s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna.fresh` | `dropna.fresh` | ensures | hypothesis | expected fail | 0 | 1 | 0 | 0 | 0 | 0.02s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna#type` | `dropna#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.79s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna#raises` | `dropna#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.08s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna#frame` | `dropna#frame` | frame | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.76s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna:Frame.unique_columns` | `dropna:Frame.unique_columns` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.19s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna:Frame.rectangular` | `dropna:Frame.rectangular` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 1.02s |
| `examples/frames/test_frames.py::test_seeded_fresh::dropna:Frame.row_count` | `dropna:Frame.row_count` | invariant | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.88s |

Skips by cause: raised: the call raised; other: another reason.

## Counterexamples

### `test_polars::select#2` (expected failure)

```text
select#2 (raises) failed as expected (expect_fail)
  raises ColumnNotFound when exists(n in names: not (n in df.columns))
  in select

inputs:
  df = Frame { columns: ["b", "bc"], rows: [[some(2.0), some(3.0)]], nrows: 1 }
  names = ["*"]
observed:
  result = Frame { columns: ["b", "bc"], rows: [[some(2.0), some(3.0)]], nrows: 1 }
  ColumnNotFound was due (exists(n in names: not (n in df.columns)) holds), but the call returned
  (an explicit example of the conformance (examples=))
explanation:
  raises ColumnNotFound when exists(n in names: not (n in df.columns)) = true
  errors that must be raised (R) = {ColumnNotFound}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/frames/test_frames.py::test_polars::select#2' --spectest-seed=0
```

### `test_polars::select.columns` (expected failure)

```text
select.columns (ensures) failed as expected (expect_fail)
  ensures columns: result.columns == names
  in select

inputs:
  df = Frame { columns: ["b", "bc"], rows: [[some(2.0), some(3.0)]], nrows: 1 }
  names = ["*"]
observed:
  result = Frame { columns: ["b", "bc"], rows: [[some(2.0), some(3.0)]], nrows: 1 }
  note: select#2 required ColumnNotFound on this input
  (an explicit example of the conformance (examples=))
explanation:
  result.columns = ["b", "bc"]
  names = ["*"]
verdicts: 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/frames/test_frames.py::test_polars::select.columns' --spectest-seed=0
```

### `test_polars::select.rows` (expected failure)

```text
select.rows (ensures) failed as expected (expect_fail)
  ensures rows: all(n in names: n in df.columns) implies eq(result.rows, map(r in df.rows: map(n in names: r[index_of(df.columns, n)])), float="bits")
  in select

inputs:
  df = Frame { columns: [], rows: [[]], nrows: 1 }
  names = []
observed:
  result = Frame { columns: [], rows: [], nrows: 0 }
explanation:
  result.rows = []
  map(r in df.rows: map(n in names: r[index_of(df.columns, n)])) = [[]]
  eq(result.rows, map(r in df.rows: map(n in names: r[index_of(df.columns, n)])), float="bits") = false
verdicts: 5 pass, 1 fail, 2 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/frames/test_frames.py::test_polars::select.rows' --spectest-seed=0
```

### `test_seeded_bugs::dropna.rows` (expected failure)

```text
dropna.rows (ensures) failed as expected (expect_fail)
  ensures rows: eq(result.rows, filter(r in df.rows: if how == "any" then all(c in r: is_some(c)) else exists(c in r: is_some(c))), float="bits")
  in dropna

inputs:
  df = Frame { columns: [], rows: [[]], nrows: 1 }
  how = "all"
observed:
  result = Frame { columns: [], rows: [[]], nrows: 1 }
explanation:
  result.rows = [[]]
  filter(r in df.rows: if how == "any" then all(c in r: is_some(c)) else exists(c in r: is_some(c))) = []
  eq(result.rows, filter(r in df.rows: if how == "any" then all(c in r: is_some(c)) else exists(c in r: is_some(c))), float="bits") = false
verdicts: 17 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/frames/test_frames.py::test_seeded_bugs::dropna.rows' --spectest-seed=0
```

### `test_seeded_bugs::fillna.rows` (expected failure)

```text
fillna.rows (ensures) failed as expected (expect_fail)
  ensures rows: eq(result.rows, map(r in df.rows: map(c in r: if is_none(c) then some(value) else c)), float="bits")
  in fillna

inputs:
  df = Frame { columns: [""], rows: [[some(nan)]], nrows: 1 }
  value = 0.0 (0x0000000000000000)
observed:
  result = Frame { columns: [""], rows: [[some(0.0)]], nrows: 1 }
explanation:
  result.rows = [[some(0.0)]]
  map(r in df.rows: map(c in r: if is_none(c) then some(value) else c)) = [[some(nan)]]
  eq(result.rows, map(r in df.rows: map(c in r: if is_none(c) then some(value) else c)), float="bits") = false
verdicts: 42 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/frames/test_frames.py::test_seeded_bugs::fillna.rows' --spectest-seed=0
```

### `test_seeded_fresh::dropna.fresh` (expected failure)

```text
dropna.fresh (ensures) failed as expected (expect_fail)
  ensures fresh: fresh(result)
  in dropna

inputs:
  df = Frame { columns: [], rows: [], nrows: 0 }
  how = default ("any")
observed:
  result = Frame { columns: [], rows: [], nrows: 0 }
explanation:
  result = <Frame #3335>
  fresh(result) = false
verdicts: 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/frames/test_frames.py::test_seeded_fresh::dropna.fresh' --spectest-seed=0
```
