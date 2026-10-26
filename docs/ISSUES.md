# Issues

- lang: docs/language.md's grammar has `impl = or [ "implies" impl ]`, so a `let` or
  `if` cannot be the right operand of `implies` (or of any binary operator), yet
  examples/libm/libm.spec `sqrt.monotone` writes `... implies let y = sqrt(next_up(x)) in ...`.
  The example's intent is clear, so the parser accepts `let` and `if` at any operand
  position, extending as far right as possible (as in ML). Suggested grammar fix:
  `expr = impl ;` and `unary = "-" unary | "let" NAME "=" expr "in" expr
  | "if" expr "then" expr "else" expr | post ;`, plus the note that inside a `let`
  value `in` ends the value unless it is bracketed (`let b = (x in xs) in ...`).
- lang: grammar gaps the parser fills (all supersets, worth stating in the doc):
  `raises [ID:] E when e` and `may_raise [ID:] E [when e]` take an optional label like
  the other clauses; `model` and `interface` may have an empty body; numeric literals
  may use `_` between digits; strings take the escapes `\" \\ \n \t \r \0 \xHH \u{H..}`.
- eval: the checker accepts `old(e)` where `e` uses a `let` or comprehension variable
  bound inside the same clause, e.g.
  `ensures all(i in range(0, len(self.items)): old(self.items[i]) == self.items[i])`.
  Such an `old(...)` cannot be evaluated before the call, so
  `spectest.eval.snapshot_olds` records an EvalError for it and the clause is a spec
  error on every example. The checker should reject it statically, with the hint to
  take `old(...)` of the state itself: `let xs = old(self.items) in all(i in ...: xs[i] == ...)`.
  (resolved: the checker rejects such an `old(...)` with that hint; variables bound inside
  the `old(...)` argument itself stay legal, and `snapshot_olds` keeps its check for
  unchecked input, now limited to variables bound outside the argument.)
- generate: `spectest.sets.index_strategy` draws an index into a set larger than 256 as an
  integer in [2^1100, 2^1100 + n). Each such choice serializes to 141 bytes, and Hypothesis
  caps a test case at 8 KiB of choices (`ConjectureData.max_length`, which counts
  `choices_size` per choice); past that the case overruns and is discarded. Sixty draws of
  libm's `cos` argument through `partition_strategy` already use 7.1 KB, so a long stateful
  run or a list of partitioned values hits the cap at about 70 draws. An offset of 2^128 is
  enough for every range of at most 2^64 values: the distribution's CDF is flat in float64
  there, so `_draw_integer_from_distribution` falls back to `random.randint` exactly as it
  does at 2^1100, and each choice costs about 18 bytes. spectest.generate uses that offset
  for its own draws (integers, and members of its default float classes), and tests that
  they stay uniform; `args_strategy` still draws set partitions through
  `sets.partition_strategy`, so it benefits once sets changes the offset.
  (resolved: `sets.index_strategy` uses the 2^128 offset; tests check that 200 partitioned
  draws fit in one test case, that 2^1100 overran, and that draws stay uniform and shrink
  exactly.)
- core: docs/language.md, Clauses table, `aggregate` row: "`sum(x in S: e) <= c` (an L1
  budget) or `max(x in S: e) <= c` (L∞) with non-negative terms, or `all(x in S: p)`" lists
  fewer shapes than PLAN.md. Implemented (PLAN.md): `sum(...) <= c`, `sum(...) < c`,
  `sum(...) == 0`, `max(...) <= c`, `max(...) < c` and `all(...)`, with c a constant (numbers,
  `T.min`, `T.max`, combined with `+ - * / // %`); `sum(...) == c` for c other than 0 is
  rejected with a hint. The row also does not say that aggregate clauses belong only to `fn`
  declarations (constructors, methods, models and interfaces reject them) or that they may
  not use the function's parameters, `result` or `old`; both are enforced.
