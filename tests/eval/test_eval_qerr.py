"""Quantized errors, max comprehensions, sets as members and aggregate clauses."""

from __future__ import annotations

from fractions import Fraction
from typing import Any

import pytest
from eval_support import FakeCtx, f16, f64, spec_of, value_of

from spectest import ast
from spectest.eval import (
    AggregateResult,
    Env,
    NullContext,
    evaluate,
    evaluate_aggregate,
    explain,
    format_value,
    holds,
)
from spectest.prelude import cr, floats
from spectest.types import FloatT
from spectest.values import EvalError, FloatValue, QError, SkipClause

ONE = f64(1.0)


def up(v: FloatValue, k: int = 1) -> FloatValue:
    for _ in range(k):
        v = floats.next_up(v)
    return v


def q(expr: str, **values: Any) -> Any:
    return value_of("f(x: f64, y: f64, z: f64)", expr, **values)


XYZ = {"x": ONE, "y": up(ONE, 2), "z": floats.nan("f64")}


# -- qerr values -----------------------------------------------------------------


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("qe(x, y)", QError(2, 0)),
        ("qe(x, z)", QError(0, 1)),
        ("qe(x, y) + qe(x, z)", QError(2, 1)),
        ("qe(z, z) + qe(x, x)", QError.ZERO),
        ("qe<f64>(x, 1)", QError.ZERO),
        ("qe<f64>(y, 1)", QError(2, 0)),
        ("steps(qe(x, y) + qe(y, x))", 4),
        ("nans(qe(x, z) + qe(z, y))", 2),
        ("[qe(x, y), qe(y, x)]", (QError(2, 0), QError(2, 0))),
    ],
)
def test_qerr_values(expr: str, expected: Any) -> None:
    assert q(expr, **XYZ) == expected


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("qe(x, y) <= 2", True),
        ("qe(x, y) <= 1", False),
        ("qe(x, y) < 2", False),
        ("qe(x, y) < 2.5", True),
        ("qe(x, y) >= 2", True),
        ("qe(x, y) > 2", False),
        ("qe(x, y) > 1", True),
        ("qe(x, y) == 2", True),
        ("qe(x, y) != 2", False),
        ("2 == qe(x, y)", True),
        ("1 < qe(x, y)", True),
        ("qe(x, z) <= 100", False),
        ("qe(x, z) >= 0", True),
        ("qe(x, z) > 0", True),
        ("qe(x, z) == 0", False),
        ("qe(x, z) + qe(x, y) >= qe(x, y)", True),
        ("qe(x, z) <= qe(x, y)", False),
        ("qe(x, y) <= qe(x, z)", False),
        ("qe(x, y) >= qe(x, z)", False),
        ("qe(x, y) == qe(y, x)", True),
        ("qe(x, y) != qe(x, z)", True),
        ("qe(x, y) < qe(x, y) + qe(x, z)", True),
        ("qe(x, y) in [qe(x, x), qe(y, x)]", True),
        ("qe(x, z) in [qe(x, x), qe(y, x)]", False),
    ],
)
def test_qerr_comparisons_are_componentwise(expr: str, expected: bool) -> None:
    assert q(expr, **XYZ) is expected


def test_qerr_formats() -> None:
    assert format_value(QError(3, 1)) == "3 + 1nan"
    assert format_value((QError(1, 0), QError(0, 2))) == "[1, 2nan]"
    spec = spec_of(
        """
        spec t
        fn f(x: f64) -> f64
          ensures a: qe(result, cr.cos(x)) <= 1
        """
    )
    env = Env({"x": ONE, "result": floats.nan("f64")})
    got = dict(explain(spec.clause_ids["f.a"].expr, env, spec, FakeCtx()))
    assert got["qe(result, cr.cos(x))"] == "1nan"


# -- sum and max -------------------------------------------------------------------


