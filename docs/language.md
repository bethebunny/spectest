# spectest spec language — v1

This is the repo copy of the language definition. The review copy is the doc
"spectest spec language — v1 draft" (https://claude.ai/artifact/1Fqu1m3CTGrSA5ebM7GJXw);
when they disagree, fix both.

A spec file declares a component's API (its types, abstract models, functions
and stateful interfaces) and attaches clauses: pure conditions over inputs and
observed behavior. spectest judges an implementation by generating inputs,
calling it through a binding, observing the results and evaluating the
clauses. A clause can fail only for a reason the spec states.

## Overview

```
spec libm

fn cos(x: f64) -> f64
  partition x
    nan       = f64.nan
    inf       = f64.inf
    zero      = f64.zero
    subnormal = f64.subnormal
    small     = f64.range(-0x1p-26, 0x1p-26) & f64.normal
    moderate  = f64.range(-0x1p20, 0x1p20) & f64.normal - small
    huge      = f64.normal - small - moderate
  ensures accurate: qe(result, cr.cos(x)) <= 1
  ensures bounded: is_finite(x) implies is_finite(result) and -1 <= result and result <= 1
  relates even: not is_nan(x) implies same(cos(-x), result)
  impl_defined nan_payload
```

- `partition x` splits the input domain into named classes. They are
  bitpattern sets, so the checker proves they are disjoint and cover every
  `f64`, and generation draws a class first, then a member: −0 is as likely
  as a normal float.
- `accurate` bounds the quantized error between the result and `cr.cos(x)`,
  the correctly rounded cosine in `f64`. `qe` counts the floats between two
  values, so it is an integer, symmetric and defined for every input: two
  NaNs are 0 apart, and a NaN against a number is one NaN error, tracked
  separately. The clause therefore also demands NaN for infinite and NaN
  inputs.
- `bounded` needs its guard: promoting NaN to a real number is an evaluation
  error, which would make the clause a spec error rather than a failure.
- `even` is a metamorphic relation. `cos(-x)` inside it is a second, planned
  call to the implementation, and `same` is bit-identical equality, named
  explicitly because floats have no implicit `==`.
- `impl_defined nan_payload` records a freedom: no clause may observe the
  payload of a NaN result.

## Types and values

Every value has a static type, checked before any test runs.

| Type | Values | Canonical `==` |
| --- | --- | --- |
| `bool`, `string`, `bytes` | Booleans; Unicode scalar sequences (no normalization implied); byte strings | Yes |
| `int` | Unbounded integers | Yes |
| `i8` … `i64`, `u8` … `u64` | Two's-complement and unsigned fixed-width integers | Yes |
| `f16`, `bf16`, `f32`, `f64` | IEEE 754 values, bit-exact: −0 and NaN payloads are kept | No |
| `real` | Extended reals: exact rationals plus ±∞. Clause-only, never a parameter | Yes |
| `qerr` | Quantized errors k + m·nan from `qe`, with whole k, m ≥ 0. Ordered componentwise, so `qe(a, b) < 1` means no step and no NaN error; a number c means c + 0·nan | Yes |
| `list<T>`, `map<K, V>`, `(A, B)`, `option<T>` | Finite collections, tuples, optional values | If every component has it |
| `enum E { A, B }`, `"any" \| "all"`, `record R { f: T }` | Named variants, literal unions, records | If every field has it |
| `model M` | Handles to objects that stay inside the implementation, known only through observers | No |

Arithmetic and ordering are mathematical. Fixed-width integers promote to
`int` and floats to `real`, so `a + b` never overflows or rounds; returning to
a fixed width is explicit: `wrap<i32>(e)`, `fits<i32>(e)`, `round<f32>(e)`.
Promoting a NaN is an evaluation error.

Type parameters take a bound, `Eq` (canonical equality) or `Ord` (a total
order): `fn sort<T: Ord>(xs: list<T>) -> list<T>`. The test configuration
chooses the concrete instantiations, e.g. `T = i64` and `T = string`.

`Ord` is the order of `<`, `sorted` and `is_sorted`, and an implementation is
judged by it whatever its own language's order is:

- integers of every width and `real` by value, with −∞ and +∞ at the ends;
- `false < true`;
- strings by Unicode code point, which is the byte order of their UTF-8
  encodings (and not the UTF-16 code-unit order of Java or JavaScript, which
  puts U+10000 before U+E000);
- bytes by unsigned byte value;
- tuples and lists lexicographically, a proper prefix first.

No other type is `Ord`. Floats compare with `<` only by promotion to `real`;
`qerr` is ordered componentwise, which is partial; options, maps, enums,
literal unions, records and models have no order of their own.

## Declarations

A file starts with `spec <name>` and may `use "other.spec"`. Blocks are
indentation-based; a clause continues onto more-indented lines, and `#`
starts a comment.

```
error IndexError                          # an error variant; bindings map exceptions to it

model Frame                               # an abstract type, observed through a binding
  observe columns: list<string>
  observe nrows: u64
  observe cell(i: u64, name: string): option<f64>
  invariant unique_columns: distinct(columns)

fn dropna(df: Frame, how: "any" | "all" = "any") -> Frame
  ...clauses...

interface Queue<T: Eq>                    # a stateful object
  observe items: list<T>
  new empty() -> Queue
    ensures len(result.items) == 0
  method push(self, x: T)
    modifies self
    ensures self.items == old(self.items) + [x]
```

- **Observers** are pure queries the binding implements. Observation is lazy:
  a clause reads only the observers it names, and an observer must not change
  the object it reads. A binding may refuse an object as not a value of its
  model (see `<fn>#type` under Verdicts).
- **Interfaces** run as generated command sequences: constructors create a
  session's objects, methods are called in random orders, and invariants are
  checked after every call. A sequence makes at most `steps` calls (30 by
  default) and holds at most `max_handles` objects (2 by default), both options
  of the conformance: constructors run only while fewer objects are live, a
  method runs on the object used last at least half the time, and an argument
  declared as an integer is drawn from -4 to 4 (0 to 4 when unsigned) three
  times in four, so sequences reach states such as a full bounded queue.
  Shrinking minimizes both the inputs and the sequence, and lowers a
  constructor's integer argument together with the calls that fill the object
  it made.
  Partitions of constructor and method parameters tag coverage, a failing
  sequence is stored and replayed first on the next run, and with
  `expect_fail` every listed clause must fail, or the item is an unexpected
  pass.
- **Partitions** name disjoint classes of a parameter's values. For a
  fixed-width scalar, each class is a set expression: `T.nan`, `T.inf`,
  `T.zero`, `T.subnormal`, `T.normal`, `T.finite`, `T.positive`, `T.negative`
  (by sign bit, so they include zeros and NaNs), `T.range(a, b)`
  (half-open), `T.pattern("...")`, `{v, ...}`, combined with `|`, `&` and `-`.
  They compile to bitpattern sets. The checker proves them disjoint and
  requires their union to equal the domain that `requires` admits (or the
  whole type, when `requires` is not a set). Hypothesis draws a class, then a
  member through bitpattern, so it only ever sees valid candidates. A domain
  of at most 2^16 values may also run exhaustively. For other parameter
  types, classes are predicates, and they steer generation too: Hypothesis
  draws a class (or, as often as any one class, no class), then a value of
  it. A conjunct `len(p) <op> n` fixes the lengths drawn (`len(b) == 4` draws
  four bytes), and any other conjunct is met by drawing again, a few times at
  most, so each class gets about an equal share. Classes also tag coverage.

**Generating model values.** A model's zero-argument observers are its
fields. Generation draws them in declaration order and reads the invariants
as constraints: `distinct(f)` makes a list unique,
`all(x in f: len(x) == len(g))` fixes the length of each element, and
`f == e` computes `f` from earlier fields. Any other invariant filters. The
binding's concretizer then builds the object. When its library cannot
represent a value, the concretizer raises Unrepresentable and the example is
skipped, never failed: a pandas int64 column, for example, cannot hold a
missing cell without becoming a float64 or object column.