- core: the same row says the terms are non-negative but not what a negative one is. A
  negative term of a `sum` or `max` aggregate (an int, a real, or a promoted float) is an
  EvalError, so the clause is a spec error; PLAN.md says this only for int terms. For `max`
  the sign does not affect soundness, but the doc's rule is applied to both.
- core: docs/language.md, Types table, `qerr` row ("a number c means c + 0·nan") does not
  define strict order. Implemented: `a <= b` iff both parts are <=, `a < b` iff `a <= b` and
  `a != b`, `>` and `>=` mirrored; so `qe(r, y) < 1` means 0 steps and no NaN error, and
  `qe(x, nan) <= 100` is false. Comparing a qerr with a float (as opposed to an int or real)
  is a check error. `qerr` has no total order, so `sorted`/`is_sorted` reject it.
- core: docs/language.md, Grammar, "`NAME<type>` applies only to the prelude's generic
  functions (`wrap`, `fits`, `round`, `ulp`, `qe`)" does not say what `qe<F>(a, b)` means.
  Implemented: the type argument is optional; with it, each argument is an F value or a
  number (int, fixed-width int, real), and a number must be exactly representable in F
  (otherwise an EvalError), so `qe<f16>(result, 0.5)` works and `qe<f16>(result, 0.1)` is a
  spec error. A float of another format is a check error.
- core: docs/language.md, Expressions, comprehension list: `max(x in xs: e)` is listed
  without its edge cases. Implemented: `max` of no elements is an EvalError; its body is a
  number or a qerr; floats promote, so `max` over floats is a real (NaN is an EvalError);
  `max` over qerr is the componentwise maximum. `sum` over qerr starts at 0 (`QError.ZERO`).
- core: docs/language.md, State: "`old(e)` evaluates `e` on the state before the call"
  could add the static rule now enforced: `e` may not use a `let` or comprehension variable
  bound in the same clause outside the `old(...)`; bind `old(...)` of the state first.
- runtime (observed in generate): an `i64` failure on all negative values (`invariant v >= 0`
  on `fn wrap(n: i64) -> Box`) shrinks to `n = -2`, not `-1`. In spectest.sets' member order
  -1 is a simple member at index 2 and the negatives start at -2, so shrinking the single
  weighted choice reaches the start of the negative block but not the special index. The
  counterexample is valid; it is one step from the simplest one.
  (resolved: a signed integer is drawn behind a leading choice of 0, 1, -1 or any member, so
  shrinking that choice reaches -1; the runner's post-shrink pass also tries 0, 1 and -1.)
- binary: byte-string counterexamples are often not minimal. Reproduction: spec
  `fn unpack(b: bytes) -> bool` with `ensures ok: result`, bound to
  `lambda b: not (len(b) > 4 and len(b) % 4 == 0)` (false exactly at lengths 8, 12, 16,
  like `numpy.frombuffer(b, "<i4")[0]`), max_examples=300. Seed 0 reports
  `b = b"\x00" * 8`, seed 1 `b"\xc2\x80\xc2\x80\xf0\x90\x80\x80"`, seed 2
  `b"0000\xc2\x80\xc2\x80"`; the minimum is `b"\x00" * 8`. In examples/binary,
  test_numpy::unpack_i32#1 reports 16 zero bytes on seeds 0, 1, 2 and 4 (at 300 examples;
  8 bytes suffice) and unpack_i32.value reports `b"\xf0\x90\x80\x80\xf0\x90\x80\x80"`
  on seed 0 where `bytes(4) + b"\x01" + bytes(3)` would do. Two causes: Hypothesis deletes
  one element at a time, and from a failing length 16 every single deletion gives a passing
  length (plain `hypothesis.find(st.binary(max_size=16), ...)` also stops at 16 zero bytes
  in 2 of 3 runs); and generate's bytes strategy is `one_of(binary, utf8 text, utf8 with a
  bad sequence)`, whose second and third branches never shrink into plain zero bytes. A
  post-shrink pass like stateful's `shorten`, trying every prefix length and then zeroing
  bytes, would reach `bytes(8)` in both cases.
  (resolved: spectest.shrink's pass after Hypothesis tries every shorter prefix and suffix,
  single deletions and zero bytes; seeds 0, 1, 2 give `bytes(8)`, and test_numpy's items now
  report `bytes(8)` (seeds 0, 1, 2, 4) and `bytes(7) + b"\x01"`.)
- binary: partition coverage counts every example that passed `requires`, including those
  the item skipped, so the coverage table can show a class as exercised by a clause that
  never judged it. examples/binary/REPORT.md, test_struct: `pack_i32.length` shows
  `x: too_small` and `x: too_large` with about 150 examples each, all of them skips (the
  call raised); `unpack_i32.value` shows `b: other` with hundreds of examples, all skips.
  Tally.add counts coverage for `ex.status in ("judged", "timeout")` whatever the item's
  verdict. Counting only examples the item judged (pass or fail), or showing judged and
  skipped separately, would make "a class with 0 examples was never exercised" true.
  (resolved: `Tally` counts coverage only for pass and fail verdicts, and the report's skip
  column breaks skips down by cause: requires, raised, raise due, wrong type, unrepresentable,
  rejected, planned call.)
- binary: the Markdown report's coverage tables label rows by clause ID only. With several
  conformances of one spec (examples/binary has six), the `pack_i32` table lists
  `pack_i32#1` four times with nothing saying which conformance each row belongs to; the
  order matches the results table, which is the only way to tell them apart. The
  Counterexamples section has the same gap: `### unpack_i32#1 (expected failure)` heads both
  test_int_bytes's and test_numpy's counterexample, and only the reproduce line says which
  is which. Using the conformance name with the clause (`test_numpy::unpack_i32.value`) in
  both places would fix it.
  (resolved: counterexample headings, coverage rows and the aggregates table use
  `<conformance>::<clause name>`, or the whole item path when two files' conformances share a
  name.)
