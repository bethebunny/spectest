# spectest v1 implementation plan

v1 is a Python host shipped as a pytest plugin. It parses and checks spec files
written in the language of `docs/language.md`, binds them to Python
implementations in-process, generates inputs with Hypothesis (and bitpattern
for fixed-width scalars), evaluates clauses, and reports verdicts with
minimized counterexamples. It is done when the five use cases in `examples/`
run end to end: every real implementation passes (or fails for a reason we can
show is real), and every seeded bug fails with a counterexample that names the
right clause.

Sources of truth, in order: `docs/language.md` (semantics), the contract
modules `src/spectest/{ast,types,values}.py` (data shapes), this plan
(module boundaries). Change a contract module only by adding to it; if a
change is unavoidable, note it in `docs/CHANGES.md` with the reason.

Conventions: Python 3.13 via `uv` (`uv run pytest`, `uv run ruff check`).
Type hints everywhere, short docstrings, no comments that narrate. Docs and
messages describe the language and the tool only. Tests live in `tests/<area>/`.
Commit small and often, with jj. Each worker runs in its own jj workspace and commits
there as it goes; finished work goes to one merge queue that owns `main`, rebases each
submission onto it, runs the checks and lands submissions one at a time. A lone worker whose
change is still a child of `main` may move `main` to it directly.

## Package layout

```
src/spectest/
  __init__.py        public API: load, conformance, Conformance, ConformanceError, ModelBinding,
                     InterfaceBinding, Unrepresentable, NotAValue
  ast.py types.py values.py            contracts (given)
  lang/
    lexer.py         tokens and the layout rule (INDENT, DEDENT, continuation lines)
    parser.py        parse(source, path) -> ast.SpecFile
    checker.py       check(SpecFile) -> Spec: names, types, clause IDs, static rules
    signatures.py    static typing rules for every prelude name
    errors.py        SpecSyntaxError, SpecCheckError (with spans and source excerpts)
    loader.py        load(path), load_source(source, path) -> Spec (parse, `use`, check, partition sets)
  prelude/
    __init__.py      PRELUDE registry and call()
    floats.py        bits <-> value, classification, next_up/down, ulp, qe / steps / nans, round<T>,
                     same, ieee_eq, format_float
    reals.py         extended-real arithmetic and comparison; promotion of ints and floats
    mp.py            MPFR (gmpy2) references at 256 bits, returning exact Fractions
    cr.py            correctly rounded cr.sqrt ... cr.atan in each float format (MPFR)
    ints.py          wrap, fits, T.min / T.max, le_uint
    collections.py   len, sorted, is_sorted, is_permutation, is_subsequence, distinct,
                     index_of, keys, values, range, options, valid_utf8, codepoints, eq,
                     identity (fresh, same_object, shares_memory)
  eval.py            evaluate(expr, env, spec, ctx); Env; EvalContext protocol
  sets.py            partition set expressions -> bitpattern BDDSet; disjoint/cover checks
  generate.py        Hypothesis strategies from types, partitions and models; exhaustive domains
  shrink.py          the deterministic pass after Hypothesis's shrinking: shorter, simpler inputs
  runtime/
    binding.py       Conformance, ModelBinding, InterfaceBinding; value conversion to and from Python
    plans.py         per-call plans: requires, old() snapshots, digests, call, outcome, clause verdicts
    runner.py        run one (function x clause) with Hypothesis or exhaustively; tallies; counterexamples
    stateful.py      a Hypothesis RuleBasedStateMachine per interface
    store.py         counterexample store under .spectest/, replayed first as explicit examples
    report.py        Report model; text, markdown and JSON rendering
  pytest_plugin.py   collect Conformance objects, options, profiles, failure display, reports
                     (merged from pytest-xdist workers)
  cli.py             `spectest check FILE.spec`, `spectest report ...`
```

## Contracts between modules

### lang