A built object must observe as the fields it was built from (floats bit for
bit, nested models by their fields); otherwise the binding is at fault, and
the example is a spec error that shows both. A binding that cannot keep every
field exactly declares itself lossy (`ModelBinding(lossy=True)`; pandas reads
a NaN cell as missing). Its objects are not checked, and a counterexample
shows each input as built next to the generated one.

**Sizes.** Generated lists have at most 8 elements (4 inside another
collection, and in a model field whose length other fields' elements take,
such as a frame's columns), strings 12 characters and bytes 16. A sixteenth
of the top-level values (parameters and model fields, not their elements) are
long instead: lists of 17 to 100 flat elements (scalars, and tuples, options
and records of them), strings of 25 to 100 characters and bytes of 33 to 100,
so an implementation that switches algorithm above some size runs on both
sides of it. A long list repeats up to 17 drawn values. The conformance
option `sizes=spectest.generate.Sizes(...)` changes these bounds
(`long_share=0` turns long values off).

**Explicit examples.** The conformance option `examples` lists inputs to
judge before the search, as Hypothesis's `@example` does:
`examples={"select": [{"df": {"columns": ["*"], "rows": [[1.0]]}, "names": ["*"]}]}`.
Each is a dict from parameter name to value, given as an implementation
value is returned (or as a spec value); a parameter with a default may be left
out. A model-typed argument is a dict of the model's fields, which the
binding's concretizer builds; fields that its invariants compute (`nrows ==
len(rows)`) may be left out, and the others must satisfy every invariant. A
function's examples are judged on each of its items under each instantiation
they fit, and a failing one is the counterexample as given; an interface
member's (`"Deque.push"`) are among the arguments its steps draw.

**Shrinking.** After Hypothesis has shrunk a failing input, a deterministic
pass shrinks it further. Parameter by parameter it tries the default, every
shorter prefix and suffix and every single deletion of a list, string or byte
string, and simpler elements (zero bytes, "0" characters, 0, 1 and -1, none),
and removes a prefix, a suffix or one element of a model field together with
the same elements of every element of the fields whose elements take its
length (columns of a frame, with their cells). A candidate is kept only when
the same clause still fails on
it, so the counterexample stays a real one. A spec error is shrunk the same
way, first by Hypothesis and then by this pass, and stays a spec error of the
same kind (the same message, up to the values in it); each kind is reported
once.

## Clauses

A clause is `<kind> [ID:] <expr>`. IDs are unique within their declaration
and default to `<decl>#<n>`; every verdict names the ID and quotes the clause.
A labelled clause's ID is `<decl>.<label>`, where `<decl>` is a function's
name, a model's or interface's name, or `Iface.member` for a constructor or
method. The label of a model's or interface's own clause may not be the name
of one of its observers, constructors or methods: in `interface Deque` with a
constructor `bounded`, `invariant bounded:` would give the invariant the ID
`Deque.bounded`, which already names the constructor, so the checker rejects
it.
Under an instantiation, a verdict prints the ID with the instantiation after the
declaration's name, as the test item is named: `sort_by_first[K=i64,V=string].stable`,
`Deque[T=i64].pop#1`.

| Kind | May reference | Meaning |
| --- | --- | --- |
| `requires` | Inputs, pre-state | Inputs outside it are never judged. It is checked on every concrete input before any call, including inputs built by `relates` and replayed examples. |
| `ensures` | Inputs, `result`, `old(e)`, observers | Must hold whenever the call returns normally. |
| `raises E when e` | Inputs, pre-state | Let R be the errors whose condition holds. If R is non-empty the call must raise a member of R; if R is empty it must return normally. Overlapping conditions are therefore satisfiable. |
| `may_raise E [when e]` | Inputs, pre-state | Declared freedom: raising `E` (when `e` holds) passes. |
| `modifies p, ...` | Parameters, `self` | Handle parameters not listed must be unchanged, compared by digest of their abstraction, whether the call returns or raises. A listed handle's state after a raise is implementation-defined: no clause judges it. The default is `modifies` nothing. |
| `relates` | Inputs, `result`, calls to spec functions | Metamorphic relation, judged only when the base call returns normally. A planned call that raises makes it skip, and identical planned calls are made once. `result` is the base call; each call to a spec function inside the expression is planned as another implementation call, subject to `requires`. |
| `aggregate` | Calls to spec functions over a set of inputs | A bound over a whole input set, with c a constant: `sum(x in S: e) <= c`, `< c` or `== 0` (an L1 budget), `max(x in S: e) <= c` or `< c` (L∞), or `all(x in S: p)`. Only in `fn` bodies, and without the function's parameters, `result` or `old`. Terms must be non-negative; a negative term is a spec error. Sets of at most 2^16 values are evaluated in full; larger sets are sampled, which can only underestimate, so sampling may miss a failure but never invents one. A term whose call fails `requires` or raises is skipped and counted. |
| `invariant` | A model's observers; an interface's state | Holds on every observed handle of the model, and after every call on an interface. |
| `unspecified n`, `impl_defined n` | — | Named freedoms, recorded and not evaluated. No clause may observe them. |
| `perf` | — | Parsed and recorded for the performance harness. Never evaluated here. |

## Expressions

Expressions keep CEL's evaluation model (pure, no recursion, guaranteed to
terminate) but not its surface or numeric semantics. CEL's int64 overflow
errors and IEEE `==` on doubles conflict with the data model, so v1 has its
own small evaluator.

