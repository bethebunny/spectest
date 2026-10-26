# frames findings

What spectest found when it ran frames.spec against pandas and polars, and what the three seeded bugs produced. Each finding gives the clause, the counterexample, an independent check, and why it violates the spec. The plain test functions at the end of examples/frames/test_frames.py use pandas and polars directly, without spectest, and assert what is stated here.

Environment: Python 3.13.9, pandas 3.1.0 (numpy-backed, no pyarrow), polars 2.1.0, numpy 2.5.4, Hypothesis 6.170.9, x86-64 Linux.

## 1. polars select of no columns drops every row (select.rows, test_polars)

**Counterexample.**
- Input: df = Frame { columns: [], rows: [[]], nrows: 1 }, names = [].
- `df.select([])` returned Frame { columns: [], rows: [], nrows: 0 }.
- `select.rows` demands one empty row per input row: `map(r in df.rows: map(n in names: ...))` is `[[]]`.
- An earlier run found the same with a column: df = Frame { columns: [""], rows: [[none]], nrows: 1 }, names = []. That run was before the binding could build frames with rows but no columns.

**Why it is a violation.** Choosing columns does not choose rows. The spec's model keeps the row count, and so does pandas: `df[[]]` keeps the index, giving shape (n, 0). polars can hold the expected result:
- `pl.DataFrame(height=1)` has shape (1, 0).
- `df.drop(<last column>)` keeps the height.
- `drop_nulls`, `fill_null` and a how="all" filter all keep or drop such rows as the spec says.

Only `select` with no expressions resets the height to 0.

**Independent check.** `test_polars_select_of_no_columns_drops_every_row` and `test_polars_frames_without_columns_keep_their_rows_elsewhere`.

**Decision.** A real difference, not a harness bug.
- `select.rows` is in test_polars' expect_fail. Every other polars clause passes, apart from the two of finding 2.
- Selecting through `polars.selectors.by_name(*names)` would not help: with no names it also returns a 0 x 0 frame.

## 2. polars select reads names as patterns (select#2, select.columns, test_polars; explicit examples)

`df.select(names)` takes expressions, so each string is parsed as a column expression. `*` means every column, and a name of the form `^...$` is a regular expression. As a result:
- **select#2 fails:** columns ["b", "bc"] with names ["*"] or ["^b.*$"] returns both columns where ColumnNotFound is due.
- **select.columns fails** on the same input: the result's columns are ["b", "bc"], not the names. The counterexample adds `note: select#2 required ColumnNotFound on this input`.
- A frame with a column that is itself named `*` fails too: columns ["*", "b"] with names ["*"] gives columns ["*", "b"], not ["*"]. That breaks select.rows as well, so it is not an explicit example: it would replace select.rows' own counterexample (finding 1).

pandas' `df[names]` reads the same names literally. So does `polars.selectors.by_name`, which also raises ColumnNotFoundError for a missing name.

**How spectest finds it.** The generator does not reach these inputs: in 3,000 draws of select's arguments, `*` appeared in names 5 times and a `^...$` name never, and no run with up to 2,000 examples per item produced a failing one. So test_frames.py gives both conformances the two inputs as explicit examples (`conformance(examples=PATTERN_NAMES)`). They are judged on every select item before the search:
- test_polars fails select#2 and select.columns on names = ["*"], and both are in its expect_fail.
- test_pandas passes them: pandas raises KeyError, mapped to ColumnNotFound.

`test_polars_select_reads_names_as_patterns` checks the behaviour with polars and pandas directly, including the column named `*`.

## 3. Seeded bugs (test_seeded_bugs, test_seeded_fresh; all in expect_fail)

Each bug fails only its intended clause. Every other item of its conformance passes.

- **dropna.rows** (`dropna_ignores_how`, always `drop_nulls()`):
  - Counterexample: df = Frame { columns: [], rows: [[]], nrows: 1 }, how = "all".
  - how="all" drops the row without cells, because no cell has a value; the bug keeps it, because no cell is null.
  - A row with a value and a null fails too: how="all" keeps it and the bug drops it. Earlier runs stopped there, at 3 columns (Frame { columns: ["", "0", "00"], rows: [[none, none, some(0.0)]], nrows: 1 }): rows are drawn to the column count, so a column can go only with its cell in every row, which Hypothesis's shrinker never tries. spectest's own pass after it removes columns with their cells, and here all of them at once.
  - Checked by `test_seeded_dropna_ignores_how`.
