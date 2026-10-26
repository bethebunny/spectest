"""Quantized errors (qe, qerr, cr.*), max comprehensions and aggregate clauses in the front end."""

import pytest

from spectest import ast
from spectest.lang import Resolution, Spec, SpecCheckError, check, load_source, parse
from spectest.types import BOOL, INT, QERR, REAL, FloatT, SetT

F16, F32, F64 = FloatT("f16"), FloatT("f32"), FloatT("f64")


def ok(body: str) -> Spec:
    return check(parse("spec t\n" + body, "t.spec"))


def fails(body: str, *fragments: str) -> list[str]:
    with pytest.raises(SpecCheckError) as info:
        ok(body)
    msgs = [d.message for d in info.value.diagnostics]
    for fragment in fragments:
        assert any(fragment in m for m in msgs), f"{fragment!r} not in {msgs}"
    return msgs


def value_ty(params: str, expr: str) -> object:
    spec = ok(f"fn f({params})\n  ensures e: let v = {expr} in true\n")
    let = spec.clause_ids["f.e"].expr
    assert isinstance(let, ast.Let)
    return let.value.ty


def aggregate(clause: str, decls: str = "") -> Spec:
    return ok(f"{decls}fn f(x: f16) -> f16\n  aggregate a: {clause}\n")


def aggregate_fails(clause: str, *fragments: str, decls: str = "") -> list[str]:
    return fails(f"{decls}fn f(x: f16) -> f16\n  aggregate a: {clause}\n", *fragments)


class TestQerrTyping:
    @pytest.mark.parametrize(
        "expr",
        [
            "qe(x, y) <= 1",
            "qe(x, y) < 1.5",
            "qe(x, y) == 0",
            "qe(x, y) != 0",
            "qe(x, y) >= qe(y, x)",
            "0 < qe(x, y)",
            "qe(x, y) > n",
            "qe(x, y) == qe(y, x)",
            "qe(x, y) + qe(x, x) <= 2",
            "qe(x, y) in [qe(x, x)]",
            "distinct([qe(x, y), qe(y, x)])",
            "steps(qe(x, y)) < 2 and nans(qe(x, y)) == 0",
            "(if is_nan(x) then qe(x, x) else qe(x, y)) <= 1",
        ],
    )
    def test_accepted(self, expr: str):
        ok(f"fn f(x: f64, y: f64, n: u8)\n  ensures {expr}\n")

    @pytest.mark.parametrize(
        ("expr", "message"),
        [
            ("qe(x, y) <= x", "compares a qerr with a qerr or a number"),
            ("qe(x, y) == x", "but the other side is f64"),
            ('qe(x, y) == "a"', "but the other side is string"),
            ("qe(x, y) - qe(x, y) == 0", "quantized errors only add to each other"),
            ("qe(x, y) + 1 == 0", "cannot apply + to qerr and int"),
            ("qe(x, y) * 2 == 0", "cannot apply * to qerr and int"),
            ("-qe(x, y) == 0", "unary - needs a number"),
            ("sorted([qe(x, y)]) == []", "qerr has no total order"),
            ("(if true then qe(x, y) else 0) == 0", "different types: qerr and int"),
        ],
    )
    def test_rejected(self, expr: str, message: str):
        fails(f"fn f(x: f64, y: f64)\n  ensures {expr}\n", message)

    def test_comparison_types(self):
        spec = ok("fn f(x: f32) -> f32\n  ensures a: qe(result, cr.cos(x)) <= 1\n")
        e = spec.clause_ids["f.a"].expr
        assert isinstance(e, ast.Binary)
        assert (e.ty, e.left.ty, e.right.ty) == (BOOL, QERR, INT)
        assert e.left.func.ty.result == QERR


class TestMax:
    @pytest.mark.parametrize(
        ("params", "expr", "ty"),
        [
            ("xs: list<u8>", "max(v in xs: v)", INT),
            ("xs: list<int>", "max(v in xs: v / 2)", REAL),
            ("xs: list<f64>", "max(v in xs: v)", REAL),
            ("xs: list<f64>", "max(v in xs: qe(v, cr.sqrt(v)))", QERR),
            ("xs: list<f64>", "sum(v in xs: qe(v, cr.sqrt(v)))", QERR),
            ("xs: list<f64>", "sum(v in xs: steps(qe(v, v)))", INT),
        ],
    )
    def test_types(self, params: str, expr: str, ty: object):
        assert value_ty(params, expr) == ty

    def test_body_must_be_a_number_or_qerr(self):
        fails(
            "fn f(xs: list<string>)\n  ensures let v = max(s in xs: s) in true\n",
            "max(...) takes the largest of numbers or qerr values, but the body is string",
        )
        fails(
            "fn f(xs: list<bool>)\n  ensures let v = sum(s in xs: s) in true\n",
            "sum(...) adds numbers or qerr values, but the body is bool",
        )