```python
def parse(source: str, path: str = "<string>") -> ast.SpecFile      # SpecSyntaxError
def check(file: ast.SpecFile, uses: list[Spec] = ()) -> Spec          # SpecCheckError (all errors at once)
def load(path: str | Path) -> Spec
def load_source(source: str, path: str = "<string>", base: str | Path | None = None) -> Spec

@dataclass
class Spec:
    name: str; path: str; source: str
    hash: str                                   # sha256 of the source text (and used specs')
    fns: dict[str, ast.FnDecl]
    models: dict[str, ast.ModelDecl]
    interfaces: dict[str, ast.InterfaceDecl]
    errors: set[str]
    enums: dict[str, EnumT]; records: dict[str, RecordT]; aliases: dict[str, Type]
    signature: dict[ast.Node, FnT]              # FnDecl / CtorDecl / MethodDecl / Observe -> signature
    tparams: dict[ast.Node, dict[str, TypeVarT]]
    resolution: dict[ast.Node, Resolution]      # every Name, Call, Attribute the evaluator must interpret
    clause_ids: dict[str, ast.Clause]           # "cos.accurate", "Deque.pop.items", "Frame.unique_columns"
    file: ast.SpecFile
    owner: dict[ast.Node, ast.Node]             # clause / member -> its declaration
    decl_ids: dict[ast.Node, str]               # "cos", "Frame", "Deque.pop": prefixes of clause IDs
    uses: list[Spec]; warnings: list[Diagnostic]
    def resolve_type(self, texpr, tvars: dict[str, TypeVarT] | None = None) -> Type
    def decl(self, name) -> ast.Node | None; def observers(self, model) -> dict[str, ast.Observe]
    def fields(self, model) -> list[ast.Observe]   # zero-argument observers, in declaration order
```

`Resolution` is a small frozen dataclass `(kind, name, detail)`. Kinds:
`param`, `result`, `self`, `local` (let / comprehension variable),
`field` (a bare model or interface field inside its own invariants),
`prelude` (a prelude function or constant), `type_const` (`i32.max`,
`f64.nan`: detail is the scalar type), `set_ctor` (`f64.range`, `f64.pattern`),
`spec_fn` (a call to a spec function: only legal in `relates` and `aggregate`),
`observer` (`df.rows`, `df.cell(i, n)`: detail is the model name),
`record_field`, `old`, `error`, `class` (an earlier partition class) and
`enum_member` (`spectest.lang.RESOLUTION_KINDS`).

Static rules the checker enforces (each with a span and a clear message):
the equality rule; ordering only on ordered types; `result` only where a
result exists; `old` only in `ensures` of a callable with handle parameters or
`self`, and not over a variable bound elsewhere in the clause; spec-function
calls only in `relates` and `aggregate`; `aggregate` only in a `fn`, in one of
its bound shapes, without the function's parameters, `result` or `old`;
observers exist and arity matches; errors are declared; type-parameter bounds
are respected; partition classes are sets for fixed-width parameters (and
predicates otherwise); clause labels unique per declaration, and a model's or
interface's clause label is not the name of one of its members (the ID would
name the member); `modifies` names handle parameters or `self`; no clause
observes a declared freedom.

### prelude

```python
@dataclass(frozen=True)
class PreludeFn:
    name: str                     # "len", "mp.cos", "qe", "wrap", ...
    impl: Callable[..., Any]      # impl(*args, **kwargs) on runtime values
    needs_ctx: bool = False       # fresh, same_object, shares_memory, eq (model observation)
    needs_types: bool = False     # wrap/fits/round/ulp/qe: receives type_args=..., arg_types=...

PRELUDE: dict[str, PreludeFn]
def call(name, args, *, kwargs=None, type_args=(), arg_types=(), ctx=None) -> Any
```

All functions are total over well-typed inputs or raise `EvalError` with a
message that names the function and the offending value. None delegates to
the host's implementation of what it defines (`sorted` is a merge sort,
`valid_utf8` follows Unicode Table 3-7), so a spec can judge that
implementation.

### eval

