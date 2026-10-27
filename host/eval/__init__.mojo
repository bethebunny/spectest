"""The evaluator: checked expressions and clauses on `Value`s.

`eval.api` has the entry points (`evaluate`, `judge`, `snapshot_olds`, `observe_with`,
`explain`, `class_holds`); `eval.host.EvalHost` is what the runner provides: observers,
constants, planned calls and identity questions. `eval.testkit` has a mock host and
helpers for tests.
"""