class TestAggregateShapes:
    @pytest.mark.parametrize(
        "clause",
        [
            "sum(v in f16.all: qe(f(v), cr.cos(v))) == 0",
            "sum(v in f16.finite: qe(f(v), cr.cos(v))) <= 100",
            "sum(v in f16.finite: steps(qe(f(v), cr.cos(v)))) < 2 * 50",
            "max(v in f16.finite - f16.zero: qe(f(v), cr.cos(v))) <= 1",
            "max(v in f16.range(-1, 1): qe(f(v), cr.cos(v))) < 1.5",
            "max(v in f16.all & {0, 1, 0.5}: steps(qe(f(v), cr.cos(v)))) <= i8.max",
            "all(v in f16.nan: is_nan(f(v)))",
            'all(v in f16.pattern("0 11111 0*") | f16.zero: not is_nan(f(v)))',
            "sum(v in [1, 2, 3]: qe(f(v), cr.cos(f(v)))) <= 3",
            "max(n in range(0, 10): n) <= 9",
            "all(v in f16.all: same(f(v), g(v)))",
        ],
    )
    def test_accepted(self, clause: str):
        aggregate(clause, decls="fn g(x: f16) -> f16\n")

    def test_resolutions_and_types(self):
        spec = aggregate("sum(v in f16.finite - f16.zero: qe(f(v), cr.cos(v))) == 0")
        c = spec.clause_ids["f.a"]
        assert c.kind == "aggregate"
        assert c.text == "aggregate a: sum(v in f16.finite - f16.zero: qe(f(v), cr.cos(v))) == 0"
        e = c.expr
        assert isinstance(e, ast.Binary) and isinstance(e.left, ast.Comprehension)
        top = e.left
        assert top.iterable.ty == SetT(F16) and top.ty == QERR
        assert spec.resolution[top.iterable.left] == Resolution("type_const", "finite", F16)
        call = top.body.args[0]
        assert spec.resolution[call] == Resolution("spec_fn", "f", spec.fns["f"])
        (v,) = [n for n in ast.walk(call) if isinstance(n, ast.Name) and n.id == "v"]
        assert v.ty == F16 and spec.resolution[v] == Resolution("local", "v", top)

    def test_set_constructor_resolution(self):
        spec = ok(
            "fn f(x: f32) -> f32\n"
            "  aggregate worst: max(v in f32.range(-1, 1): qe(f(v), cr.cos(v))) <= 0\n"
        )
        top = spec.clause_ids["f.worst"].expr.left
        assert top.iterable.ty == SetT(F32)
        assert spec.resolution[top.iterable] == Resolution("set_ctor", "range", F32)

    def test_clause_ids(self):
        spec = ok(
            "fn cos16(x: f16) -> f16\n"
            "  ensures accurate: qe(result, cr.cos(x)) <= 1\n"
            "  aggregate correctly_rounded: sum(v in f16.all: qe(cos16(v), cr.cos(v))) == 0\n"
            "  aggregate max(v in f16.all: qe(cos16(v), cr.cos(v))) <= 1\n"
        )
        assert list(spec.clause_ids) == [
            "cos16.accurate", "cos16.correctly_rounded", "cos16#3",
        ]  # fmt: skip

    @pytest.mark.parametrize(
        ("clause", "message"),
        [
            ("max(v in f16.all: qe(f(v), cr.cos(v))) == 0", "one of the shapes"),
            ("sum(v in f16.all: qe(f(v), cr.cos(v))) >= 1", "one of the shapes"),
            ("sum(v in f16.all: qe(f(v), cr.cos(v))) > 1", "one of the shapes"),
            ("1 >= sum(v in f16.all: qe(f(v), cr.cos(v)))", "one of the shapes"),
            ("sum(v in f16.all: qe(f(v), cr.cos(v))) == 1", "only for c = 0"),
            ("exists(v in f16.all: is_nan(f(v)))", "one of the shapes"),
            ("count(v in f16.all: is_nan(f(v))) <= 1", "one of the shapes"),
            ("is_nan(f(x))", "one of the shapes"),
            ("true", "one of the shapes"),
            ("all(v in f16.all: is_nan(f(v))) and true", "one of the shapes"),
        ],
    )
    def test_bad_shapes(self, clause: str, message: str):
        aggregate_fails(clause, message)

    def test_bound_is_a_constant(self):
        aggregate_fails(
            "sum(v in f16.all: qe(f(v), cr.cos(v))) <= len([1])",
            "the bound of an aggregate clause must be a constant",
        )
        aggregate_fails(
            "max(n in range(0, 3): n) <= max(m in range(0, 3): m)",
            "the bound of an aggregate clause must be a constant",
        )
        aggregate_fails(
            "max(v in f16.all: qe(f(v), cr.cos(v))) <= f16.max",
            "but the other side is f16",
        )