```python
class EvalContext(Protocol):                     # in full under Pinned APIs
    def observe(self, handle: Handle, observer: str, args: tuple) -> Any
    def call_spec_fn(self, name: str, args: tuple) -> Any        # planned call; may raise SkipClause
    def is_fresh(self, handle: Handle) -> bool
    def same_object(self, a: Handle, b: Handle) -> bool
    def shares_memory(self, a: Handle, b: Handle) -> bool
    ...                                          # fields, members

@dataclass
class Env:
    values: dict[str, Any]                       # params, result, self, locals
    olds: dict[ast.Call, Any]                    # pre-state values of old(...) calls (or EvalError)
    fields: Handle | None = None                 # the handle whose fields bare names refer to
    tenv: dict[str, Type] = {}                   # type variables -> concrete types

def evaluate(expr: ast.Expr, env: Env, spec: Spec, ctx: EvalContext) -> Any   # EvalError, SkipClause
def holds(clause: ast.Clause, env, spec, ctx) -> bool
def old_calls(expr, spec=None) -> list[ast.Call] # for the planner to snapshot before the call
```

### sets and generate

```python
def compile_set(expr: ast.Expr, elem: Type, classes=None, *, aliases=None) -> BDDSet
def check_partitions(spec: Spec) -> list[Diagnostic]        # disjoint, covers domain or requires-set
def classify(value, classes) -> str | None                   # partition class of a value
def partition_strategy(classes, elem=None, *, label=None) -> SearchStrategy   # class first, then member

# generate: strategy, args_strategy (partition-uniform when partitions exist), model_strategy,
# residual_invariants, partitions, exhaustive_inputs; signatures under Pinned APIs
```

### runtime and plugin (public API)

```python
spec = spectest.load("libm.spec")             # relative to the calling test module
test_math = spectest.conformance(
    spec,
    impls={"cos": math.cos, "sqrt": math.sqrt},
    errors={ValueError: "DomainError"},
    scalars="python",                         # or "numpy": f16/f32/f64 as numpy scalars
    instantiate={"T": "i64"},                 # or a list of dicts for several instantiations
    models={"Frame": ModelBinding(observers=..., concretize=...)},
    interfaces={"Deque": InterfaceBinding(constructors=..., methods=...)},
    expect_fail={"cos.accurate"},             # seeded bugs: these clauses must fail (strict xfail)
    max_examples=200,
    sizes=generate.Sizes(max_list=16),        # bounds on generated collections
    examples={"cos": [{"x": 0.5}]},           # explicit inputs, judged before the search
    steps=30, max_handles=2,                  # per interface step sequence: calls, live handles
)
```

Module-level `Conformance` objects whose names start with `test` become pytest
items, one per (function, instantiation, clause) and one per (interface,
instantiation): for example `test_libm.py::test_math::cos.accurate` and
`test_deque.py::test_collections_deque::Deque[T=i64]`. Exhaustive mode applies
when a function's input domain has at most `--spectest-exhaustive-limit`
(65,536) values. A failing item prints the counterexample: clause ID and text,
inputs, observation, partition, seed, and the reproduction command.

**Clause names.** Every clause result prints under one name: its clause ID with
the instantiation after the declaration's name, with no spaces. For a function
item this is the last part of the node ID (`sort_by_first[K=i64,V=string].stable`,
`first[T=i64]#type`, `wrap[T=i64]:Box.nonneg`); an interface item's clauses
extend the item's name (`Deque[T=i64].pop#1`). Failure headers, the "spectest"
terminal summary, xfail reasons, the strict XPASS message and the report all
use it; the report's headings and coverage rows prefix the conformance
(`test_numpy::cos.accurate`), or the whole item path when two files' conformances
share a name.

**Selecting clauses.** `pytest -k` cannot take `#`, so `--spectest-clause=GLOB[,GLOB...]`
(repeatable) runs only the clauses whose name or ID matches a glob, where `*` and
`?` are the only wildcards and brackets are literal: `--spectest-clause='cos#*'`,
`--spectest-clause='sort[T=string]*,*.stable'`. Function items that do not match
are deselected. An interface item runs when one of its clauses matches and
reports only those clauses; its state machine still judges every clause at every
step, so the selected clauses get the verdicts of a full run. Other tests are not
affected (add `-m spectest` to run spectest items only). Node IDs also work as
usual: `pytest 'test_libm.py::test_math::cos#raises'`.

