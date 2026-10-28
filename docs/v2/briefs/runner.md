# Brief: runner

Runs a spec's declarations against the code under test: load, generate, call, judge,
shrink, store and report results. This is where every earlier package meets.

**Owns:** `src/host/`, `tests/mojo/host/`, `tests/run/` (Python end-to-end tests), and
the new functions of `spectest/_host/module.mojo` and `scripts/build_host.py` (the bridge
package has landed, and this package extends its module).

**Read first:** `docs/language.md` (Clauses, Verdicts: the rules this package
enforces), `docs/v2/host-api.md` (the API to implement), `docs/v2/protocol.md`, and
the landed packages: `src/specfile` (`check_source`, `Spec`), `src/partition`
(`compile_partitions`), `src/host/draw` (`draw_args`, `draw_in_classes`, `domain_size`,
`value_at`, `Builder`), `src/mcheck` (`search`, `enumerate_all`, `Store`),
`src/interpreter` (`EvalHost`, `Env`, `judge`, `explain`, `class_holds`, `snapshot_olds`,
`observe_with`), `spectest/_host` (`DriverClient`, `to_python`, `from_python`),
`src/value` (`format_value`). Also `docs/v2/mojo.md`. v1 is the reference for every
verdict rule: `spectest/runtime/runner.py`, `plans.py`, `binding.py`,
`context.py`, `stateful.py` (the parts for functions), and `tests/runtime/`.

## Deliver

1. **Loading.** `load(path) -> Loaded`: parse, check, compile partitions. The
   `Loaded` value keeps the spec, its set context, the partition sets and a hash of the
   source.
2. **Typed reading.** `decode(value, t, types) raises -> Value` reads a value the
   driver returned against its declared type, as v1's binding did:
   - `None` is an option's none, and a present option is wrapped;
   - records come from `Record` or from a map with exactly the fields;
   - enums and string-literal unions come from `Enum` or from strings;
   - fixed-width integers are range-checked;
   - a Python float (`Float` f64) for an `f32`, `f16` or `bf16` result is accepted
     when exact in that format;
   - a handle's class is checked against its model where the class is known.
   A value that doesn't fit is a `#type` failure. `encode` prepares arguments,
   unwrapping options.
3. **The host for the evaluator.** `EvalHost` over `DriverClient`:
   - observers read the attribute, or evaluate the observer's expression through
     `observe_with`, with `call_extern` resolving the callable through the driver;
   - planned calls apply `requires` to their inputs (a planned input outside it makes
     the clause skip), make identical calls once per example, and run their raises
     through the clause-skip rule;
   - constants come through `driver.get`;
   - identity questions use handle ids.
4. **Running a declaration.** `run(mut loaded, decl, options, mut driver) -> RunResult`
   runs one mcheck search whose properties are all of the declaration's clauses plus
   `#type` and `#raises`. Each example:
   - draw the arguments, steered by partition classes (predicate classes through
     `class_holds`, retrying a few times);
   - apply `requires`;
   - snapshot `old`;
   - call through the driver: the receiver first for methods, resolving targets once
     per run;
   - judge every clause by the verdict table and soundness rules of `docs/language.md`:
     `ensures` when the call returned; `raises` and `may_raise` (keep v1's runtime
     behavior where both apply, an open question); `#raises`; `#type`; `modifies` by
     a digest of the observers of unlisted handle parameters; `relates` with planned
     calls; invariants of model results; raise-due skips with their note line.
     Evaluation errors are spec errors.
   Each failing clause is shrunk on its own. Small domains run exhaustively
   (`domain_size`, `enumerate_all`). Explicit `examples` are judged first. Failures
   are stored by spec hash and clause id, and replayed first. Aggregate clauses are
   judged in the same run, as v1 does, sampling large sets.
5. **Results** in the shape of `docs/v2/host-api.md`: counts, skips by cause,
   coverage by partition class, and the counterexample (inputs and observation
   through `format_value`, partitions, explanation through `explain`, seed and a
   reproduce string).
6. **The Python API** of `docs/v2/host-api.md` in `spectest/_host/module.mojo`: `load`,
   `items`, `run`, `unload`.

## What wave 2b settled

- `src/interpreter/api.mojo` is the evaluator's surface:
  - `evaluate` and `judge(spec, clause_pos, env, mut host) -> Judgment`, where
    `clause_pos` is a position in `Spec.clauses` and a Judgment has a kind, a message
    and a node;
  - `snapshot_olds(..., mut env)`, which writes into the env;
  - `observe_with`, `explain` (with a default limit of 16) and `class_holds`.
  `EvalHost` is in `src/interpreter/host.mojo`. Its parameters are named `fn_pos` and
  `const_pos`, because `fn` is reserved in Mojo.
- `src/interpreter/coerce.mojo` has `coerce_arg`, which checks that an argument is exactly
  representable in its parameter's type. Use it for planned calls and for explicit
  examples.
- Aggregate bookkeeping is this package's job. The evaluator judges an aggregate
  clause as one expression, and a comprehension over a partition set stops above
  65,536 members. Port v1's `evaluate_aggregate`: terms, worst-term ranking, the
  skipped-term counts, and sampling of large sets.
- Mojo builds of large test files are slow, about 40 s each cold for the evaluator's.
  Group the runner's Mojo tests into a few files, and put most end-to-end coverage
  in the Python tests under `tests/run/`.

## Acceptance

`uv run pytest tests/mojo/host tests/run` passes. End-to-end tests in `tests/run/` use
small specs written for them in v2 syntax (qualified names), Python implementations
beside them, and the real `spectest.driver.Driver`. They cover:

- a correct implementation passing every clause;
- seeded bugs, each failing the right clause with a shrunk counterexample;
- `requires` filtering;
- `raises`, `may_raise`, `#raises` and `#type` failures;
- `modifies` catching a mutated parameter;
- `relates` with planned calls, including a planned call that raises (skip);
- `old`;
- a model built through `build` with observers;
- partition coverage counts;
- an exhaustive run of an f16 function;
- an aggregate clause;
- the failure store replaying a failure on the next run;
- `math.cos` against a v2 spec modeled on `examples/libm/libm.spec`.

Speed: measure the host's overhead per example on a trivial function (10,000
examples) and print microseconds per example. The target is 50 µs; report what you
get.

## Out of scope

Interfaces (stateful runs, wave 3b), user prelude files, the pytest plugin (built at
the same time against a fake of this API), Markdown rendering (the plugin reuses v1's).
