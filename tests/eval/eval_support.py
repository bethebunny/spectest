"""Shared helpers for the evaluator tests: a fake EvalContext and spec builders."""

from __future__ import annotations

import functools
import random
import textwrap
from collections.abc import Callable
from pathlib import Path
from typing import Any

from spectest import ast, sets
from spectest.eval import Env, evaluate
from spectest.lang import Spec, load, load_source
from spectest.prelude import floats
from spectest.values import FloatValue, Handle

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"


@functools.cache
def example(name: str) -> Spec:
    """Load examples/<dir>/<name>.spec, once per session (no test changes a loaded spec)."""
    matches = sorted(EXAMPLES.glob(f"*/{name}.spec"))
    assert matches, name
    return load(matches[0])


def spec_of(source: str) -> Spec:
    return load_source(textwrap.dedent(source).lstrip("\n"), "t.spec")


def f64(x: float) -> FloatValue:
    return floats.from_python_float(x, "f64")


def f32(x: float) -> FloatValue:
    return floats.from_python_float(x, "f32")


def f16(x: float) -> FloatValue:
    return floats.from_python_float(x, "f16")


def py(v: FloatValue) -> float:
    return floats.to_python_float(v)


def handle(model: str, **observers: Any) -> Handle:
    """A handle whose observers are dict entries: values, or callables (live or with args)."""
    return Handle(dict(observers), model)


class FakeCtx:
    """An EvalContext over handles whose ``obj`` maps observer names to values or callables."""

    def __init__(
        self,
        spec_fns: dict[str, Callable[..., Any]] | None = None,
        fresh: tuple[Handle, ...] = (),
        exhaustive_limit: int = 1 << 16,
        sample: int = 500,
    ) -> None:
        self.spec_fns = spec_fns or {}
        self.calls: list[tuple[str, tuple]] = []
        self.observations: list[tuple[Handle, str, tuple]] = []
        self.fresh = {h.id for h in fresh}
        self.exhaustive_limit = exhaustive_limit
        self.sample = sample
        self.member_sets: list[Any] = []

    def observe(self, h: Handle, observer: str, args: tuple) -> Any:
        self.observations.append((h, observer, args))
        v = h.obj[observer]
        if callable(v):
            return v(*args)
        assert not args
        return v

    def fields(self, h: Handle) -> dict[str, Any]:
        return {k: (v() if callable(v) else v) for k, v in h.obj.items()}

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        self.calls.append((name, args))
        return self.spec_fns[name](*args)

    def is_fresh(self, h: Handle) -> bool:
        return h.id in self.fresh

    def same_object(self, a: Handle, b: Handle) -> bool:
        return a.obj is b.obj

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        return False

    def members(self, s: Any, elem: Any) -> tuple[Any, bool]:
        """Every member of a small set; a seeded sample of a large one."""
        self.member_sets.append(s)
        n = sets.set_size(s)
        if n <= self.exhaustive_limit:
            return sets.enumerate_set(s), False
        rng = random.Random(0)
        return [sets.member(s, rng.randrange(n)) for _ in range(self.sample)], True


PROBE = "probe"


def probe_spec(signature: str, expr: str, decls: str = "") -> tuple[Spec, ast.Expr]:
    """A spec with ``fn <signature>`` whose one clause binds ``expr``; returns (spec, expr node)."""
    source = f"spec t\n{decls}\nfn {signature}\n  ensures e: let {PROBE} = ({expr}) in true\n"
    spec = load_source(source, "t.spec")
    clause = next(iter(spec.fns.values())).clauses[0]
    assert isinstance(clause.expr, ast.Let)
    return spec, clause.expr.value


def value_of(signature: str, expr: str, ctx: Any = None, decls: str = "", **values: Any) -> Any:
    """Evaluate ``expr`` in a function ``signature`` with the given parameter values."""
    spec, node = probe_spec(signature, expr, decls)
    return evaluate(node, Env(dict(values)), spec, ctx or FakeCtx())


def clause(spec: Spec, cid: str) -> ast.Clause:
    return spec.clause_ids[cid]
