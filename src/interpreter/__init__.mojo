"""The evaluator: checked expressions and clauses on `Value`s.

`interpreter.api` has the entry points (`evaluate`, `judge`, `snapshot_olds`,
`observe_with`, `explain`, `class_holds`); `interpreter.host.EvalHost` is what the runner
provides: observers, constants, planned calls and identity questions.
"""