- **Operators**, lowest precedence first: `implies` (right-associative), `or`,
  `and`, `not`, comparisons `== != < <= > >= in`, `|`, `&`, `+ -`,
  `* / // %`, unary `-`, then calls, `.field`, `.0` (tuple fields), `[i]` and
  `[a:b]`. Also `if c then a else b` and `let x = e in body`. `//` and `%`
  are floored, as in Python.
- **Evaluation order.** `and`, `or`, `implies` and `if` evaluate left to right
  and short-circuit, so a guard protects what it guards. Errors are values
  that propagate: an out-of-range index or slice, a missing key, division by
  zero, or promoting a NaN.
- **Comprehensions** range over finite collections: `all(x in xs: p)`,
  `exists(x in xs: p)`, `count(x in xs: p)`, `sum(x in xs: e)`,
  `max(x in xs: e)`, `map(x in xs: e)` and `filter(x in xs: p)`, with
  `range(a, b)` for integer ranges. In `aggregate` clauses they may also range
  over a set such as `f16.finite`. An empty `max` is an evaluation error.
  Slices take both bounds: `xs[a:b]`.
- **Numbers.** Integers of every width compare and compute as `int`. Unary
  minus on a float flips its sign bit and keeps its type, so `cos(-x)` passes
  an `f64`; binary arithmetic promotes. A value passed to a fixed-width
  parameter must be exactly representable, or evaluation fails. Quantized
  errors add componentwise.
- **The equality rule.** `==`, `!=` and `in` type-check only on types with
  canonical equality. Floats compare with `same(a, b)` (bit-identical),
  `ieee_eq(a, b)`, `qe(a, b)`, or after an explicit `real(x)`. Models compare through
  their observers or with `eq(a, b, ...)`, whose knobs must cover every float
  and every ordering in the values: `float="bits" | "ieee" | "nan_any"`,
  `order="exact" | "ignore"`.
- **State.** `result` is the return value and `old(e)` evaluates `e` on the
  state before the call; `e` may not use a variable bound elsewhere in the
  clause, so bind `old(...)` of the state first. In `relates` and `aggregate`, calls to spec functions
  are implementation calls.

The prelude is versioned with the spec. v1 provides:

- **Floats:** `is_nan`, `is_inf`, `is_finite`, `is_zero`, `is_subnormal`,
  `signbit`, `bits`, `next_up`, `next_down`, `ulp<T>(r)`, and `qe(x, y)`. For
  x and y of one float format, `qe` is the number of values of that format in
  [min(x, y), max(x, y)), counting ±0 as one value and ±∞ as values. It is 0
  when both are NaN and `1·nan` when exactly one is. It is commutative,
  defined for every input, and equals the ulp error wherever that is defined
  and an integer. `steps(e)` and `nans(e)` read the two parts of a `qerr`.
