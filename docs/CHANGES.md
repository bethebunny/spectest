# Changes to the contract modules

Additions to `ast.py`, `types.py` and `values.py`, with the reason for each.

- runtime: `values.Handle` gained a last field, `targs: tuple[Type, ...] = ()`, the type
  arguments of a generic model or interface handle (`MutableList<i64>` has `(i64,)`).
  Observer types such as `items: list<T>` depend on them, and a handle is all that
  `observe(handle, ...)` receives. Existing positional and keyword constructions are
  unchanged. `concretize` sets it from `GeneratedModel.targs`, and `from_python` sets it
  from the declared `ModelT.args`.
- core: `types.QErrT` (printed `qerr`) and the singleton `types.QERR`, the type of quantized
  errors from `qe`. `has_canonical_eq(QErrT())` is true; `has_total_order(QErrT())` is false,
  because the componentwise order is partial.
- core: `values.QError(steps, nans)`, the runtime value of `qerr`: frozen, both parts ints
  >= 0, `+` adds componentwise, `le(other)` is the componentwise order, `max(other)` the
  componentwise maximum, `QError.ZERO` is 0, and `str`/`repr` print `3`, `1nan`,
  `3 + 1nan` and `0`.
- core: `ast.CLAUSE_KINDS` gained `"aggregate"` (a bound over a whole input set), and
  `ast.Comprehension.kind` may be `"max"`. Both are needed for the quantized-error clauses of
  docs/language.md.
- runtime (report.py): `render_failure` no longer prints "failed on N of M inputs (exhaustive:
  ...)" for an `aggregate` result whose mode is "exhaustive". An aggregate is one evaluation
  over a whole set (its counts hold a single verdict), so that line read "failed on 0 of 1
  inputs"; the aggregate's own lines (value, bound, members, largest terms) say what failed.
- runtime (report.py): `ClauseResult.label` puts the instantiation after the declaration's
  name, as node IDs do (`sort_by_first[K=i64,V=string].stable`, `Deque[T=i64].pop#1`), instead
  of after the whole clause ID with spaces (`sort_by_first.stable[K=i64, V=string]`), so a name
  copied from a failure is a node ID. `clause_name(clause_id, instantiation)` computes it;
  `ClauseResult.conformance` and `.qualified` (`test_numpy::cos.accurate`) name the
  conformance.
- runtime (report.py): `ClauseResult` gained `replayed: bool = False` (the item replayed a stored
  counterexample instead of searching) and `skips: dict[str, int]` (skips by cause, keys of
  `SKIP_CAUSES`); `coverage` now counts only the examples the item judged (pass or fail), so a
  class with 0 examples was never exercised. `Report` gained `items` (pytest item ID to outcome,
  so the report's item tally agrees with pytest's), `platform` and `packages`; `Report.tally()`
  still counts clause results, and `Report.item_tally()` counts items. JSON without these fields
  still loads.
- runtime (runner.py, plans.py): `Tally` counts coverage for pass and fail verdicts only, and
  skips by `plans.skip_cause(example, key)`; `Runner.counterexample` no longer appends a `#type`
  item's note to its observation, which already states the mismatch (as does stateful's
  counterexample).
- runtime (plans.py): a raise is shown as `raised E: msg (maps to SpecError)`, not
  `(spec error SpecError)`, which read like the spec error verdict. A function's observation
  shows the state after the call of every handle its `modifies` lists, marked `(unchanged)` when
  the digest is unchanged, in place of `result = unit`.
- eval (format_value): strings and bytes share one escape scheme. NUL prints as `\x00` in both
  (strings printed `\0`), bytes use `\n`, `\t` and `\r` like strings, and strings print U+FFFD
  as `\u{fffd}`.
- plugin: `--spectest-clause=GLOB[,GLOB...]` selects clauses by name or ID; under `--runxfail`
  an expected failure is reported as a failure (it passed before, because `pytest.xfail` is a
  no-op there) and an expected failure that did not fail passes.
