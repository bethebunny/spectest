# spectest

spectest is a specification language and a pytest plugin. A spec file states what a
component's functions must do, and the plugin tests an implementation against the spec
with generated inputs.

## Example

Here is a quicksort with a bug, in `sorting.py`:

```python
def sort(xs):
    if len(xs) <= 1:
        return xs
    pivot, *rest = xs
    smaller = [x for x in rest if x < pivot]
    larger = [x for x in rest if x > pivot]
    return sort(smaller) + [pivot] + sort(larger)
```

`sorting.spec` describes `sort` by its qualified name, `sorting.sort`:

```
spec sorting

fn sorting.sort(xs: list<i64>) -> list<i64>
  partition xs
    empty      = len(xs) == 0
    single     = len(xs) == 1
    unique     = len(xs) > 1 and distinct(xs)
    duplicates = len(xs) > 1 and not distinct(xs)
  ensures permutation: is_permutation(result, xs)
  ensures ordered: is_sorted(result)
```

A test module, `test_sorting.py`, hands the spec to the plugin:

```python
import spectest

test_sort = spectest.check("sorting.spec")
```

pytest collects one item per clause and two built-in items. `#type` checks that each
result has the declared type, and `#raises` checks that no call raises an exception the
spec doesn't admit.

```
$ pytest
collected 4 items

test_sorting.py F...                                                     [100%]

=================================== FAILURES ===================================
______________________ spectest sorting.sort.permutation _______________________
sorting.sort.permutation (ensures) failed
  ensures permutation: is_permutation(result, xs)
  in sorting.sort

inputs:
  xs = [0, 0]
observed:
  result = [0]
partitions:
  xs: duplicates
explanation:
  result = [0]
  xs = [0, 0]
  is_permutation(result, xs) = false
verdicts: 85 pass, 15 fail (hypothesis)
seed: 0
reproduce: seed=0 decl=sorting.sort clause=sorting.sort.permutation
=================================== spectest ===================================
test_sorting.py::test_sort (spec sorting): 3 passed, 1 failed
=========================== short test summary info ============================
FAILED test_sorting.py::test_sort::sorting.sort.permutation - sorting.sort.pe...
========================= 1 failed, 3 passed in 0.59s ==========================
```

`larger` leaves out the elements equal to the pivot. With `x >= pivot` in its place, all
four items pass.

## How it works

spectest draws each input from its declared type, here lists of 64-bit integers. A
partition splits a parameter's values into named classes. Each example picks a class
(or, as often as any one class, no class) and draws again until the value is in it, a
few times at most. So a rare class gets its share of the examples. Here 15 of the 100
lists had duplicates, and every one of them failed. For a fixed-width number (eg. an
`i32` or an `f64`) the classes are sets instead. The checker proves before any test runs
that they are disjoint and cover every value that `requires` admits, and generation
draws a member of a class directly. An example that a `requires` clause rejects is
skipped and never judged.

Every clause of the function is judged on each example's call. A clause that fails is
shrunk on its own to a small counterexample, such as `[0, 0]` above, and stored in
`.spectest/`. The next run replays it first.

Together, `permutation` and `ordered` say that the result is the input in sorted order,
so they describe `sort` completely. A pass on 100 lists spread over the four classes is
good evidence that an implementation meets them, and `--spectest-report` writes a
report that counts the examples in each class. A domain of at most 65,536 inputs (eg. a
function of one `f16`) runs exhaustively, and a pass there holds for every input.

The example runs on v2, the engine behind `spectest.check`. v2 is a Mojo host that
generates inputs and judges clauses, compiled into the extension module `spectest._host`,
and a Python driver that calls the code under test. v1, the pure-Python engine behind
`spectest.conformance`, runs the specs under `examples/`.

## Install

```
pip install spectest
```

0.0.1 is an early release. It has wheels for Linux on x86-64 (glibc 2.35 or later) and
needs Python 3.12 or later. The wheel depends on mojo-compiler for the Mojo runtime
libraries.

## Development

```
uv sync
uv run python scripts/build_host.py  # builds spectest._host in place
uv run pytest                        # the dev loop: tests/ at small budgets
uv run pytest --ci                   # everything at full strength
```

`scripts/build_host.py` rebuilds the module only when a `.mojo` file changed, and the
tests that need the module build it too.

- `docs/language.md` defines the spec language.
- `docs/v2/` has v2's plan, its syntax, the driver protocol and notes on Mojo.
- `examples/` holds specs of libm, sorting, binary codecs, a deque and data frames, with
  the implementations they were tested against and what the runs found.
