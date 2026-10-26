# spectest

A formal specification language and the tooling to test implementations against specs.

The language is described in `docs/language.md`. Each directory under `examples/` holds a
spec, the implementations it is tested against, and what the runs found.

## Running the tests

```
uv run pytest                   # the dev loop: tests/ at small budgets
uv run pytest tests/lang        # one directory, file or test, in one process
uv run pytest --ci              # everything at full strength, under pytest-xdist
```

`uv run pytest` runs tests/ under the `dev` Hypothesis profile: 10 examples per
property and no deadline. Tests whose cost is a count rather than a Hypothesis
budget (an exhaustive loop over f16, a sample size, a spectest search budget)
take a smaller count from `tests/budget.py`, and the scratch projects of the
plugin tests run under `--spectest-profile=dev`; the assertions are the same in
both runs. Tests marked `slow` (those that take over half a second even at the dev
budgets) are deselected; `--slow` keeps them, `-m slow` runs only them, and naming
one by its node ID runs it. The whole suite runs on four pytest-xdist workers, while
a run that names paths stays in one process, which starts faster; `-n N` sets the
workers either way.

`uv run pytest --ci` is the full run: tests/ under the `ci` profile (Hypothesis's
default budgets, no deadline) with the slow tests, and every example under
examples/ at its own spectest budget with its expected failures, on one worker
per logical CPU. `--spectest-report` and `--spectest-json` work under xdist: the
controller writes one report of every worker's results. `--hypothesis-profile=ci`
gives full strength in one process, without the examples.

## Spectest options for runs

`--spectest-profile=dev` (or `spectest_profile = dev` in the pytest ini) runs
25 examples per item, exhausts only domains of at most 4,096 inputs and samples
1,000 members of larger aggregate sets, where the default `ci` profile runs each
conformance at its own budget. Use it while editing a spec; it can miss failures
that need a larger search, so judge an implementation at the default budgets.

`--spectest-store=DIR` moves the counterexample store from `.spectest/` and
`--spectest-no-store` turns it off.