class TestAggregateScope:
    def test_parameters_result_and_old(self):
        aggregate_fails(
            "sum(v in f16.all: qe(f(v), cr.cos(x))) <= 3",
            "an aggregate clause cannot use the parameter x of f",
        )
        aggregate_fails(
            "sum(v in f16.all: qe(result, cr.cos(v))) <= 3",
            "evaluated once over a set of inputs, so there is no result",
        )
        msgs = aggregate_fails(
            "sum(v in f16.all: steps(qe(old(f(v)), v))) <= 3",
            "old(...) has no meaning in an aggregate clause",
        )
        assert len(msgs) == 1

    def test_spec_functions_are_planned_calls(self):
        spec = aggregate("all(v in f16.all: same(g(v), f(v)))", decls="fn g(y: f16) -> f16\n")
        calls = [
            spec.resolution[n].name
            for n in ast.walk(spec.clause_ids["f.a"].expr)
            if isinstance(n, ast.Call) and spec.resolution[n].kind == "spec_fn"
        ]
        assert calls == ["g", "f"]

    def test_only_in_functions(self):
        fails(
            "interface Q\n  observe n: int\n  new make() -> Q\n"
            "    aggregate a: max(i in range(0, 3): i) <= 3\n",
            "aggregate clauses belong to functions (fn), not to a constructor",
        )
        fails(
            "interface Q\n  observe n: int\n  method m(self)\n"
            "    aggregate a: max(i in range(0, 3): i) <= 3\n",
            "aggregate clauses belong to functions (fn), not to a method",
        )
        fails(
            "model M\n  observe n: int\n  aggregate a: max(i in range(0, 3): i) <= 3\n",
            "aggregate belongs to a function, constructor or method, not to model M",
        )

    def test_sets_only_at_the_top_of_an_aggregate(self):
        aggregate_fails(
            "all(v in f16.all: all(w in f16.nan: same(f(v), w)))",
            "all(...) ranges over a set such as f16.all only as the top comprehension",
        )
        fails(
            "fn f(x: f16) -> f16\n  ensures all(v in f16.nan: is_nan(v))\n",
            "only as the top comprehension of an aggregate clause",
        )
        fails(
            "fn f(x: f16) -> f16\n  ensures let s = sum(v in f16.range(0, 1): steps(qe(v, x))) "
            "in s >= 0\n",
            "sum(...) ranges over a set such as f16.all only as the top comprehension",
        )

    def test_set_iterables_must_be_typed_sets(self):
        aggregate_fails(
            "sum(v in {1, 2}: steps(qe(f(v), cr.cos(v)))) <= 1",
            "the type of this set is unknown",
        )
        aggregate_fails(
            "sum(v in f16.all | f32.nan: steps(qe(f(v), cr.cos(v)))) <= 1",
            "cannot combine a set of f16 with a set of f32",
        )
        aggregate_fails("all(v in f16.all - x: true)", "cannot use the parameter x")

    def test_set_bounds_are_checked_on_load(self):
        with pytest.raises(SpecCheckError, match="f32.range bound 0.1 is not exactly"):
            load_source(
                "spec t\nfn f(x: f32) -> f32\n"
                "  aggregate a: sum(v in f32.range(-1, 0.1): qe(f(v), cr.cos(v))) <= 3\n"
            )
        spec = load_source(
            "spec t\nfn f(x: f32) -> f32\n"
            "  aggregate a: max(v in f32.nan & f32.zero: qe(f(v), cr.cos(v))) <= 3\n"
        )
        (warning,) = spec.warnings
        assert "f: aggregate a: the set it ranges over is empty" in warning.message


class TestOldOfClauseLocals:
    IFACE = "interface S\n  observe items: list<int>\n  new e() -> S\n  method m(self)\n"

    def test_comprehension_variable(self):
        fails(
            self.IFACE + "    ensures all(i in range(0, len(self.items)): old(self.items[i]) == "
            "self.items[i])\n",
            "old(...) is evaluated before the call, so it cannot use i, which all(...) binds "
            "inside this clause: bind old(...) of the state first, e.g. let xs = "
            "old(self.items)",
        )

    def test_let_variable(self):
        fails(
            self.IFACE + "    ensures let n = 1 in old(len(self.items) + n) == n\n",
            "cannot use n, which let binds inside this clause",
        )

    def test_names_bound_inside_old_and_the_recommended_form(self):
        ok(
            self.IFACE + "    ensures a: old(let n = len(self.items) in n + 1) >= 1\n"
            "    ensures b: old(all(i in self.items: i > 0)) or true\n"
            "    ensures c: let xs = old(self.items) in "
            "all(i in range(0, len(xs)): xs[i] == self.items[i])\n"
        )