**Expected failures.** A clause in `expect_fail` is a strict xfail; an interface
item is an unexpected pass when any of its expected clauses never failed. Under
`pytest --runxfail` it is reported as if it were not listed: a failure shows its
counterexample as a normal failure, and an expected failure that did not fail
passes.

**The report.** `--spectest-report=PATH.md` writes one section per spec:
- facts: the spec, its hash, spectest's and Hypothesis's versions, the platform
  (Python implementation and version, OS, `platform.machine()`), and the versions
  of numpy, pandas, polars, gmpy2 and ml_dtypes when imported, and of any
  installed package a bound implementation, constructor, method or observer
  comes from;
- "Items" counts pytest items per outcome, as pytest tallied them (spec errors
  and unexpected passes are pytest failures, inconclusive items are skips);
  "Clause results" counts clause results, which differ for interface items;
- a Results table with one row per clause result: item, clause name, kind, mode,
  verdict, verdict counts and time. The skip count is broken down by cause where
  it is known: `requires` (false), `raised` (the call raised), `raise due` (an
  error was due, so the clause did not apply), `wrong type`, `unrepresentable`
  (the binding could not build the input), `rejected` (a generated model broke a
  model invariant) and `planned call`. A mode of "hypothesis, replayed" marks an
  item that replayed a stored counterexample instead of searching, so its counts
  come from that replay;
- coverage per partition class, counting only the examples each clause judged
  (pass or fail), so a class with 0 examples was never exercised by that clause;
  replayed rows are marked;
- every counterexample, including those of expected failures.

Counterexample observations name the error an exception maps to
(`raised ValueError: math domain error (maps to DomainError)`), state a
`#type` mismatch once (`returned int 256, which is not u8 (outside the u8 range
0..255)`), and show the state after the call of each handle the function may
modify (`xs after = MutableList { items: [0, -2] } (unchanged)`, judged by
digest), in place of a unit result. Strings and bytes print with one escape
scheme: `\"`, `\\`, `\n`, `\t`, `\r`, `\xHH` for other control characters
(NUL is `\x00`) and, in strings, `\u{H..}` for non-printable code points and
U+FFFD; bytes from 0x80 print as `\xHH`.

## Phases

1. **Core in parallel.** Four builders: `lang`, `prelude`, `sets` + `generate`,
   `eval`. Each owns its files and writes unit tests. The front end must parse
   and check every file in `examples/`.
2. **Runtime and plugin.** One builder wires everything into
   `runtime/`, `pytest_plugin.py` and `cli.py`, and gets `examples/libm` running
   end to end as the thin slice.
3. **Use cases in parallel.** One builder per directory in `examples/`: real
   implementations, bindings, seeded bugs, `test_<case>.py`. They change only
   their own directory and file core bugs in `docs/ISSUES.md`.
4. **Core fixes.** One builder resolves `docs/ISSUES.md`; phase 3 reruns.
5. **Verification.** Independent reviewers check soundness of the
   implementation against `docs/language.md`, re-derive each example spec's
   correctness, and run the full suite. The demo report goes to
   `docs/DEMO.md`.

## Pinned APIs (phases 1b and 2)

Phase 1a shipped `spectest.lang`, `spectest.prelude` and `spectest.sets`; their
reports are in the build notes. The following names are pinned so that
`eval`, `generate`, `runtime` and the plugin can be built in parallel.

### spectest.eval

