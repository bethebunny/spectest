# deque

A stateful interface case: deque.spec specifies a double-ended queue with an optional bound, modelled on Python's `collections.deque`. It exercises these spec features:
- constructors (`empty`, `bounded(n)`) and command sequences;
- `raises IndexError when len(self.items) == 0`, judged on the state before the call;
- `old(...)` in `ensures`, and `modifies self`;
- an interface invariant, checked after every call;
- floored `%` in `rotate`.

spectest runs each instantiation (T = i64 and T = string) as a Hypothesis state machine. The machine builds at most two deques per step sequence, calls methods in random order (mostly on the deque used last), judges every clause after every call, and shrinks a failure to a short step log.

## Files

- `deque.spec`: the requirement. Two strengthening fixes are described in FINDINGS.md, section 3.
- `deque_bindings.py` has:
  - the `InterfaceBinding`: `empty` = `collections.deque()`, `bounded(n)` = `collections.deque(maxlen=n)`, observers `items` = `list(d)` and `maxlen` = `d.maxlen`, and each object's own methods;
  - the error mapping `{IndexError: "IndexError"}` and the instantiations;
  - `ProbedDeque`, a counting subclass of collections.deque used to measure coverage.
- `deque_impls.py`: `ListDeque`, a correct list-based deque, plus five seeded bugs:
  - `WrongEndDeque`
  - `BackwardRotateDeque`
  - `PopleftNoneDeque`
  - `SlotDeque`
  - `RebuildingDeque`
- `test_deque.py`: the conformances and the plain checks.
  - `test_collections_deque`: both constructors, 300 examples. The search fills bounded deques of every size class (FINDINGS.md, section 2).
  - One `test_seeded_*` conformance per bug, each with its expected failures.
  - Plain pytest functions that replay every counterexample without spectest.
- `explore_deque.py`: run on demand. It repeats the collections.deque search over `ProbedDeque` and checks that every edge case ran: pops on empty deques, rotate with negative and large n, bounded(0), bounded(1) and bounded(n >= 2) deques filling up, and so on.
- `REPORT.md`: written by `--spectest-report`.
- `FINDINGS.md`: what was found, with independent checks.

## Running

```
uv run pytest examples/deque                                         # about 50 s
uv run pytest examples/deque --spectest-report=examples/deque/REPORT.md
uv run pytest examples/deque/explore_deque.py -s                     # edge-case counts, about 15 s
uv run pytest examples/deque -k test_collections_deque --spectest-max-examples=2000 --spectest-seed=1
```

## What to expect

- 10 passed and 10 xfailed. The 10 passes are 2 spectest items (one conformance × two instantiations) and 8 plain checks.
- The "spectest" terminal section lists each expected failure with its step log:
  - (a) `Deque.appendleft.items`: bounded(n=1), append(1), appendleft(0). The deque keeps `[1]`.
  - (b) `Deque.rotate.items`: empty(), append 0, 0 and 1, then rotate(1). The deque holds `[0, 1, 0]`, not `[1, 0, 0]`.
  - (c) `Deque.popleft#1` and `Deque.popleft#type`: popleft() on an empty deque returned None.
  - (d) `Deque.pop#1` and `Deque.pop#raises`: pop() on an empty deque raised an unmapped KeyError.
  - (e) `Deque.rotate.maxlen`: bounded(n=0), then rotate(0). maxlen became none.
- `explore_deque.py` prints the counts per edge case and passes.

Every bug is found at the default seed, and at seeds 0 to 5 for both T (FINDINGS.md, section 5); a missed bug would fail as a strict unexpected pass. Each failing step log is stored under `.spectest/` and replayed first on the next run, so a rerun finds it at any seed; its counterexample then ends with "(replayed from the counterexample store ...)". Delete `.spectest/counterexamples/<the spec's hash prefix>/` to search afresh.

## Reading REPORT.md

Each interface item gives one row per clause (38 rows per item). The Clause column names each one, e.g. `Deque[T=i64].pop#1`. "Items" counts pytest items as pytest tallied them; "Clause results" counts the rows. Counterexample sections are headed by conformance and clause, e.g. `test_seeded_appendleft_wrong_end::Deque[T=i64].appendleft.items`. To run one clause's results only, use `--spectest-clause`, e.g. `--spectest-clause='Deque*.rotate.*'`; `-k` cannot take `#`.
