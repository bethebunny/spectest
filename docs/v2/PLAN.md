# spectest v2 implementation plan

v2 splits spectest into a Mojo host and a Python driver, as the design doc
"spectest v2 design" describes (https://claude.ai/artifact/Hse62fiuRkV8FaMXnwqNY1).
The host parses and checks specs, generates inputs, judges clauses, keeps the failure
store and writes reports. The driver calls the code under test. Both run in one
process: pytest loads the host as an extension module, `spectest._host`, and the host
calls back into the driver.

v1 stays in `src/spectest` and keeps working until v2 replaces it. v2's Python parts
are new subpackages of `spectest`; its Mojo parts live under `host/`.

The work is split into packages that can be built at the same time. Each one has a
brief in `docs/v2/briefs/`, owns its own directories, and depends on the others only
through the contracts below.

## Layout

```
host/                        Mojo sources; one include root
  wire/value.mojo            contract: Value, every value the host computes with
  wire/                      value semantics: equalities, order, formatting
  numeric/bigint.mojo        contract: BigInt
  numeric/formats.mojo       contract: FloatFormat, F16 BF16 F32 F64
  numeric/                   exact reals, float conversions, literals, number text
  syntax/ast.mojo            contract: the flat syntax tree
  syntax/                    lexer, parser, tree dump
  mcheck/                    the input engine
  sets/                      partition sets on bitpattern's diagrams
  bridge/                    the CPython extension module and the driver client
  vendor/bitpattern/         bitpattern's Mojo core at v0.3.0 (arena, bigint), unchanged
src/spectest/driver/         the Python driver; wire.py is a contract
tests/host/<package>/        Mojo tests, test_*.mojo, collected by tests/host/conftest.py
tests/driver/ tests/bridge/  Python tests
scripts/                     build scripts
docs/v2/                     this plan, the protocol, v2 syntax, Mojo notes, briefs
```

## Dev loop

- One Mojo package's tests: `uv run pytest tests/host/wire`. Each `test_*.mojo` file
  is one pytest item: it compiles with `host/` and `host/vendor/bitpattern` on the
  include path and runs its `TestSuite`. A cached rerun takes about a second; a cold
  compile several.
- One file without pytest:
  `.venv/bin/mojo run -I host -I host/vendor/bitpattern tests/host/wire/test_value.mojo`.
- Python tests: `uv run pytest tests/driver`.
- The extension module: `uv run python scripts/build_host.py` (from the bridge
  package), which rebuilds only when a `.mojo` file changed.
- Run the narrowest selection that answers the question, and at most one Mojo
  compile at a time per package: compiles take several cores and about a gigabyte.

`docs/v2/mojo.md` has notes on Mojo 1.2: the idioms that compile, the limits found so
far, and where to find reference code.

## Contracts

| Contract | File | What it fixes |
| --- | --- | --- |
| Value | `host/wire/value.mojo` | Kinds, layout, constructors, accessors, structural identity |
| BigInt | `host/numeric/bigint.mojo` | Signed integers of any size, floored division, decimal and hex text |
| Float formats | `host/numeric/formats.mojo` | Format ids (1 f16, 2 bf16, 3 f32, 4 f64) and bit layouts |
| Number text | `host/numeric/text.mojo` | `float_text(format_id, bits)`; a placeholder until numeric lands |
| Syntax tree | `host/syntax/ast.mojo` | Node kinds, ops, child layout per kind, spans, diagnostics |
| Python wire objects | `src/spectest/driver/wire.py` | The Python form of each wire kind |
| Protocol | `docs/v2/protocol.md` | The driver's methods and the conversions on both sides |
| v2 syntax | `docs/v2/syntax.md` | The grammar the parser accepts |

A package may add to a contract (a new accessor, a new node kind at the end) and says
so in its commit message. Changing or removing anything in a contract waits for
integration, where every user of it is updated at once.

## Packages

### Wave 1: independent

| Package | Brief | Builds |
| --- | --- | --- |
| bridge | `briefs/bridge.md` | The extension module, Value to Python and back, the driver client, the round-trip spike |
| driver | `briefs/driver.md` | Name resolution, calls, observers, marshalling, converters, errors, handles |
| wire | `briefs/wire.md` | Canonical equality, `same`, the `Ord` order, hashing to match, report text |
| numeric | `briefs/numeric.md` | Exact reals, float to real and back, numeric literals, number text |
| syntax | `briefs/syntax.md` | Lexer with the layout rule, parser for v2 syntax, tree dump, diagnostics |
| mcheck | `briefs/mcheck.md` | Choice sequences, generators, search over several properties, shrinking, enumeration, failure store |
| sets | `briefs/sets.md` | Partition sets on the arena: intervals, patterns, named float and int sets, counting, sampling |

### Wave 2: on wave 1

| Package | Needs | Builds |
| --- | --- | --- |
| checker | syntax | Names, qualified-name resolution, types, clause IDs, the static rules of `docs/language.md` |
| prelude | numeric, wire | The system prelude in `prelude.mojo`: floats, ints, collections, text, `cr` and `mp` math |
| evaluator | checker, wire, numeric | Expressions on Values, host operators, short-circuiting, errors as values |
| gen | mcheck, sets, checker | Spec types to generators, partitions as sets and predicates, `build` lists, sizes |
| plugin | bridge, driver | Collecting spec items in pytest and running them through the host |
| reports | wire, mcheck | The failure store and Markdown and JSON reports |

### Wave 3: end to end

The runner (generate, call, judge, verdicts, `#type` and `#raises`, planned calls),
stateful interfaces, user preludes, and specs to run v2 against.

## Open questions and where they bite

The design doc's open questions stay open. The packages work around them:

- `raises` with `may_raise`: only the runner (wave 3) judges this. It keeps v1's
  runtime behavior until the question is settled.
- Isolation: only the runner calls the library repeatedly. Wave 1 and 2 don't depend
  on the answer.
- Converted types in specs: the protocol carries `Converted` both ways, so either
  answer fits. The checker (wave 2) needs the answer before it types such parameters.
- Migration: wave 1 parses the existing specs as test material; porting them to run on
  v2 is wave 3.

## How a package lands

Each package is built in its own jj workspace started from `main`, and committed in
small steps as its tests pass. When its brief's acceptance list is met, it goes to the
merge queue, which rebases it onto `main`, runs its tests and the contract tests
(`uv run pytest tests/host/wire/test_value.mojo tests/host/numeric/test_bigint.mojo
tests/host/syntax/test_ast.mojo tests/host/vendor`), and moves `main`. Packages own
disjoint directories, so rebases rarely conflict; one that does goes back to its
author.

## Status

| Package | State |
| --- | --- |
| contracts | landed |
| bridge | landed. About 0.25 µs per call is the host's own cost; see `docs/v2/spike.md` |
| driver | landed. `call` costs 0.2 to 0.6 µs for a two-int function |
| wire | landed |
| numeric | landed. Literal exponents are capped at 10\*\*6, which v1 doesn't cap |
| syntax | landed. `bitpattern.spec` parses in about 7 ms |
| mcheck | landed. About 0.18 µs per trivial example |
| sets | landed. Every named set of every format builds in about 0.1 ms |