- **Reference math:** `mp.sqrt`, `mp.exp`, `mp.log`, `mp.sin`, `mp.cos`,
  `mp.tan` and `mp.atan` return reals computed with MPFR at 256 bits.
  `cr.sqrt`, `cr.exp`, `cr.log`, `cr.sin`, `cr.cos`, `cr.tan` and `cr.atan`
  take a float and return the correctly rounded result in its format, with
  IEEE 754's special cases: NaN for invalid inputs and NaNs, signed zeros,
  and overflow to infinity.
- **Collections:** `len`, `sorted` (stable), `is_sorted`, `is_permutation`,
  `is_subsequence`, `distinct`, `index_of`, `keys`, `values`, concatenation
  with `+`.
- **Options:** `some(x)`, `none`, `is_some`, `is_none`, `unwrap`.
- **Bytes and text:** `le_uint` (little-endian unsigned value), `valid_utf8`
  (well-formed UTF-8, by Table 3-7 of the Unicode Standard: no overlong
  forms, surrogates or values past U+10FFFF), `codepoints(s)` (the code points
  of a string, a `list<int>`); `len(s)` counts code points.
- **Identity:** `fresh(h)`, `same_object(a, b)`, `shares_memory(a, b)`.
- **Fixed width:** `wrap<T>`, `fits<T>`, `round<T>`, `T.min`, `T.max` (for floats,
  the finite extremes), and the partition sets of the Declarations section. In `T.range(a, b)` a bound of
  `none` leaves that end open.

A prelude function never delegates to the host's own implementation of what
it defines, so that a spec can judge that implementation: `sorted` is not
Python's sort, and `valid_utf8` is not Python's UTF-8 decoder.

## Verdicts

Each clause on each example yields exactly one verdict, and only `fail` is
charged to the implementation.

| Verdict | When |
| --- | --- |
| `pass` | The clause evaluated to true. |
| `fail` | The clause evaluated to false, or the call broke `raises` or `modifies`, on an input that satisfies `requires`, with no evaluation error. |
| `skip` | The clause does not apply: `requires` is false, an `ensures` met a call that raised, or the clause could not be evaluated where a raise was due (below). |
| `spec error` | Evaluating the clause raised an error, or the binding failed (a concretizer or observer raised, or a built object does not observe as generated). Reported loudly; never a failure. |
| `inconclusive` | A timeout or resource limit. Wall-clock time is never a verdict. |

Two built-in clauses catch faults that no written clause covers: `<fn>#type`
fails when a result cannot be observed as its declared type, and
`<fn>#raises` fails on an exception that no `raises` or `may_raise` admits.

A model result is a value of its model only if the binding accepts it. `#type`
reads every field of each model handle in the result, and fails when the
binding refuses the object: a Python binding's `accepts(obj)` returns false
or an observer raises `spectest.NotAValue` (a frame column of the wrong
dtype, say). Every other clause that reaches a refused result skips, so the
one fault is charged once, to the implementation. A refusal of any other
object, such as an input the concretizer built, is a binding failure, and
any other exception from an observer stays one too.

A call may return normally on an input where a `raises` clause was due. That
clause fails there, and the call's other clauses meet an input their author
expected never to return. An `ensures`, `relates` or `invariant` clause whose
evaluation errors on it (an `index_of` of the very name whose absence made
the raise due, say) is a skip with the cause `raise due (<fn>#n)`, not a spec
error. One that evaluates to false fails as usual, and its counterexample
carries the line `note: <fn>#n required <Error> on this input`.

The soundness rules behind these verdicts:

1. Every `fail` names a clause, the inputs and the observation, and replays
   from the spec hash, the seed and the harness version (which pins
   Hypothesis).
2. `requires` is checked on every concrete input, however it was produced.
3. Equality and order on floats and models are always explicit.
4. An error while evaluating a clause is a spec error, except where a raise
   was due and the call returned: the `raises` clause fails there, and the
   clause that cannot be evaluated is a skip.
5. Quantifiers over values are evaluated in full. Only `aggregate` clauses
   over large sets sample, and only in forms where an underestimate cannot
   invent a failure.
6. Freedoms (`may_raise`, `unspecified`, `impl_defined`) can only widen what
   passes.

## Grammar