- **fillna.rows** (`fillna_fills_nan`, `fill_nan(value).fill_null(value)`):
  - Counterexample: df = Frame { columns: [""], rows: [[some(nan)]], nrows: 1 }, value = 0.0.
  - Result: [[some(0.0)]]. The spec keeps some(nan).
  - In pandas NaN is the missing marker, so filling it is right. In polars NaN is a value, and the model's split between none and some(NaN) is what catches the bug.
  - Earlier runs stopped at 4 columns, [[none, none, some(0.0), some(nan)]], for the reason above.
  - Checked by `test_seeded_fillna_overwrites_nan`.
- **dropna.fresh** (`dropna_returns_input`, returns its input when no row is dropped):
  - Counterexample: df = Frame { columns: [], rows: [], nrows: 0 }, how = default ("any"). The result is the input object.
  - Checked by `test_seeded_dropna_returns_its_input`.
  - The first version of this bug skipped the copy whenever the frame had no null. spectest showed that also broke dropna.rows on Frame { columns: [], rows: [[]], nrows: 1 } with how = "all": that row has no null, yet how="all" drops it, because an `exists` over no cells is false. The shortcut is now "no row dropped".

## 4. Binding notes

- **Empty column names.** `pl.DataFrame([pl.Series("", ...)])` renames the column to "column_0". The first seeded run showed it: the counterexample printed the generated input with columns ["", ...] next to a result with columns ["column_0", ...]. The binding now builds from a dict, which keeps "". spectest now reads every concretized frame back and reports a binding error if it differs from the generated fields (the bindings' own read-back check is gone), and tests/runtime/test_runtime_binding.py shows that the list-of-Series concretizer is caught. Checked by `test_polars_frame_from_a_list_of_series_renames_an_empty_name`.
- **pandas has no separate null for float64.** The concretizer writes none and some(NaN) as NaN, and every NaN reads back as none. pandas is therefore never handed a NaN value, only missing cells, and the binding declares itself `lossy=True`: counterexamples show the frame as built next to the generated one. `test_pandas_reads_nan_as_missing_and_polars_keeps_it` shows the two libraries' semantics side by side.
- **polars 2.1 holds rows without columns.** The binding builds them with `pl.DataFrame(height=n)` and raises Unrepresentable only on a polars without that parameter. docs/language.md said polars has no such frame, which is no longer true; its example is now a pandas int64 column, which cannot hold a missing value.
- **Sharing really varies.** pandas' copy-on-write results share the input's data when `select` or `dropna` keeps a column whole, and copy when `dropna` drops rows. This is why `shares_memory` is unspecified. Checked by `test_sharing_is_unspecified_because_pandas_shares`.

## 5. Spec change: select.rows is guarded

`ensures rows` now starts with `all(n in names: n in df.columns) implies`.

- **The problem.** Without the guard, a select that returns although ColumnNotFound is due made `select.rows` a SPEC ERROR (`index_of: ... is not in the list`), charging the spec for the implementation's fault. explore_frames.py's `test_select_skips_missing` showed it, and polars' handling of `*` would trigger it too. docs/language.md's own `bounded` example says such a clause needs a guard.
- **The effect.** With the guard, the same implementation fails `select#2` and `select.columns`, and `select.rows` passes.
- **No weakening.** pandas and polars always raised when ColumnNotFound was due, so their verdicts are unchanged.
- **Since then.** spectest no longer charges such an evaluation error to the spec: a clause that cannot be evaluated where a raise was due, and the call returned, is a skip ("raise due (select#2)"; docs/language.md, Verdicts). On a copy of the spec without the guard, `test_select_skips_missing` now gives `select.rows` 43 passes and 7 skips ("raise due") instead of the spec error, and `select.columns`' counterexample (names = [""] on the empty frame) adds `note: select#2 required ColumnNotFound on this input`. The guard stays: it says what the clause means.

## Deep runs

| Run | Examples per item | Seed | Binding and spec | Result |
| --- | ---: | ---: | --- | --- |
| 1 | 2,000 | 7 | Earlier binding (polars skipped frames with rows but no columns); spec before the guard | pandas: all 27 items pass. polars: only `select.rows` fails. |
| 2 | 1,500 | 7 | Final binding and spec, polars only | Only `select.rows` fails. |

In both runs, every result column stayed float64 (the strict observers would have reported any other dtype), and every result was a new object.