- core (values.py): `values.NotAValue(Exception)`, exported as `spectest.NotAValue`. A model
  binding raises it to say that an object is not a value of the model; before it, any observer
  failure was a binding error, so an implementation that returned a malformed object (a frame
  with an object column) was charged to the spec.
- runtime (binding.py): `ModelBinding` gained `accepts: Callable[[Any], bool] | None = None`
  and `lossy: bool = False`, and binding.py gained `ValueRefused(BindingError)` (with the
  refused `handle`), `refusal(obj, model, conf)` and `check_round_trip(...)`. `from_python`
  raises TypeMismatch for a model object that `accepts` refuses; `observe` turns NotAValue
  into ValueRefused. `concretize` raises BindingError when `accepts` refuses the built object,
  or, unless the binding is lossy, when the object does not observe as its generated fields
  (the message shows both); bindings whose concretizer cannot be observed back now fail there.
- runtime (plans.py): `CallJudge.type_verdict(ctx)` reads every field of each model handle in
  the result and fails on ValueRefused (other binding errors make it a spec error);
  `CallJudge.refused(exc)` makes ensures, relates and invariant items skip on a refused result
  ("the result is not of its declared type") or planned-call result. `_Run.observation` starts
  with `<param> as built = ...` for each input a lossy binding built otherwise than generated.
- lang: a model's or interface's clause label may not equal the name of one of its observers,
  constructors or methods (examples/deque's `invariant bounded:` gave the ID `Deque.bounded`,
  the constructor's ID); `Checker.assign_ids` takes the member names.
- prelude: `codepoints(s: string) -> list<int>`. `valid_utf8` follows Unicode Table 3-7 itself
  instead of calling CPython's UTF-8 decoder, and `sorted` is a merge sort instead of Python's
  `sorted`, so neither shares code with an implementation a spec may judge.
- runtime (binding.py): `Conformance` gained `steps: int = 30` and `max_handles: int = 2`, and
  `conformance()` the same keyword options (positive integers): the calls in each stateful step
  sequence, and the live handles before constructor rules stop. With every constructor a rule
  as likely as any method, a sequence's steps were spread over about ten handles, so deep
  states (a full bounded deque) were rarely built.
- runtime (stateful.py): `interface_outcome` is strict per clause: it returns "xpassed" when an
  expected clause never failed, even if other expected clauses did, and `run_interface` adds a
  result (expected, never judged) for an expected clause that is not one of the item's tallied
  clauses, such as a clause of an unbound constructor. Interface results now carry `coverage`
  (partition classes of constructor and method parameters, counted on calls the clause judged)
  and `replayed`, and each clause's counts stop at its own first failure. `Step` (was
  `_Step`), `encode_program`, `decode_program`, `replay`, `lower_arguments` and `minimize` are
  public; `shorten` is unchanged. The counterexample store holds an interface item's failing
  programs through the existing `save`/`load` API, as inputs
  `{"clause": ID, "steps": [["new" | "call", name, target position or null, {args}], ...]}`.
- eval: `snapshot_olds` works out each clause's old(...) calls (and why one cannot be
  snapshotted) once per clause expression instead of on every call.