- binary: on a rerun, an item whose counterexample is in the store replays it and stops,
  so the report's counts and coverage for that item come from the one replayed example
  (`verdicts: 1 fail`, every class but one at 0). The REPORT.md of a run therefore depends
  on whether `.spectest/` was warm: after a fresh search, test_seeded_wrapping_pack's
  `pack_i32#1` reads 1 pass, 1 fail and covers in_range and too_large; after a replay it
  reads 1 fail and covers too_small only. The counterexample says it was replayed, but the
  results and coverage tables do not. Marking replayed items in the tables, or running the
  search's generate phase anyway for the statistics, would make reports comparable. A
  related oddity: tallies stop at the first failure, before shrinking, so in the fresh
  report the counterexample's own class (x = -2147483649, too_small) shows 0 examples.
  (resolved: a replayed item reads "hypothesis, replayed" in the results table's Mode column
  and "(replayed)" in its coverage rows, with a note on what that means. The related oddity
  remains: tallies still stop at the first failure.)
- sorting: generated lists have at most `Sizes.max_list` = 8 elements (`max_inner` = 4 when
  nested), and `conformance()` cannot change that, so an implementation that switches
  algorithm above some size is only ever tested below it. Reproduction, on x86-64, where
  `NPY_DISABLE_CPU_FEATURES=X86_V3` makes numpy use its portable sort:
  `NPY_DISABLE_CPU_FEATURES=X86_V3 uv run pytest examples/sorting/explore_sorting.py -k default_kind`
  passes `sort_by_first.stable` for `np.argsort(keys)` (the default kind, documented as not
  stable) on 2,000 examples per item. In the same file, `test_longer_lists_expose_the_default_kind`
  runs the same FunctionPlan on `generate.args_strategy(..., Sizes(max_list=40))` and fails
  the clause on 17 pairs with equal keys; the portable sort is stable up to 16 elements
  (`test_numpy_portable_argsort_is_stable_on_short_arrays` in examples/sorting/test_sorting.py).
  The same bound means `sorted` and `list.sort` are tested only on CPython's binary insertion
  sort: timsort sorts fewer than 64 elements as a single run, with no merging
  (`merge_compute_minrun` in Objects/listobject.c). Suggested: a `sizes=` option on
  `conformance()`, and a small share of long lists (64 elements or more) in the default
  list strategy.
  (resolved: `conformance(sizes=Sizes(...))`, and a sixteenth of top-level lists, strings and
  bytes are long (lists of 17 to 100 elements); with `NPY_DISABLE_CPU_FEATURES=X86_V3`,
  test_numpy_default_kind's `sort_by_first.stable` now fails on 17 pairs, so it is an expected
  failure on both dispatch paths.)
