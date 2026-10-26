# spectest v1: the use cases

spectest is a specification language and a tool that tests implementations against
specs. A spec states what a function or a stateful interface must do. A conformance
binds a spec to Python implementations. The pytest plugin then turns every clause into
a test item, searches for inputs that break it, and reports a minimized counterexample.
The language is defined in [language.md](language.md).

Five use cases under `examples/` exercise the design. Each has:
- a spec;
- real implementations to test;
- seeded bugs that the spec must catch;
- a FINDINGS.md that checks every finding without spectest.

## Results

| Case | What the spec covers | Tested against | Default run | Found in real implementations |
| --- | --- | --- | --- | --- |
| [libm](../examples/libm/README.md) | `cos` over f64, f32 and f16, and `sqrt` over f64, against correctly rounded references | `math`, numpy, 2 seeded formulas | 37 passed, 6 xfailed | `math.cos(±inf)` raises where IEEE 754 returns NaN. numpy's f16 cos is not correctly rounded on 2 of the 65,536 inputs, and its f32 cos is off by one step on [-1, 1) (explore run). |
| [sorting](../examples/sorting/README.md) | a value sort, a stable sort of pairs by key, an in-place sort | `sorted`, `list.sort`, numpy, 3 seeded bugs | 65 passed, 4 xfailed | numpy's default `argsort` reorders equal keys from 4 elements with AVX2, and from 17 on its portable path. |
| [frames](../examples/frames/README.md) | an abstract float dataframe: `dropna`, `fillna`, `select` | pandas, polars, 3 seeded bugs | 85 passed, 6 xfailed | polars `select([])` on a frame with rows and no columns returns a 0 x 0 frame. polars also reads the column names `*` and `^…$` as patterns, so `select` returns other columns instead of raising. |
| [deque](../examples/deque/README.md) | a bounded double-ended queue as a stateful interface | `collections.deque`, a list-based deque, 5 seeded bugs | 10 passed, 10 xfailed | `collections.deque` conforms. The runs found two holes in the spec itself, which are now closed: rotate on an empty deque, and `maxlen` changing. |
| [binary](../examples/binary/README.md) | `pack_i32` / `unpack_i32` and the UTF-8 codecs | `struct` and `str`, `int.to_bytes` / `from_bytes`, numpy, 3 seeded bugs | 66 passed, 13 xfailed | `int.from_bytes` accepts any length. numpy `frombuffer(b, "<i4")[0]` silently reads 8, 12 or 16 bytes. The case also showed that spectest's `valid_utf8` was CPython's own decoder, so it could not catch a bug there. It now follows the Unicode table instead. |

All 43 expected-failure clauses, the seeded bugs and the real findings, fail at every seed from 0 to 5 (258 of 258 runs). An expected failure that stops failing breaks the run, because expected failures are strict.

## What each case exercises

| Feature | Where |
| --- | --- |
| IEEE floats, quantized error `qe`, correctly rounded references `cr.*`, `same`, `next_up` | libm |
| Input partitions as bit-pattern sets (`f64.range(...) & f64.normal`, open i64 ranges) and their coverage | libm, binary |
| Predicate partitions that steer generation (`len(b) == 4`, `distinct(xs)`) | sorting, binary |
| Generic declarations with `Ord` / `Eq` bounds and several instantiations | sorting, deque |
| Models: observers, invariants that shape generation, `option` cells, `none` versus `some(NaN)` | frames, sorting |
| `modifies`, `old(...)` and the frame rule | sorting, deque |
| `raises` and `may_raise`, with Python exceptions mapped to spec errors | libm, frames, deque, binary |
| `relates`: metamorphic relations and round trips through a second function | libm, binary |
| `aggregate` bounds and exhaustive checking (all 65,536 f16 inputs) | libm |
| Interfaces: constructors, method sequences, invariants after every call, shrunk step logs | deque |
| `fresh`, `unspecified`, `impl_defined` | frames, libm |
| Explicit examples for inputs the generator rarely reaches | frames |
| Exploration runs that measure rather than require (`explore_*.py`; in libm, a spec of questions) | libm, sorting, frames, deque, binary |

A failing item shows:
- the clause;
- the minimized input and what the call returned;
- each subexpression's value;
- a command that reproduces it.

Counterexamples are stored under `.spectest/` and replayed first on the next run. `--spectest-report` and `--spectest-json` write a report with every clause's counts and its coverage of each partition class.

## Running

```
uv run pytest                    # dev loop: tests/ at small budgets, about 15 s
uv run pytest tests/eval         # one area, in one process
uv run pytest examples/frames    # one use case at full strength
uv run pytest examples/frames --spectest-report=examples/frames/REPORT.md
uv run pytest examples/libm/explore_libm.py --spectest-report=examples/libm/EXPLORE.md
uv run pytest --ci               # everything at full strength, about 3 minutes
```

`--spectest-profile=dev` runs a use case at small budgets while its spec is being edited. The README covers both profiles and the store options.

## Open items

- **State after a raise.** In v1, a call that raises may leave any state in the handles it is allowed to modify. Every other handle must stay unchanged, just as after a normal return. No clause can yet say, for instance, that `pop` on an empty deque leaves it empty. The intended form is subclauses under `raises` clauses (see [language.md](language.md), "Not in v1").
- **Stateful search speed.** Interface items are the slowest part of every run. A faster step driver was tried and removed, because it skipped invariant checks unsoundly. A redesign is in [ISSUES.md](ISSUES.md).
- **Rare inputs.** The generator almost never draws pattern-like names such as `*`, so frames supplies them as explicit examples. Also, `expect_fail` names a clause, not a cause: once a clause is expected to fail, any other failure of it is hidden.
- **Generation drifts slightly** when spectest's own source changes, because Hypothesis mixes in literals from imported modules. Verdicts and counterexamples have held; counts move by under 1% ([ISSUES.md](ISSUES.md)).
- **Not in v1:**
  - drivers for languages other than Python;
  - judging `perf` clauses;
  - concurrency;
  - partial frames;
  - checking a spec against itself.

  An independent check of the implementation against [language.md](language.md) is still to come.