```python
class EvalContext(Protocol):
    def observe(self, handle: Handle, observer: str, args: tuple) -> Any
    def fields(self, handle: Handle) -> dict[str, Any]       # all zero-arg observers, for eq()
    def call_spec_fn(self, name: str, args: tuple) -> Any     # planned call; may raise SkipClause
    def is_fresh(self, handle: Handle) -> bool
    def same_object(self, a: Handle, b: Handle) -> bool
    def shares_memory(self, a: Handle, b: Handle) -> bool

@dataclass
class Env:
    values: dict[str, Any]                       # params, "result", "self", locals
    olds: dict[ast.Call, Any] = {}               # value or EvalError per old(...) call
    fields: Handle | None = None                 # the handle bare field names refer to
    tenv: dict[str, Type] = {}                   # type variables -> concrete types

evaluate(expr, env, spec, ctx) -> Any            # raises EvalError or SkipClause only
holds(clause, env, spec, ctx) -> bool
old_calls(expr, spec=None) -> list[ast.Call]
snapshot_olds(clauses, env, spec, ctx) -> dict[ast.Call, Any]   # evaluated on pre-state
explain(expr, env, spec, ctx, *, limit=16) -> list[tuple[str, str]]   # (sub-expression text, value)
default_value(param: ast.Param, spec) -> Any
coerce_arg(value, t: Type, what="argument") -> Any   # to a fixed-width param type; EvalError if inexact
format_value(value, t: Type | None = None) -> str
```

### spectest.generate

```python
DEFAULT                                          # sentinel: omit this argument (use its default)
@dataclass class Sizes: max_list=8, max_inner=4, max_text=12, max_bytes=16,
    long_list=100, long_text=100, long_bytes=100, long_share=1/16   # a share of long top-level values
@dataclass(eq=False) class GeneratedModel: model: str; targs: tuple[Type, ...]; fields: dict[str, Any]
strategy(t, spec, tenv=None, sizes=Sizes()) -> SearchStrategy
args_strategy(decl, spec, tenv=None, sizes=Sizes(), *, defaults=True, examples=()) -> SearchStrategy[dict[str, Any]]
field_plans(model, spec, sizes=Sizes()) -> list[FieldPlan]       # computed, unique, length_of per field
computed_fields(plans, values, *, missing_only=False) -> dict     # fields an invariant computes, filled in
broken_invariants(gm, spec) -> list[str]; invariants_hold(gm, spec) -> bool
model_strategy(model, targs, spec, sizes=Sizes()) -> SearchStrategy[GeneratedModel]
residual_invariants(model, spec, sizes=Sizes()) -> list[ast.Clause]   # not enforced by construction
@dataclass class PartitionInfo: param: str; kind: "set" | "predicate"; classes: list[tuple[str, Any]]
partitions(decl, spec, tenv=None) -> list[PartitionInfo]
exhaustive_inputs(decl, spec, tenv=None, limit=65536) -> tuple[int, Iterator[dict[str, Any]]] | None
```

### spectest.runtime (infrastructure)

```python
# binding.py
@dataclass class ModelBinding: observers: dict[str, Callable]; concretize: Callable[[dict], Any] | None = None;
    digest: Callable[[Any], Hashable] | None = None; shares_memory: Callable[[Any, Any], bool] | None = None;
    accepts: Callable[[Any], bool] | None = None      # False (or NotAValue): not a value of the model
    lossy: bool = False                               # concretized objects need not observe as generated
@dataclass class InterfaceBinding: constructors: dict[str, Callable]; methods: dict[str, Callable] | None = None;
    observers: dict[str, Callable] | None = None; digest: Callable[[Any], Hashable] | None = None
@dataclass class Conformance: spec, impls, errors, scalars, instantiate, models, interfaces,
    expect_fail, max_examples, exhaustive_limit, steps, max_handles, sizes, examples,
    name (set by the plugin), path
conformance(spec: Spec | str, **options) -> Conformance  # a str path resolves against the caller's file
class TypeMismatch(Exception)                            # a result is not of its declared type: <fn>#type fails
class ValueRefused(BindingError): handle                 # an observer raised values.NotAValue on handle
to_python(value, t, conf) -> Any                         # spec value -> implementation argument
from_python(obj, t, conf, *, created_by=None) -> Any     # implementation value -> spec value; TypeMismatch
                                                         # (also for a model object accepts refuses)
concretize(gm: GeneratedModel, conf, spec, *, created_by=None) -> Handle
                                                         # Unrepresentable or BindingError; BindingError also
                                                         # when the object does not observe as gm (not lossy)
observe(handle, observer, args, conf, spec) -> Any       # BindingError when the observer fails (ValueRefused
                                                         # for NotAValue); #type fails on a refused result
fields(handle, conf, spec) -> dict[str, Any]
digest(handle, conf, spec) -> Hashable
map_exception(exc, conf) -> str | None                   # spec error name for an implementation exception
# store.py
encode_value(v, t) -> JSON; decode_value(obj, t) -> value
class CounterexampleStore(root=".spectest"): load(spec_hash, item_id) -> list[dict]; save(spec_hash, item_id, inputs)
# report.py
Verdict = "pass" | "fail" | "skip" | "spec_error" | "inconclusive"
@dataclass class Counterexample: inputs: dict[str, str]; observation: str; partitions: dict[str, str];
    explanation: list[tuple[str, str]]; seed: int | None; reproduce: str
@dataclass class ClauseResult: item_id, clause_id, clause_text, kind, decl, instantiation, mode,
    counts: dict[Verdict, int], coverage: dict[str, int], counterexample: Counterexample | None,
    failing_inputs: int, spec_errors: list[str], expected_fail: bool, duration: float,
    replayed: bool = False, skips: dict[str, int] = {}     # skips by cause: SKIP_CAUSES keys
    label -> "sort[T=i64].ordered"; conformance -> "test_numpy"; qualified -> "test_numpy::cos.accurate"
@dataclass class Report: spec_name, spec_hash, harness_version, hypothesis_version, results: list[ClauseResult],
    items: dict[str, str] = {}                           # pytest item ID -> outcome
    platform: dict[str, str] = {}; packages: dict[str, str] = {}
clause_name(clause_id, instantiation) -> str             # "Deque[T=i64].pop#1"
render_failure(result) -> str; render_markdown(report) -> str; Report.to_json() / Report.from_json()
```