- sorting: for a function that returns nothing and changes a handle, the counterexample
  says `result = unit`, and shows the handle after the call only when it changed. The seeded
  `sort_a_copy` (sorts a copy and leaves the list as it was) reads
  `xs = MutableList { items: [0, -2] } -> result = unit` in the summary; the full display
  adds only `xs.items = [0, -2]` under explanation, without saying that this is the state
  after the call, so the bug (nothing changed) is never stated. Reproduction: the
  `sort_in_place.ordered[T=i64]` counterexample in examples/sorting/REPORT.md. Suggested:
  always show each handle the function may modify after the call (`xs after = ...
  (unchanged)`), and use that in place of `result = unit` in the one-line summary.
  (resolved: the observation shows `xs after = ...` for every handle that `modifies` lists,
  marked `(unchanged)` when its digest is unchanged, in place of `result = unit`; the one-line
  summary reads `xs = MutableList { items: [0, -2] } -> xs after = MutableList { items: [0, -2] }
  (unchanged)`.)
- sorting: a `modifies` clause that names every handle parameter (`modifies xs` on
  `sort_in_place(xs: MutableList<T>)`) becomes an item, `sort_in_place[T=i64]#1`, with
  nothing to compare, yet each example counts as a pass (examples/sorting/REPORT.md: 500
  pass). The frame check compares only handle parameters that `modifies` leaves out. Counting
  such examples as skip ("every handle parameter may change"), or making no item, would
  stop the report from claiming checks that never ran.