@pytest.mark.parametrize(
    ("signature", "expr", "values", "expected"),
    [
        ("f(xs: list<u8>)", "max(v in xs: v)", {"xs": (3, 9, 2)}, 9),
        ("f(xs: list<int>)", "max(v in xs: v / 2)", {"xs": (3, 1)}, Fraction(3, 2)),
        ("f(xs: list<int>)", "max(v in xs: v - 10)", {"xs": (3, 1)}, -7),
        ("f(xs: list<f64>)", "max(v in xs: v)", {"xs": (f64(0.5), f64(-2.0))}, Fraction(1, 2)),
        (
            "f(xs: list<f64>)",
            "max(v in xs: qe(v, cr.sqrt(v)))",
            {"xs": (f64(4.0), f64(-1.0), f64(2.0))},
            QError(2**52, 1),
        ),
        (
            "f(xs: list<f64>)",
            "sum(v in xs: qe(v, cr.sqrt(v)))",
            {"xs": (f64(4.0), f64(-1.0), f64(-2.0))},
            QError(2**52, 2),
        ),
        ("f(xs: list<f64>)", "sum(v in xs: qe(v, v))", {"xs": ()}, QError.ZERO),
    ],
)
def test_sum_and_max(signature: str, expr: str, values: dict[str, Any], expected: Any) -> None:
    got = value_of(signature, expr, **values)
    assert got == expected and type(got) is type(expected)


def test_max_of_nothing_and_of_nan_are_errors() -> None:
    with pytest.raises(EvalError, match=r"max\(\.\.\.\) of no elements has no value"):
        value_of("f(xs: list<u8>)", "max(v in xs: v)", xs=())
    with pytest.raises(EvalError, match="cannot promote NaN"):
        value_of("f(xs: list<f64>)", "max(v in xs: v)", xs=(f64(1.0), floats.nan("f64")))


def test_qerr_max_is_componentwise() -> None:
    xs = (f64(4.0), f64(2.0), f64(-1.0))
    got = value_of("f(xs: list<f64>)", "max(v in xs: qe(v, cr.sqrt(v)))", xs=xs)
    assert got == QError(floats.qe(f64(4.0), f64(2.0)).steps, 1)


# -- sets as members -------------------------------------------------------------------


SMALL = """
spec t
fn g(x: u8) -> u8
  aggregate total: sum(v in u8.range(0, 10): g(v)) <= 100
  aggregate exact: sum(v in u8.range(0, 10) | {200}: g(v)) == 0
  aggregate under: sum(v in u8.range(0, 10): g(v)) < 45
  aggregate worst: max(v in u8.all - {0}: g(v)) <= 3
  aggregate below: max(v in u8.all: g(v)) < 4
  aggregate fixed: all(v in u8.range(0, 50): g(v) == v)
  aggregate listed: max(v in [3, 1, 2]: g(v)) <= 2 * 50
  aggregate constant: max(v in u8.all: g(v)) <= i8.max
"""


def _identity(v: int) -> int:
    return v


def test_comprehension_over_a_set_uses_ctx_members() -> None:
    spec = spec_of(SMALL)
    c = spec.clause_ids["g.total"]
    ctx = FakeCtx({"g": _identity})
    assert evaluate(c.expr, Env({}), spec, ctx) is True
    assert [a for _, a in ctx.calls] == [(i,) for i in range(10)]
    (s,) = ctx.member_sets
    assert s.size == 10
    with pytest.raises(EvalError, match="ranging over a set of u8 values is not available"):
        evaluate(c.expr, Env({}), spec, NullContext())
    with pytest.raises(EvalError, match="is not available.*at t.spec:3:"):
        evaluate_aggregate(c, spec, NullContext())

    class NoMembers:
        def call_spec_fn(self, name: str, args: tuple) -> Any:
            return 0

    with pytest.raises(EvalError, match="needs ctx.members"):
        evaluate_aggregate(c, spec, NoMembers())


def test_aggregate_sum() -> None:
    spec = spec_of(SMALL)
    r = evaluate_aggregate(spec.clause_ids["g.total"], spec, FakeCtx({"g": _identity}))
    assert r == AggregateResult(True, 45, 100, 10, 0, 10, False, [(i, i) for i in range(9, 0, -1)])
    under = evaluate_aggregate(spec.clause_ids["g.under"], spec, FakeCtx({"g": _identity}))
    assert (under.holds, under.value, under.bound) == (False, 45, 45)
    exact = evaluate_aggregate(spec.clause_ids["g.exact"], spec, FakeCtx({"g": lambda v: 0}))
    assert (exact.holds, exact.value, exact.total, exact.worst) == (True, 0, 11, [])
    off = evaluate_aggregate(
        spec.clause_ids["g.exact"], spec, FakeCtx({"g": lambda v: int(v == 200)})
    )
    assert (off.holds, off.value, off.worst) == (False, 1, [(200, 1)])