### Quantized error and aggregates (added after review)

`ulp_error` is replaced by `qe` (see docs/language.md). New pinned names:

```python
# spectest.types
@dataclass(frozen=True) class QErrT(Type)                # "qerr"; canonical equality; componentwise order
QERR = QErrT()
# spectest.values
@dataclass(frozen=True) class QError: steps: int; nans: int   # k + m·nan; __add__; ordering helpers; str "3", "1nan", "3 + 1nan"
# spectest.ast: CLAUSE_KINDS gains "aggregate"; Comprehension.kind gains "max"
# spectest.prelude: "qe", "steps", "nans", "cr.sqrt", "cr.exp", "cr.log", "cr.sin", "cr.cos", "cr.tan", "cr.atan"
# spectest.eval
class EvalContext(Protocol):
    ...
    def members(self, s: BDDSet, elem: Type) -> tuple[Iterable[Any], bool]   # (members to visit, sampled?)
@dataclass
class AggregateResult:
    holds: bool; value: Any; bound: Any
    evaluated: int; skipped: int; total: int; sampled: bool
    worst: list[tuple[Any, Any]]                 # (member, term), largest terms first, at most 20
evaluate_aggregate(clause, spec, ctx) -> AggregateResult
```

An `aggregate` clause sits in a function's body, may not mention the
function's parameters, `result` or `old`, and has one of the shapes
`sum(v in S: e) <= c` / `< c` / `== 0`, `max(v in S: e) <= c` / `< c`, or
`all(v in S: p)`, where S is a set expression or a list and c is a constant.
The runtime evaluates it once per conformance and instantiation: exhaustively
when the set has at most `exhaustive_limit` members, otherwise on a seeded
sample (`ctx.members` decides). A term whose planned call fails `requires` or
raises is skipped and counted; a negative int term is a spec error.

### Model values and text (phase 4)

```python
# spectest.values
class NotAValue(Exception)       # a binding refuses an object: not a value of the model
# spectest.prelude: "codepoints" (string -> list<int>)
```

A model result is judged by `<fn>#type`: it must read as a handle, the
binding's `accepts` must take it, and every field must observe without an
observer raising NotAValue; the clauses that reach a refused result skip. A
refusal of any other object (an input, an observer's result) is a binding
failure. `concretize` reads each built object back: unless the binding is
`lossy`, a field that does not observe as generated is a BindingError, and a
lossy binding's counterexamples show the input as built.