- sorting: docs/language.md does not say which order `Ord` means on `string` (nor on
  `bytes`, `bool` and tuples). The prelude compares strings by code point, which is UTF-8
  byte order but not the UTF-16 code-unit order of Java and JavaScript:
  examples/sorting/explore_sorting.py `test_explore_utf16_order` fails
  `sort.ordered[T=string]` on `["𐀀", "\u{e000}"]` for a UTF-16 sort (after 1,403 passing
  examples). A sentence in the Types section ("strings order by code point, bytes by byte,
  tuples lexicographically, false < true") would say what a binding must match.
  (resolved: docs/language.md, Types and values, lists the order of every `Ord` type and says
  no other type is `Ord`; prelude tests check strings against code points and UTF-8 bytes.)
- sorting: one clause appears under two names. Node IDs put the instantiation before the
  label, without spaces (`sort_by_first[K=i64,V=string].stable`); failure headers, the
  spectest summary and the report's headings put it after, with a space
  (`sort_by_first.stable[K=i64, V=string]`), so a name copied from a failure is not a valid
  node ID. The report's counterexample headings also omit the conformance:
  examples/sorting/REPORT.md has two `sort_by_first.stable[K=i64, V=string]` sections
  (test_numpy_default_kind and test_seeded_bugs), told apart only by the reproduce line.
  (resolved: every printed name puts the instantiation where node IDs do,
  `sort_by_first[K=i64,V=string].stable`, as PLAN.md and docs/language.md document; report
  headings add the conformance, `test_seeded_bugs::sort_by_first[K=i64,V=string].stable`; and
  `--spectest-clause=GLOB` selects clauses by name or ID, since `-k` cannot take `#`.)
- sorting: the report's facts name spectest and Hypothesis but not the platform or the
  implementation's libraries, although verdicts can depend on them:
  `test_numpy_default_kind::sort_by_first[K=i64,V=string].stable` fails on x86-64 with AVX2
  (numpy 2.5.4 dispatches argsort to a SIMD sort that reorders equal keys from 4 elements)
  and passes on numpy's portable sort. Recording the Python version, `platform.machine()` and the
  versions of imported top-level packages such as numpy would make two reports comparable.
  (resolved: the report records the Python implementation and version, the OS and
  `platform.machine()`, and the versions of numpy, pandas, polars, gmpy2 and ml_dtypes when
  imported, and of any installed package a bound callable comes from.)
- frames: an implementation's fault in a model-typed result is charged to the spec. `<fn>#type`
  checks only that the result reads as a handle, which any object but None does
  (`binding._from`, ModelT branch), and an observer that refuses the object is a BindingError,
  so every clause that reads it is a spec error. Reproduction:
  `uv run pytest examples/frames/explore_frames.py`, conformance `test_dtype_change`:
  `fillna` returns `df.fillna(value).astype(object)` and the pandas binding's `rows` observer
  raises because the columns are not float64. `fillna#type` passes, and `fillna.rows`,
  `fillna:Frame.rectangular` and `fillna:Frame.row_count` are SPEC ERROR ("the spec's or the
  binding's fault"). Expected: a failure charged to the implementation, e.g. `<fn>#type` failing
  when an observer raises on a handle the call just returned (its `created_by` is the function),
  or a ModelBinding hook (say `check(obj)`, or observers raising TypeMismatch) that marks an
  object as not a value of the model.
  (resolved: observers raise `spectest.NotAValue` and `ModelBinding(accepts=...)` refuses an
  object; on a returned handle `<fn>#type` fails, reading every field, and the clauses that
  read it skip. The frames bindings use both, and `test_dtype_change` now fails `fillna#type`.)
- frames: counterexample inputs show the generated fields, not the object the implementation
  received. `FunctionPlan.format_inputs` prints a GeneratedModel through `show_generated`, and
  nothing checks that the concretized object observes as those fields. Reproduction: a polars
  concretizer `pl.DataFrame([pl.Series(name, cells, dtype=pl.Float64) for ...])` renames a
  column named "" to "column_0"; test_seeded_bugs::dropna.rows then printed
  `df = Frame { columns: ["", "0", "1", "00"], ... }` with
  `result = Frame { columns: ["column_0", "0", "1", "00"], ... }`, an input that never existed.
  Verdicts were right (clauses observe the real object), the display was not. Suggested: after
  concretizing, compare `fields(handle)` with the generated fields and report a binding error on
  a mismatch (a binding that is lossy on purpose, like pandas reading NaN as none, could opt
  out), or print the observed input when it differs. examples/frames/frames_bindings.py now
  checks its own round trip.
  (resolved: `binding.concretize` reads the object back and raises a BindingError showing both
  values on a mismatch, unless `ModelBinding(lossy=True)`, whose counterexamples add
  `df as built = ...`; the pandas binding is lossy, and the frames bindings' own check is gone.)
- frames (generate): shrinking a model whose field lengths depend on an earlier field stalls.
  Frame rows are drawn per column count (`all(r in rows: len(r) == len(columns))`), so dropping a
  column means deleting its name and one cell in every row, two separate spans of choices, which
  no Hypothesis shrink pass does. Reproduction: `uv run pytest examples/frames -k seeded -rx`:
  `fillna.rows` keeps 4 columns
  (`Frame { columns: ["", "0", "1", "00"], rows: [[none, none, some(0.0), some(nan)]] }`) and
  `dropna.rows` 3, while `Frame { columns: [""], rows: [[some(nan)]] }` and
  `Frame { columns: [], rows: [[]], nrows: 1 }` with how = "all" fail too (asserted by
  test_seeded_fillna_overwrites_nan and test_seeded_dropna_ignores_how). Suggested: draw such
  models column-major (nrows, then each column's name with its cells, so a column is one span),
  or add a model-aware shrink step that removes a column.
  (resolved: spectest.shrink removes a prefix, a suffix or one element of a field together
  with the matching cells of the fields drawn to its length; fillna.rows now reports
  `Frame { columns: [""], rows: [[some(nan)]], nrows: 1 }` and dropna.rows
  `Frame { columns: [], rows: [[]], nrows: 1 }`, how = "all".)
- frames: docs/language.md, "Generating model values", says "polars has no frame with rows but
  no columns". polars 2.1.0 has one: `pl.DataFrame(height=3).shape == (3, 0)`, and dropping the
  last column keeps the height. Only `df.select([])` still returns a 0 x 0 frame (a finding in
  examples/frames/FINDINGS.md). The frames binding builds such frames with `height=` and raises
  Unrepresentable only on a polars without that parameter; the doc needs another example.
  (resolved: the example is a pandas int64 column, which cannot hold a missing cell.)
- frames: a spec error is reported on the first input that raised, not a shrunk one. Before the
  frames spec guarded `select.rows`, examples/frames/explore_frames.py `test_select_skips_missing`
  reported `index_of: '\x01ÊÈ\x03Áæ' is not in the list`, where `names = [""]` on the empty
  frame would do. Spec errors are the spec author's to fix, so a small example matters.
  (resolved: the first input of each kind of spec error is shrunk, by a Hypothesis run that
  stops at it and spectest.shrink's pass, and each kind is reported once. On the unguarded
  spec with `may_raise` (with `raises` the clause is now a "raise due" skip), the report is
  `index_of: '' is not in the list`, example `df = Frame { columns: [], rows: [[]], nrows: 1 },
  names = [""]`: one row is needed, since on no rows index_of is never evaluated.)
- frames: the Markdown report's counterexample headings name only the clause label
  (`### dropna.rows (expected failure)`), so the same clause failing in two conformances of one
  spec gives two identical headings; only the reproduce line inside tells them apart. Suggested:
  head each counterexample with the conformance and item name.
  (resolved: headings read `test_seeded_bugs::dropna.rows`, the conformance and the clause's
  name.)
- deque: the Markdown report's Results table cannot be read for interface items. Every
  clause of an interface item is a row whose Item cell is the item ID, so
  `uv run pytest examples/deque --spectest-report=/tmp/r.md` prints 38 rows that all read
  `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]`, told apart only by
  Kind; no row names its clause (`_render_one` in runtime/report.py uses `r.item_id`). The
  "**Items:**" line counts ClauseResults, not pytest items (examples/deque: "524: 510
  passed, 14 expected failures" for 14 spectest items, 4 passed and 10 xfailed), so its
  tally disagrees with pytest's. Suggested: a Clause column with
  `r.label` (`Deque.pop#1[T=i64]`), and an item count per pytest item. Counterexample
  headings (`### Deque.rotate.items[T=i64]`) do not name the conformance either; only the
  reproduce line inside tells two conformances' failures apart. The libm report's coverage
  tables have the same gap: rows of different conformances repeat the same clause ID.
  (resolved: the Results table has a Clause column, `Deque[T=i64].pop#1`; "**Items:**" counts
  pytest items with the outcomes pytest reported, and "**Clause results:**" counts clause
  results; headings and coverage rows name the conformance,
  `test_collections_deque::Deque[T=i64].rotate.items`.)
- deque: strict expect_fail is lost on interface items. A conformance over
  examples/deque/deque_impls.py's `PopleftNoneDeque` with
  `expect_fail={"Deque.popleft#1", "Deque.popleft#type", "Deque.pop#1"}` (pop#1 cannot fail
  for that class) reports XFAIL in pytest and "1 expected failure" in the terminal summary,
  while the Markdown header says "1 unexpected pass". `stateful.interface_outcome` returns
  "xfailed" whenever the failing clauses are a subset of the expected ones; it never checks
  that every expected clause failed. A function item has one clause, so it is strict.
  Suggested: "xpassed" (a strict failure naming the clauses) when expected - failing is
  non-empty.
  (resolved: `interface_outcome` returns "xpassed" when an expected clause never failed, the
  XPASS(strict) message names only those clauses, and an expected clause the item never judges
  gets a result of its own; that conformance now reads `[XPASS(strict)] expected to fail:
  Deque[T=i64].pop#1`, "1 unexpected pass" in the summary and "Items: 1: 1 unexpected pass".)
- deque: stateful searches rarely reach deep states. `STEP_COUNT = 30` steps are spread over
  many handles, because every constructor is a rule as likely as any method. For
  examples/deque with both constructors, 300 examples (T=i64) made 2,954 deques and 5,776
  method calls: 65% of method calls met an empty deque, 17% a deque of one item and 8% a deque
  of three or more. `bounded(n: u8)` drew n = 1 for 1.4% of bounded deques, against 15% for
  n = 0. In 1,000 examples, appendleft on a full bounded(1) or bounded(n >= 2) deque never
  ran. Consequences: the seeded bug WrongEndDeque (appendleft on a full deque drops the wrong
  end) is found at seed 0 but missed at 4 of 12 (seed, T) runs at 300 examples
  (seeds 0-5); BackwardRotateDeque is missed at seed 1, T=i64, at 100 examples. The deque
  example works around it with a second conformance that binds only `bounded`. Suggested:
  cap live handles (constructor rules only while fewer than 2-3 handles live, or
  `initialize` rules), prefer recent handles, draw small values more often for parameters
  that become sizes, and conformance options for the step count and handle cap.
  (resolved: constructor rules run only while fewer than `max_handles` (default 2) handles are
  live, a method runs on the handle used last at least half the time, an argument declared as
  an integer is -4 to 4 (0 to 4 unsigned) three times in four, and `conformance()` takes `steps=` and
  `max_handles=`. examples/deque now has one collections.deque conformance, with both
  constructors at 300 examples; it reaches every edge case of its FINDINGS.md section 2 at seeds
  0-11. WrongEndDeque is found at 12 of 12 (seed, T) runs at seeds 0-5, at 100 examples and at
  200, against 6 and 8 before; BackwardRotateDeque at 12 of 12 at 100, against 11.)
- deque: interface items record no partition coverage and do not use the counterexample
  store. `stateful.Recorder` tallies verdicts only, and `run_interface` never reads or
  writes `.spectest/`, so a failing step sequence found once is not replayed first on the
  next run (with another `--spectest-seed` it may not be found at all), and the report
  cannot show which edge cases an interface search exercised. examples/deque/explore_deque.py
  measures that with a counting subclass of collections.deque.
  (resolved: each interface clause counts the partition classes of constructor and method
  parameters on the calls it judged (pass or fail). A minimized failing step program is saved
  through the store's `save`/`load` and replayed first on the next run; the counterexample
  says "(replayed from the counterexample store ...)", the result is marked replayed, and the
  search then runs with that clause muted, so the other clauses still get a full search.
  deque.spec has no partitions and its edge cases depend on the state, so explore_deque.py
  stays.)
- deque: shrinking cannot reduce a constructor argument together with the steps that depend
  on it. WrongEndDeque, T=string, 300 examples, seed 4: the counterexample is
  `bounded(n=12)`, twelve appends and `appendleft(x="")` (14 steps); the minimal one is
  `bounded(n=1)`, `append`, `appendleft` (3 steps). Making n smaller alone, or deleting one
  append alone, stops the failure, and `stateful.shorten` only deletes steps.
  (resolved: `stateful.minimize` alternates `shorten` with `lower_arguments`, which tries 0,
  half and one closer to 0 for a constructor's integer argument, the last also with each one
  step on the constructed handle deleted; that 14-step program minimizes to `bounded(n=1)`,
  `append(x="0")`, `appendleft(x="")`, and the seed-4 run now reports `bounded(n=1)`, `append`,
  `appendleft`.)
- deque: `eval.snapshot_olds` calls `old_calls(c.expr, spec)` on every call, re-walking each
  clause's AST. In a cProfile of the WrongEndDeque T=i64 item (94 s, most of it Hypothesis
  shrinking 30-step programs, 1,472 replays at about 63 ms each), `old_calls` took 11 s
  (`ast.walk` 6.7M calls) and `binding.observe` 12 s (422k observations). Caching the
  old(...) calls per clause would remove the first.
  (resolved: `snapshot_olds` finds a clause's old(...) calls once per clause; a step reuses the
  last step's post-state observations as its pre-state and skips the receiver's digest when
  the method modifies self. Seed 0, profiled: the item took 11.8 s instead of 124 s, 0.88 ms
  per step instead of 2.1 ms, `snapshot_olds` 0.035 ms per call instead of 0.73 ms (`old_calls`
  0.03 s instead of 12.2 s), with 6.7 observations and 1.5 digests per step instead of 14.5 and
  3.1; unprofiled 3.6 s instead of 32.4 s. Fewer steps (4,697 instead of 29,208) come from the
  deeper search finding the bug sooner.)
- deque: an interface clause label can equal a member's declaration ID. deque.spec's
  `invariant bounded:` gets ID `Deque.bounded`, the constructor `bounded` is also
  `Deque.bounded`, and the constructor's clauses `Deque.bounded.items` /
  `Deque.bounded.maxlen` read like parts of the invariant. The checker accepts it silently;
  a warning (or an error) for a label that names a constructor, method or observer would
  keep IDs unambiguous.
  (resolved: the checker rejects such a label with a rename hint, docs/language.md states the
  rule, and the invariant is `within_bound`, ID `Deque.within_bound`.)
- deque: the verdict counts in an interface clause's counterexample include the reruns in
  which that clause was muted, so a failing clause shows e.g. "verdicts: 106 pass, 169 fail"
  (Deque.popleft#1 for PopleftNoneDeque), while function items count up to the first failure
  only. The numbers are right, but they read as if most calls failed during the search.
  (resolved: an interface clause's verdicts are counted only up to its first failure, also when
  another clause reported that step; Deque.popleft#1 now reads "verdicts: 1 fail".)
- deque (language): no clause can constrain the state after a call that raises. `ensures`
  is skipped when the call raises, and `modifies self` covers both outcomes, so deque.spec
  cannot say that pop on an empty deque leaves it unchanged; a pop that raises IndexError
  and also appends an item passes every clause (checked at 300 examples). A form such as `ensures_on E: ...` or "modifies nothing
  when raising" would close it.
  (decided for v1: the state a raise leaves in a handle the call may modify is
  implementation-defined, and every other handle must be unchanged after a raise as after a
  return; docs/language.md says so and lists the gap under "Not in v1". The intended direction
  is subclauses under `raises` clauses, judged when the call raises that error.)
- tests: `test_scaled_bytes_shrink_close_to_the_boundary` now runs derandomized, because the
  random version failed about half the time. The weakness is real: shrinking
  `find(index_strategy(2**40, far=False), lambda i: i > 10**9)` lands within 1% of 10**9 in
  12 of 20 seeds, and at 4294967296 in the worst ones. `far=True` gives 10**9 + 1 every time.
- generate: Hypothesis mixes literals from every local module a process has imported into
  its draws, and that includes spectest's own source in an editable install and the test
  modules. An edit to spectest, or a run that imports other modules (a CI worker that also ran
  tests/), therefore shifts the example streams a little. Verdicts and counterexamples held in
  every comparison so far; the counts moved by under 1%. Turning it off needs a private
  Hypothesis API.
- runtime (stateful): interface items are the slowest part of every run: a seeded deque item
  takes several seconds, about 60% of it Hypothesis's shrinking of step programs, and
  test_seeded_bug_fails_with_a_short_step_log takes 14 s even at the dev budgets. A lean step
  driver with its own replay shrinker was tried and taken out again. It was 6 times faster,
  but it skipped invariants on handles whose digest had not changed (unsound when an
  invariant reads an observer with arguments) and made some deque edge cases 3 to 6 times
  rarer. A faster driver needs its own design, tested against both cases.
- runtime: a search shared by a function's items was tried and taken out again. Judging
  several items on one example lets a relates clause whose planned call mutates an input
  change the verdict of the items judged after it (#frame then fails as "flaky"). Any
  sharing must run each item on a fresh copy of the inputs.