- runtime (binding.py): `Conformance` gained `sizes: generate.Sizes = DEFAULT_SIZES` and
  `examples: dict[str, list[dict]]`, and `conformance()` the same keyword options. `sizes`
  bounds the generated collections; `examples` maps a bound function, or a constructor or
  method of a bound interface (`"Deque.push"`), to explicit argument dicts judged before the
  search (a model-typed argument is a dict of the model's fields, computed fields optional).
  Each example must fit at least one instantiation, or `conformance()` raises. Lists were
  capped at 8 elements with no way to raise the cap (examples/sorting could not reach numpy's
  portable argsort, which is stable up to 16), and an input known to be tricky (a frame column
  named `*`) could only be reached by chance.
- generate: `Sizes` gained `long_list = 100`, `long_text = 100`, `long_bytes = 100` and
  `long_share = 1/16`: that share of top-level lists, strings and bytes is long (from twice the
  short bound plus one up to the long bound; lists of flat elements only, drawn from a palette
  of repeated values), and `max_len` counts the long bounds. `Sizes.long_bounds(kind)` and
  `Sizes.problems()` are new. `args_strategy` gained `examples=` (explicit argument dicts, about
  a quarter of the draws), and a parameter with a predicate partition is drawn class first (a
  class, or no class as often as any one class), with `len(p) <op> n` conjuncts fixing the
  drawn lengths and other conjuncts met by up to four draws. New public helpers for models:
  `FieldPlan` (was `_FieldPlan`), `field_plans`, `computed_fields`, `broken_invariants` and
  `invariants_hold`. A signed fixed-width integer is drawn behind a leading choice of 0, 1, -1
  or any member, so a failure on every negative value shrinks to -1 (it stopped at -2, where
  the negatives start in spectest.sets' member order).
- shrink (new module): `minimize(args, types, fails, spec, defaults=, budget=, deadline=)`, the
  deterministic pass the runner applies after Hypothesis's shrinking: defaults, shorter
  prefixes and suffixes, single deletions, simpler elements, and removal of one element of a
  model field with the matching element of the fields whose elements take its length.
  `candidates(value, t, spec)` lists the simpler values it tries.
- runtime (runner.py): explicit examples are judged first (in exhaustive mode they join the
  pass); a failure found by the search or replayed from the store is minimized by
  `shrink.minimize` before it is stored and shown; spec errors are grouped by
  `error_signature(message)` (the message without quoted values and numbers), and the first
  input of each of the first five kinds is shrunk (the first kind also by a Hypothesis run that
  stops at it) and reported once. `Tally.spec_error_args` keeps the inputs; `Runner.search`
  takes `tally=None` and `target=`, and `Runner.minimize` and `Runner.shrink_spec_errors` are
  new. Spec errors were reported on the first input that raised them, failures kept lengths no
  single Hypothesis deletion could reduce (16 zero bytes where 8 fail), and frames kept 3 and 4
  columns where 1 fails.
- runtime (plans.py): when a call returns normally where a `raises` clause was due, an ensures,
  relates or invariant item whose evaluation errors is a skip with the note
  `raise due (<fn>#n)` instead of a spec error, and a failing one's note gains the line
  `note: <fn>#n required <Error> on this input` (`CallJudge.due`, `returned_while_due`,
  `due_skip`, `due_notes`); the raises conditions are evaluated for those items too. New
  helpers for explicit examples: `from_example`, `example_args`, `explicit_examples`,
  `example_decl`, `example_problems`, and `FunctionPlan.explicit_examples()`.
- runtime (stateful.py, a small edit for explicit examples): `CallablePlan.prepare` takes
  `examples=()` and passes them to `args_strategy`, and `InterfacePlan.prepare` gives each
  constructor and method the conformance's examples for it (`plans.explicit_examples`).
- plugin: `--spectest-store=DIR`, `--spectest-no-store`, `--spectest-profile=ci|dev` and the
  ini setting `spectest_profile` (`pytest_plugin.PROFILES`; `dev` is 25 examples per item, an
  exhaustive limit of 4,096 and 1,000 aggregate samples). Each call report carries the item's
  results as JSON (`report.spectest`, from `SpectestItem.payload()`), and the session builds
  the reports and the summary from them, so under pytest-xdist the controller writes the same
  reports as a serial run; `build_reports` takes items or payloads and orders them by
  collection (`SpectestItem.spectest_index`).
- store: `CounterexampleStore.save` holds an `fcntl.flock` on the item's directory while it
  reads and rewrites the file, so processes sharing a store lose no entry.
