"""explain(): why a clause is false, from the example specs and small specs."""

from __future__ import annotations

import math

from eval_support import FakeCtx, example, f64, handle, spec_of

from spectest.eval import Env, explain, holds, snapshot_olds
from spectest.prelude import floats
from spectest.values import EvalError, Some


def _explain(spec, cid: str, env: Env, ctx=None) -> dict[str, str]:
    c = spec.clause_ids[cid]
    ctx = ctx or FakeCtx()
    assert holds(c, env, spec, ctx) is False
    pairs = explain(c.expr, env, spec, ctx)
    assert len({t for t, _ in pairs}) == len(pairs)
    return dict(pairs)


def test_sort_ordered_with_an_unsorted_result() -> None:
    spec = example("sorting")
    got = _explain(spec, "sort.ordered", Env({"xs": (1, 2, 3), "result": (3, 1, 2)}))
    assert got == {"result": "[3, 1, 2]", "is_sorted(result)": "false"}


def test_sort_permutation() -> None:
    spec = example("sorting")
    got = _explain(spec, "sort.permutation", Env({"xs": (1, 2, 2), "result": (1, 2)}))
    assert got == {"result": "[1, 2]", "xs": "[1, 2, 2]", "is_permutation(result, xs)": "false"}


def test_cos_accurate_with_a_three_step_error() -> None:
    spec = example("libm")
    x = f64(1.0)
    good = math.cos(1.0)
    bad = floats.next_up(floats.next_up(floats.next_up(f64(good))))
    got = _explain(spec, "cos.accurate", Env({"x": x, "result": bad}))
    assert list(got) == ["result", "cr.cos(x)", "qe(result, cr.cos(x))"]
    assert (
        got["result"]
        == f"{math.nextafter(math.nextafter(math.nextafter(good, 2), 2), 2)!r} (0x{bad.bits:016x})"
    )
    assert got["cr.cos(x)"] == f"{good!r} (0x{f64(good).bits:016x})"
    assert got["qe(result, cr.cos(x))"] == "3"


def test_cos_accurate_with_a_nan_result() -> None:
    spec = example("libm")
    got = _explain(spec, "cos.accurate", Env({"x": f64(1.0), "result": floats.nan("f64")}))
    assert got["qe(result, cr.cos(x))"] == "1nan"
    got = _explain(spec, "cos.accurate", Env({"x": floats.inf("f64"), "result": f64(0.5)}))
    assert got["cr.cos(x)"] == "nan (0x7ff8000000000000)"
    assert got["qe(result, cr.cos(x))"] == "1nan"


def test_deque_append_with_a_wrong_bounded_append() -> None:
    spec = example("deque")
    append = spec.clause_ids["Deque.append.items"]
    before = [1, 2, 3]
    h = handle("Deque", items=lambda: tuple(before), maxlen=Some(3))
    ctx = FakeCtx()
    olds = snapshot_olds([append], Env({"self": h, "x": 4}), spec, ctx)
    before[:] = [1, 2, 4]
    got = _explain(spec, "Deque.append.items", Env({"self": h, "x": 4}, olds=olds), ctx)
    assert got["ys"] == "[1, 2, 3, 4]"
    assert got["self.items"] == "[1, 2, 4]"
    assert got["is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)"] == "true"
    branch = [t for t in got if t.startswith("if ")]
    assert len(branch) == 1 and got[branch[0]] == "[2, 3, 4]"
    assert next(iter(got)) == "ys"


def test_deque_pop_value_shows_the_index() -> None:
    spec = example("deque")
    pop = spec.interfaces["Deque"].methods[2]
    items = [5, 6, 7]
    h = handle("Deque", items=lambda: tuple(items), maxlen=None)
    olds = snapshot_olds(pop.clauses, Env({"self": h}), spec, FakeCtx())
    items.pop(0)
    got = _explain(spec, "Deque.pop.value", Env({"self": h, "result": 5}, olds=olds))
    assert got["result"] == "5"
    assert got["old(self.items)"] == "[5, 6, 7]"
    assert got["len(old(self.items)) - 1"] == "2"
    assert got["old(self.items)[len(old(self.items)) - 1]"] == "7"


def test_conjunctions_pick_the_first_false_part() -> None:
    spec = example("libm")
    env = Env({"x": f64(0.5), "result": f64(1.5)})
    got = _explain(spec, "cos.bounded", env)
    assert got == {"result": "1.5 (0x3ff8000000000000)"}


def test_negation_and_prelude_predicates() -> None:
    spec = spec_of(
        """
        spec t
        fn cos(x: f64) -> f64
          ensures nonfinite: not is_finite(x) implies is_nan(result)
        """
    )
    env = Env({"x": floats.inf("f64"), "result": f64(0.5)})
    got = _explain(spec, "cos.nonfinite", env)
    assert got == {"result": "0.5 (0x3fe0000000000000)", "is_nan(result)": "false"}


def test_relates_shows_the_planned_call() -> None:
    spec = example("libm")
    ctx = FakeCtx({"cos": lambda x: f64(0.25)})
    env = Env({"x": f64(1.0), "result": f64(0.5)})
    got = _explain(spec, "cos.even", env, ctx)
    assert got["cos(-x)"] == "0.25 (0x3fd0000000000000)"
    assert got["result"] == "0.5 (0x3fe0000000000000)"
    assert got["same(cos(-x), result)"] == "false"


