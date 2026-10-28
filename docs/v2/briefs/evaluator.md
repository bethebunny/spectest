# Brief: evaluator

Evaluates checked expressions and clauses on `Value`s: the host's operators, prelude
calls, definitions, and, through a host interface, observers, constants, planned
calls and identity questions.

**Owns:** `src/interpreter/`, `tests/mojo/interpreter/`.

**Read first:** `docs/language.md` (Types and values, Clauses, Expressions, Verdicts),
`docs/v2/syntax.md`, `src/spec/spec.mojo` (resolutions by node, types by node),
`src/specfile/` (`check_source`), `src/prelude/api.mojo` (`call`, `CallArgs`),
`src/value/` (equalities, order, `format_value`), `src/value/` (BigInt, Real,
float conversions, literals), `src/partition/` (`compile_set` for set expressions
in clauses), `docs/v2/mojo.md`. v1 is the reference: `spectest/eval.py` and
`tests/eval/`.

## Deliver

1. **The host interface**, which the runner implements and tests mock:

   ```mojo
   trait EvalHost:
       def observe(mut self, obj: Value, model: Int, observer: Int, args: List[Value]) raises -> Value
       def call_fn(mut self, fn: Int, args: List[Value]) raises -> Value      # a planned call
       def constant(mut self, const: Int) raises -> Value                    # a declared constant
       def fresh(mut self, obj: Value) raises -> Bool
       def same_object(mut self, a: Value, b: Value) raises -> Bool
       def shares_memory(mut self, a: Value, b: Value) raises -> Bool
       def call_extern(mut self, name: String, args: List[Value]) raises -> Value  # R_EXTERN
   ```

   `call_extern` serves an observer's reading expression that calls a callable the
   spec doesn't declare (`observe members: list<int> = builtins.list(self)`, resolved
   as `R_EXTERN`). `observe_with(spec, model, observer, obj, args, mut host)`
   evaluates such an expression with `self` bound to `obj`.

   A planned call that raises in the library returns an ERROR Value; the evaluator
   turns that into a skip of the clause, as the language says.
2. **Environment.** `Env` holds the parameters' values, `result`, `self`, the values of
   `old(...)` taken before the call, and the type substitution of a generic
   function's instantiation. `snapshot_olds(spec, clauses, env, mut host)` evaluates
   every `old(e)` of the given clauses on the state before the call.
3. **Evaluation.** `evaluate(spec, node, env, mut host) -> Value` for every expression
   form, as language.md and v1 define them:
   - exact arithmetic (fixed widths promote to `int`, floats to `real`, promoting a
     NaN is an error); unary minus on a float flips its sign and keeps its type;
     floored `//` and `%`; `**`, `<<`, `>>`, and `&` and `|` on integers;
   - comparisons by the language's order; `==`, `!=` and `in` by canonical equality;
     `in` over lists, map keys and partition sets; `+` concatenating lists, strings and
     bytes, and adding qerrs;
   - `and`, `or`, `implies`, `if` evaluating left to right and short-circuiting;
     `let`; comprehensions, including over `range(a, b)` and partition sets;
   - indexing and slices, with errors out of range; tuple fields; record fields; qerr
     parts; enum members; type constants (`T.min`, `T.max`, the named sets) and set
     constructors;
   - calls: prelude functions through `prelude.call` with argument types and type
     arguments filled in; the identity functions through the host; definitions,
     evaluated with their parameters bound; planned calls through the host, with
     each argument checked exactly representable in its parameter's type; observers
     through the host.
4. **Judging.** `judge(spec, clause, env, mut host) -> Judgment`, where `Judgment` is
   one of: true, false, an evaluation error (message and node), or a skip (cause).
   An evaluation error is a spec error, except where the runner says a raise was due.
   Leave that distinction to the runner and report the error. `raises` and `may_raise`
   judge their `when` condition.
5. **Explanation.** `explain(spec, clause, env, mut host, limit) -> List[(String,
   String)]`: source text and value text of the subexpressions of a failing clause,
   as v1's `explain` gives them for reports.
6. **Predicate classes.** `class_holds(spec, class_node, value, mut host) -> Bool`, so
   generation can steer by predicate classes.

## What wave 2a settled

- `check_source(source, path) -> Spec` is in `specfile/checker.mojo`. For a function
  with a receiver, `Fn.params[0]` is `self`: `R_PARAM` indices count from it, and
  `self` itself resolves as `R_SELF`.
- `prelude.api.call(id, CallArgs, types)` evaluates the prelude, except the identity
  functions. Its list functions compare elements with `same`, so an INT and a REAL of
  equal value differ there. Keep values of static type `real` as REAL Values even
  when they are whole (a `list<real>` literal `[1, 0.5]` holds two REALs).
- `eq` on values containing handles raises in the prelude. Compare models through
  their fields, read with the host (v1's `ctx.fields`), and call `eq` on those.
- `partitions.compile.compile_set_aliased(ctx, ast, types, elem_type, node, classes,
  aliases)` compiles a set expression in a clause, such as `T.range(a, b)`. The
  partition sets of a spec come from `partitions.check.compile_partitions(ctx, spec)`.
- For tests, `partitions.testing.build_spec` and `check.testkit` show how specs get
  built.

## Acceptance

`uv run pytest tests/mojo/interpreter` passes, covering:

- v1's evaluator tests (`tests/eval/`), ported, with specs checked by
  `check_source` and a mock host;
- every operator on every type it accepts, and the errors (division by zero, index
  out of range, missing key, NaN promotion, empty `max`, an inexact argument to a
  fixed-width parameter);
- short-circuiting protecting a guarded error;
- planned calls and observers going through the mock host, a planned call's library
  error making the clause skip, and `old` reading the state before;
- definitions, including one calling another;
- speed: judging the clauses of `libm.spec`'s `cos` on one input takes under 20 µs
  (print it). This is the evaluator's share of the 50 µs budget per example.

## Out of scope

Generating inputs, calling the library, the verdict rules that combine clauses
(`#raises`, raise-due skips): those are the runner's, in wave 3.