INDENT and DEDENT come from the layout rule; a line indented deeper than the
clause that starts it continues that clause.

```
file      = "spec" NAME { decl } ;
decl      = "use" STRING | "error" NAME | enum | record | alias | model | fn | interface ;
enum      = "enum" NAME "{" NAME { "," NAME } "}" ;
record    = "record" NAME "{" param { "," param } "}" ;
alias     = "type" NAME "=" type ;
model     = "model" NAME [ tparams ] [ INDENT { observe | clause } DEDENT ] ;
interface = "interface" NAME [ tparams ] [ INDENT { observe | ctor | method | clause } DEDENT ] ;
fn        = "fn" NAME [ tparams ] params [ "->" type ] [ INDENT body DEDENT ] ;
ctor      = "new" NAME params "->" type [ INDENT body DEDENT ] ;
method    = "method" NAME "(" "self" { "," param } ")" [ "->" type ] [ INDENT body DEDENT ] ;
observe   = "observe" NAME [ params ] ":" type ;
body      = { partition | clause } ;
partition = "partition" NAME INDENT { NAME "=" expr } DEDENT ;
clause    = ( "requires" | "ensures" | "relates" | "invariant" | "aggregate" ) [ NAME ":" ] expr
          | "raises" [ NAME ":" ] NAME "when" expr
          | "may_raise" [ NAME ":" ] NAME [ "when" expr ]
          | "modifies" NAME { "," NAME } | ( "unspecified" | "impl_defined" ) NAME
          | "perf" LINE ;
tparams   = "<" NAME [ ":" NAME ] { "," NAME [ ":" NAME ] } ">" ;
params    = "(" [ param { "," param } ] ")" ;
param     = NAME ":" type [ "=" expr ] ;
type      = NAME [ "<" type { "," type } ">" ] | "(" type "," type { "," type } ")"
          | STRING { "|" STRING } ;

expr      = impl ;
impl      = or [ "implies" impl ] ;
or        = and { "or" and } ;
and       = not { "and" not } ;
not       = "not" not | cmp ;
cmp       = union [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" | "in" ) union ] ;
union     = inter { "|" inter } ;
inter     = sum { "&" sum } ;
sum       = term { ( "+" | "-" ) term } ;
term      = unary { ( "*" | "/" | "//" | "%" ) unary } ;
unary     = "-" unary | "let" NAME "=" expr "in" expr
          | "if" expr "then" expr "else" expr | post ;
post      = atom { "(" [ arg { "," arg } ] ")" | "." ( NAME | INT ) | "[" expr [ ":" expr ] "]" } ;
arg       = [ NAME "=" ] expr ;
atom      = NUMBER | STRING | "true" | "false" | "none" | NAME [ "<" type ">" ]
          | ( "all" | "exists" | "count" | "sum" | "max" | "map" | "filter" ) "(" NAME "in" expr ":" expr ")"
          | "[" [ expr { "," expr } ] "]" | "{" [ expr { "," expr } ] "}" | "(" expr { "," expr } ")" ;
```

`NAME<type>` applies only to the prelude's generic functions (`wrap`, `fits`,
`round`, `ulp`, `qe`); `qe<F>(a, b)` also accepts numbers exactly
representable in F. `NUMBER` includes hexadecimal floats such as `0x1p-26`; numeric
literals are exact reals and may use `_` between digits. `let` and `if`
extend as far right as possible, so they can follow `implies`; inside a
`let` value, `in` ends the value unless it is bracketed.

## Not in v1

These are reserved in the syntax or the design, and are specified later:

- `linearizable` and concurrent call histories, which are not seed-reproducible.
- The wire protocol and drivers for languages other than Python. v1 binds
  Python implementations in-process.
- Corpus export, sampled observation of large values, and `perf` routing
  beyond parsing.
- Partial frames such as `modifies df.cells`, and function-valued arguments
  (key functions, callbacks).
- Clauses on the state a raising call leaves in the handles it may modify (for
  example, that `pop` on an empty deque leaves it empty). The likely form is
  subclauses under a `raises` clause, judged when the call raises that error.
- User-defined functions inside expressions. Reuse goes through the prelude.