def test_quantifier_shows_the_failing_element() -> None:
    spec = example("frames")
    rows = ((Some(f64(1.0)),), (Some(f64(2.0)), None))
    df = handle("Frame", columns=("a",), rows=rows, nrows=2)
    got = _explain(spec, "Frame.rectangular", Env({"self": df}, fields=df))
    assert got["r"] == "[some(2.0), none]"
    assert got["len(r)"] == "2"
    assert got["len(columns)"] == "1"
    assert got["columns"] == '["a"]'


def test_eq_shows_both_sides() -> None:
    spec = example("frames")
    rows = ((Some(f64(1.0)), None), (Some(f64(2.0)), Some(f64(3.0))))
    df = handle("Frame", columns=("a", "b"), rows=rows, nrows=2)
    out = handle("Frame", columns=("a", "b"), rows=rows, nrows=2)
    env = Env({"df": df, "how": "any", "result": out})
    got = _explain(spec, "dropna.rows", env)
    assert got["result.rows"] == "[[some(1.0), none], [some(2.0), some(3.0)]]"
    filtered = [t for t in got if t.startswith("filter(")]
    assert len(filtered) == 1 and got[filtered[0]] == "[[some(2.0), some(3.0)]]"


def test_errors_inside_explain_are_summarized() -> None:
    spec = spec_of(
        """
        spec t
        fn f(xs: list<i64>) -> i64
          ensures e: xs[result] > 0
          ensures g: result > 0 and xs[5] > 0 or false
        """
    )
    env = Env({"xs": (1,), "result": 3})
    pairs = explain(spec.clause_ids["f.e"].expr, env, spec, FakeCtx())
    assert pairs[0][0] == "xs[result] > 0"
    assert pairs[0][1].startswith("error: index 3 is out of range")
    env = Env({"xs": (1,), "result": 1})
    ((text, value),) = explain(spec.clause_ids["f.g"].expr, env, spec, FakeCtx())
    assert text == "result > 0 and xs[5] > 0 or false"
    assert value.startswith("error: index 5 is out of range")
    assert value.endswith("(at t.spec:4:29: xs[5])")


def test_explain_never_raises() -> None:
    spec = example("sorting")

    class Broken:
        def observe(self, *args: object) -> object:
            raise RuntimeError("boom")

    c = spec.clause_ids["sort_in_place.ordered"]
    pairs = explain(c.expr, Env({}), spec, Broken())
    assert pairs and all(isinstance(t, str) and isinstance(v, str) for t, v in pairs)
    assert "error" in pairs[-1][1]


def test_explain_of_a_true_clause_shows_its_reasons() -> None:
    spec = example("sorting")
    c = spec.clause_ids["sort.ordered"]
    pairs = explain(c.expr, Env({"result": (1, 2)}), spec, FakeCtx())
    assert dict(pairs) == {"result": "[1, 2]", "is_sorted(result)": "true"}


def test_explain_of_a_literal_clause() -> None:
    spec = spec_of(
        """
        spec t
        fn f(a: bool) -> i64
          ensures e: false
          ensures g: a
          ensures h: not (a and result > 1)
        """
    )
    assert explain(spec.clause_ids["f.e"].expr, Env({}), spec, FakeCtx()) == [("false", "false")]
    assert explain(spec.clause_ids["f.g"].expr, Env({"a": False}), spec, FakeCtx()) == [
        ("a", "false")
    ]
    pairs = explain(spec.clause_ids["f.h"].expr, Env({"a": True, "result": 2}), spec, FakeCtx())
    assert pairs == [("a", "true"), ("result", "2")]


def test_explain_limits_and_truncates() -> None:
    spec = spec_of(
        """
        spec t
        fn f(xs: list<i64>) -> list<i64>
          ensures e: result == xs
        """
    )
    xs = tuple(range(1000))
    pairs = explain(spec.clause_ids["f.e"].expr, Env({"xs": xs, "result": ()}), spec, FakeCtx())
    assert dict(pairs)["result"] == "[]"
    assert len(dict(pairs)["xs"]) <= 300 and dict(pairs)["xs"].endswith("...")
    many = spec_of(
        """
        spec t
        fn f(a: i64, b: i64, c: i64, d: i64) -> i64
          ensures e: a == b or b == c or c == d or d == a
        """
    )
    env = Env({"a": 1, "b": 2, "c": 3, "d": 4})
    assert len(explain(many.clause_ids["f.e"].expr, env, many, FakeCtx(), limit=3)) == 3


def test_implies_with_a_failing_antecedent_error() -> None:
    spec = spec_of(
        """
        spec t
        fn f(o: option<i64>) -> i64
          ensures e: not (unwrap(o) > 0 implies result > 0)
        """
    )
    pairs = explain(spec.clause_ids["f.e"].expr, Env({"o": None, "result": 1}), spec, FakeCtx())
    assert pairs[0][1].startswith("error: unwrap: the option is none")


def test_snapshot_error_is_explained() -> None:
    spec = example("deque")
    pop = spec.interfaces["Deque"].methods[2]
    h = handle("Deque", items=(), maxlen=None)
    olds = snapshot_olds(pop.clauses, Env({"self": h}), spec, FakeCtx())
    c = spec.clause_ids["Deque.pop.value"]
    env = Env({"self": h, "result": 1}, olds=olds)
    try:
        holds(c, env, spec, FakeCtx())
    except EvalError:
        pass
    pairs = explain(c.expr, env, spec, FakeCtx())
    assert pairs[0][1].startswith("error: index -1 is out of range")