def test_aggregate_max_and_worst_ordering() -> None:
    spec = spec_of(SMALL)
    ctx = FakeCtx({"g": lambda v: v % 7})
    r = evaluate_aggregate(spec.clause_ids["g.worst"], spec, ctx)
    assert (r.holds, r.value, r.bound, r.evaluated, r.total) == (False, 6, 3, 255, 255)
    assert len(r.worst) == 20
    assert [t for _, t in r.worst] == [6] * 20
    assert [m for m, _ in r.worst][:3] == [6, 13, 20]
    below = evaluate_aggregate(spec.clause_ids["g.below"], spec, FakeCtx({"g": lambda v: 3}))
    assert below.holds and below.value == 3
    assert not evaluate_aggregate(
        spec.clause_ids["g.below"], spec, FakeCtx({"g": lambda v: 4})
    ).holds
    listed = evaluate_aggregate(spec.clause_ids["g.listed"], spec, FakeCtx({"g": _identity}))
    assert listed == AggregateResult(True, 3, 100, 3, 0, 3, False, [(3, 3), (2, 2), (1, 1)])
    constant = evaluate_aggregate(
        spec.clause_ids["g.constant"], spec, FakeCtx({"g": lambda v: v // 2})
    )
    assert (constant.holds, constant.value, constant.bound) == (True, 127, 127)


def test_aggregate_all_counts_failures() -> None:
    spec = spec_of(SMALL)
    c = spec.clause_ids["g.fixed"]
    r = evaluate_aggregate(c, spec, FakeCtx({"g": lambda v: v if v % 2 == 0 else 0}))
    assert (r.holds, r.value, r.bound, r.evaluated, r.total) == (False, 25, 0, 50, 50)
    assert r.worst == [(v, False) for v in range(1, 41, 2)]
    ok = evaluate_aggregate(c, spec, FakeCtx({"g": _identity}))
    assert (ok.holds, ok.value, ok.worst) == (True, 0, [])
    assert holds(c, Env({}), spec, FakeCtx({"g": _identity}))


def test_skipped_terms_are_counted_not_fatal() -> None:
    spec = spec_of(SMALL)

    def picky(v: int) -> int:
        if v % 3 == 0:
            raise SkipClause("requires fails")
        return v

    r = evaluate_aggregate(spec.clause_ids["g.total"], spec, FakeCtx({"g": picky}))
    assert (r.value, r.evaluated, r.skipped, r.total) == (1 + 2 + 4 + 5 + 7 + 8, 6, 4, 10)
    every = evaluate_aggregate(
        spec.clause_ids["g.fixed"], spec, FakeCtx({"g": lambda v: picky(v) * 0})
    )
    assert (every.skipped, every.evaluated, every.value) == (17, 33, 33)

    def never(v: int) -> int:
        raise SkipClause("never")

    none = evaluate_aggregate(spec.clause_ids["g.worst"], spec, FakeCtx({"g": never}))
    assert (none.holds, none.value, none.evaluated, none.skipped) == (True, None, 0, 255)


def test_sampled_members() -> None:
    spec = spec_of(SMALL)
    ctx = FakeCtx({"g": lambda v: 1}, exhaustive_limit=100, sample=40)
    r = evaluate_aggregate(spec.clause_ids["g.worst"], spec, ctx)
    assert (r.sampled, r.evaluated, r.total, r.value) == (True, 40, 255, 1)
    assert len(ctx.calls) == 40


def test_negative_and_bad_terms_are_errors() -> None:
    spec = spec_of(
        """
        spec t
        fn g(x: u8) -> int
          aggregate neg: sum(v in u8.range(0, 4): g(v)) <= 10
          aggregate div: max(n in range(0, 3): 10 // (1 - n)) <= 10
          aggregate empty: max(v in u8.range(0, 0): g(v)) <= 10
        """
    )
    with pytest.raises(EvalError, match=r"the term -1 for v = 3 is negative.*\(at t.spec:3"):
        evaluate_aggregate(spec.clause_ids["g.neg"], spec, FakeCtx({"g": lambda v: 2 - v}))
    with pytest.raises(EvalError, match="division by zero"):
        evaluate_aggregate(spec.clause_ids["g.div"], spec, FakeCtx())
    with pytest.raises(EvalError, match="over a set with no members has no value"):
        evaluate_aggregate(spec.clause_ids["g.empty"], spec, FakeCtx({"g": _identity}))
    with pytest.raises(EvalError, match="an aggregate clause is"):
        evaluate_aggregate(ast.Clause("aggregate", expr=ast.BoolLit(True)), spec, FakeCtx())


# -- aggregates over floats -------------------------------------------------------------


FLOATS = """
spec t
fn cos16(x: f16) -> f16
  aggregate exact: sum(v in f16.range(-1, 1) - f16.zero: qe(cos16(v), cr.cos(v))) == 0
  aggregate budget: sum(v in f16.range(0, 1): steps(qe(cos16(v), cr.cos(v)))) <= 3
  aggregate nan: all(v in f16.nan | f16.inf: is_nan(cos16(v)))
  aggregate worst: max(v in f16.range(0, 8) | f16.nan: qe(cos16(v), cr.cos(v))) < 1.5
"""


@pytest.mark.slow
def test_aggregates_over_f16() -> None:
    spec = spec_of(FLOATS)

    def off_by_one(v: FloatValue) -> FloatValue:
        y = cr.cos(v)
        return floats.next_up(y) if v == f16(0.5) or v == f16(-0.25) else y

    def nan_at_two(v: FloatValue) -> FloatValue:
        return floats.nan("f16") if v == f16(2.0) else cr.cos(v)

    exact = evaluate_aggregate(spec.clause_ids["cos16.exact"], spec, FakeCtx({"cos16": off_by_one}))
    assert (exact.holds, exact.value, exact.total) == (False, QError(2, 0), 2 * 0x3C00 - 1)
    assert exact.evaluated == exact.total
    assert sorted(floats.format_float(m) for m, _ in exact.worst) == ["-0.25", "0.5"]
    budget = evaluate_aggregate(
        spec.clause_ids["cos16.budget"], spec, FakeCtx({"cos16": off_by_one})
    )
    assert (budget.holds, budget.value, budget.total) == (True, 1, 0x3C00 + 1)
    nans = evaluate_aggregate(spec.clause_ids["cos16.nan"], spec, FakeCtx({"cos16": cr.cos}))
    assert (nans.holds, nans.total) == (True, 2 * 1023 + 2 + 2 - 2)
    worst = evaluate_aggregate(spec.clause_ids["cos16.worst"], spec, FakeCtx({"cos16": nan_at_two}))
    assert (worst.holds, worst.value) == (False, QError(0, 1))
    assert worst.worst == [(f16(2.0), QError(0, 1))]
    fine = evaluate_aggregate(spec.clause_ids["cos16.worst"], spec, FakeCtx({"cos16": off_by_one}))
    assert (fine.holds, fine.value) == (True, QError(1, 0))
    assert fine.bound == Fraction(3, 2)


@pytest.mark.slow
def test_worst_ranks_nan_errors_first() -> None:
    spec = spec_of(FLOATS)

    def bad(v: FloatValue) -> FloatValue:
        if v == f16(1.0):
            return floats.nan("f16")
        if v == f16(3.0):
            return up(cr.cos(v), 5)
        if v == f16(4.0):
            return up(cr.cos(v), 2)
        return cr.cos(v)

    r = evaluate_aggregate(spec.clause_ids["cos16.worst"], spec, FakeCtx({"cos16": bad}))
    assert r.value == QError(5, 1)
    assert [(floats.format_float(m), t) for m, t in r.worst] == [
        ("1.0", QError(0, 1)), ("3.0", QError(5, 0)), ("4.0", QError(2, 0)),
    ]  # fmt: skip


def test_aggregate_set_elements_are_typed_members() -> None:
    spec = spec_of(FLOATS)
    ctx = FakeCtx({"cos16": cr.cos})
    evaluate_aggregate(spec.clause_ids["cos16.budget"], spec, ctx)
    args = [a for _, (a,) in ctx.calls]
    assert all(isinstance(a, FloatValue) and a.fmt == "f16" for a in args)
    assert f16(0.0) in args and f16(-0.0) in args and floats.next_down(f16(1.0)) in args
    assert f16(1.0) not in args
    top = spec.clause_ids["cos16.budget"].expr.left
    assert top.iterable.ty.elem == FloatT("f16")
