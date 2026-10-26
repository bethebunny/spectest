"""Literals, names, operators, indexing, comprehensions and error handling."""

from __future__ import annotations

from fractions import Fraction

import pytest
from eval_support import FakeCtx, f32, f64, handle, probe_spec, spec_of, value_of

from spectest import ast
from spectest.eval import Env, evaluate, holds
from spectest.prelude import floats
from spectest.values import (
    NEG_INF,
    POS_INF,
    BindingError,
    EvalError,
    FloatValue,
    MapValue,
    RecordValue,
    SkipClause,
    Some,
)

# -- literals ------------------------------------------------------------------


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("42", 42),
        ("0x10", 16),
        ("1.5", Fraction(3, 2)),
        ("0x1p-26", Fraction(1, 2**26)),
        ('"hi"', "hi"),
        ("true", True),
        ("false", False),
        ("[1, 2, 3]", (1, 2, 3)),
        ('(1, "a")', (1, "a")),
        ("[]", ()),
        ("[[1], [2, 3]]", ((1,), (2, 3))),
    ],
)
def test_literals(expr: str, expected: object) -> None:
    v = value_of("f()", expr)
    assert v == expected and type(v) is type(expected)


def test_none_literal() -> None:
    assert value_of("f(x: option<i64>)", "if is_none(x) then none else x", x=None) is None


def test_set_literal_is_an_eval_error() -> None:
    spec = spec_of(
        """
        spec t
        fn f(x: u8) -> u8
          partition x
            small = {0, 1}
            rest = u8.all - small
        """
    )
    part = spec.fns["f"].partitions[0]
    with pytest.raises(EvalError, match="partition set"):
        evaluate(part.classes[0].expr, Env({"x": 0}), spec, FakeCtx())
    with pytest.raises(EvalError, match="partition set"):
        evaluate(part.classes[1].expr, Env({"x": 0}), spec, FakeCtx())


def test_set_constants_and_constructors_are_eval_errors() -> None:
    spec = spec_of(
        """
        spec t
        fn f(x: f64) -> f64
          partition x
            nan = f64.nan
            low = f64.range(none, 0)
            rest = f64.all - nan - low
        """
    )
    classes = spec.fns["f"].partitions[0].classes
    for cls in classes:
        with pytest.raises(EvalError, match="partition set"):
            evaluate(cls.expr, Env({"x": f64(1.0)}), spec, FakeCtx())


# -- names ---------------------------------------------------------------------


def test_param_and_result() -> None:
    spec = spec_of(
        """
        spec t
        fn f(x: i64) -> i64
          ensures e: result == x + 1
        """
    )
    c = spec.clause_ids["f.e"]
    assert holds(c, Env({"x": 1, "result": 2}), spec, FakeCtx())
    assert not holds(c, Env({"x": 1, "result": 3}), spec, FakeCtx())
    with pytest.raises(EvalError, match="no value for the result"):
        holds(c, Env({"x": 1}), spec, FakeCtx())
    with pytest.raises(EvalError, match="parameter x"):
        holds(c, Env({"result": 1}), spec, FakeCtx())


def test_let_shadowing_and_nesting() -> None:
    assert value_of("f()", "let a = 1 in let a = a + 10 in a * 2") == 22
    assert value_of("f()", "let a = 1 in (let a = 5 in a) + a") == 6
    assert value_of("f(xs: list<i64>)", "map(x in xs: let y = x * x in y + x)", xs=(1, 2)) == (2, 6)


def test_comprehension_variable_shadows_let() -> None:
    v = value_of("f(xs: list<i64>)", "let x = 100 in map(x in xs: x + 1)", xs=(1, 2))
    assert v == (2, 3)
    v = value_of("f(xs: list<i64>)", "let x = 100 in sum(y in xs: x + y)", xs=(1, 2))
    assert v == 203


def test_enum_members() -> None:
    decls = "enum Color { Red, Green }"
    assert value_of("f(c: Color)", "c == Color.Red", decls=decls, c="Red") is True
    assert value_of("f(c: Color)", "c == Green", decls=decls, c="Red") is False
    assert value_of("f()", "Color.Green", decls=decls) == "Green"


def test_record_fields() -> None:
    decls = "record Point { x: i64, y: i64 }"
    p = RecordValue("Point", (("x", 3), ("y", 4)))
    assert value_of("f(p: Point)", "p.x * p.x + p.y * p.y", decls=decls, p=p) == 25


def test_fields_and_self_in_invariants() -> None:
    spec = spec_of(
        """
        spec t
        model Bag
          observe items: list<i64>
          observe count(x: i64): u64
          invariant sized: len(items) >= 0 and len(self.items) == len(items)
          invariant counted: all(x in items: count(x) >= 1)
        """
    )
    h = handle("Bag", items=(1, 2, 2), count=lambda x: (1, 2, 2).count(x))
    ctx = FakeCtx()
    env = Env({"self": h}, fields=h)
    assert holds(spec.clause_ids["Bag.sized"], env, spec, ctx)
    assert holds(spec.clause_ids["Bag.counted"], env, spec, ctx)
    assert "count" in {name for _, name, _ in ctx.observations}
    assert holds(spec.clause_ids["Bag.counted"], Env({}, fields=h), spec, ctx)
    assert holds(spec.clause_ids["Bag.sized"], Env({"self": h}), spec, ctx)
    bad = handle("Bag", items=(1, 3), count=lambda x: 0)
    assert not holds(spec.clause_ids["Bag.counted"], Env({}, fields=bad), spec, ctx)
    with pytest.raises(EvalError, match="Env.fields"):
        holds(spec.clause_ids["Bag.counted"], Env({}), spec, ctx)


# -- boolean operators and short-circuiting --------------------------------------


@pytest.mark.parametrize(
    ("a", "b", "op", "expected"),
    [
        (True, True, "and", True),
        (True, False, "and", False),
        (False, True, "or", True),
        (False, False, "or", False),
        (True, False, "implies", False),
        (False, False, "implies", True),
        (True, True, "implies", True),
    ],
)
def test_boolean_operators(a: bool, b: bool, op: str, expected: bool) -> None:
    assert value_of("f(a: bool, b: bool)", f"a {op} b", a=a, b=b) is expected


def test_not() -> None:
    assert value_of("f(a: bool)", "not a", a=True) is False
    assert value_of("f(a: bool)", "not not a", a=True) is True


@pytest.mark.parametrize(
    "expr",
    [
        "len(xs) > 0 implies xs[0] > 0",
        "len(xs) == 0 or xs[0] > 0",
        "not (len(xs) > 0 and xs[0] > 0)",
        "if len(xs) == 0 then true else xs[0] > 0",
        "exists(x in xs: x > 0) implies unwrap(none) > 0",
        "count(x in xs: xs[x] > 0) == 0",
    ],
)
def test_short_circuit_guards_errors(expr: str) -> None:
    assert value_of("f(xs: list<i64>)", expr, xs=()) is True


def test_unguarded_error_propagates() -> None:
    with pytest.raises(EvalError, match="index 0 is out of range"):
        value_of("f(xs: list<i64>)", "xs[0] > 0 or len(xs) == 0", xs=())


def test_quantifiers_short_circuit_left_to_right() -> None:
    sig = "f(xs: list<i64>)"
    assert value_of(sig, "all(x in xs: x > 0 and 10 // x > 0)", xs=(-1, 0)) is False
    assert value_of(sig, "exists(x in xs: x == 2 or 10 // x > 0)", xs=(2, 0)) is True
    with pytest.raises(EvalError, match="division by zero"):
        value_of(sig, "all(x in xs: 10 // x > 0)", xs=(0, -1))


# -- arithmetic -----------------------------------------------------------------


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("a + b", 10),
        ("a - b", 4),
        ("a * b", 21),
        ("a // b", 2),
        ("a % b", 1),
        ("-a // b", -3),
        ("-a % b", 2),
        ("a % -b", -2),
        ("a / b", Fraction(7, 3)),
        ("a / 7", Fraction(1)),
        ("-a", -7),
        ("a * a * a * a * a * a * a * a * a * a * a * a", 7**12),
    ],
)
def test_integer_arithmetic(expr: str, expected: object) -> None:
    v = value_of("f(a: i8, b: u8)", expr, a=7, b=3)
    assert v == expected and type(v) is type(expected)


def test_fixed_width_arithmetic_never_overflows() -> None:
    v = value_of("f(a: i64)", "a + a", a=2**63 - 1)
    assert v == 2**64 - 2
    assert value_of("f(a: u8)", "a - 1", a=0) == -1
    assert value_of("f(a: i8)", "-a", a=-128) == 128


@pytest.mark.parametrize(
    ("expr", "message"),
    [
        ("a // 0", "division by zero"),
        ("a % 0", "division by zero"),
        ("a / 0", "division by zero"),
    ],
)
def test_division_by_zero(expr: str, message: str) -> None:
    with pytest.raises(EvalError, match=message):
        value_of("f(a: i64)", expr, a=1)


def test_float_arithmetic_promotes_to_real() -> None:
    v = value_of("f(x: f64, y: f64)", "x + y", x=f64(0.1), y=f64(0.2))
    assert v == Fraction(0.1) + Fraction(0.2)
    assert type(v) is Fraction
    assert value_of("f(x: f64)", "x * 2", x=f64(1.5)) == 3
    assert type(value_of("f(x: f64)", "x * 2", x=f64(1.5))) is Fraction
    assert value_of("f(x: f32)", "x - 1", x=f32(0.5)) == Fraction(-1, 2)


def test_infinities_in_arithmetic() -> None:
    inf = floats.inf("f64")
    assert value_of("f(x: f64)", "x + 1", x=inf) is POS_INF
    assert value_of("f(x: f64)", "-x - 1", x=inf) is NEG_INF
    with pytest.raises(EvalError, match="undefined"):
        value_of("f(x: f64)", "x - x", x=inf)


def test_nan_promotion_is_an_eval_error() -> None:
    with pytest.raises(EvalError, match="NaN"):
        value_of("f(x: f64)", "x + 1", x=floats.nan("f64"))
    with pytest.raises(EvalError, match="NaN"):
        value_of("f(x: f64)", "x < 1", x=floats.nan("f64"))
    with pytest.raises(EvalError, match="NaN"):
        value_of("f(x: f64)", "real(x)", x=floats.nan("f64"))


def test_unary_minus_on_floats_flips_the_sign_bit() -> None:
    for fmt, make in (("f64", f64), ("f32", f32)):
        v = value_of(f"f(x: {fmt})", "-x", x=make(0.0))
        assert isinstance(v, FloatValue) and v.fmt == fmt
        assert floats.signbit(v) and floats.is_zero(v)
        assert value_of(f"f(x: {fmt})", "-x", x=make(-2.5)) == make(2.5)
    n = floats.nan("f64", payload=5)
    neg = value_of("f(x: f64)", "-x", x=n)
    assert floats.is_nan(neg) and floats.signbit(neg) and neg.bits ^ n.bits == 1 << 63


def test_unary_minus_on_reals() -> None:
    assert value_of("f(x: f64)", "-real(x)", x=f64(0.5)) == Fraction(-1, 2)
    assert value_of("f()", "-1.5") == Fraction(-3, 2)


# -- comparisons and equality -------------------------------------------------------


@pytest.mark.parametrize(
    ("expr", "expected"),
    [
        ("a < b", True),
        ("a <= a", True),
        ("a > b", False),
        ("b >= a", True),
        ("x < 1", True),
        ("-1 <= x", True),
        ("x > 0.25", True),
        ("x >= 0.5", True),
        ("x <= 0.5", True),
        ("real(x) == 0.5", True),
        ('"abc" < "abd"', True),
        ('"b" > "abc"', True),
        ("(1, 2) < (1, 3)", True),
        ("[1, 2] < [1, 2, 0]", True),
        ("false < true", True),
    ],
)
def test_comparisons(expr: str, expected: bool) -> None:
    assert value_of("f(a: i64, b: u8, x: f64)", expr, a=-1, b=200, x=f64(0.5)) is expected


def test_infinite_comparisons() -> None:
    inf = floats.inf("f64")
    assert value_of("f(x: f64)", "x > 1e308", x=inf) is True
    assert value_of("f(x: f64)", "-x < -1e308", x=inf) is True


def test_equality_is_structural() -> None:
    sig = "f(a: list<option<i64>>, b: list<option<i64>>)"
    assert value_of(sig, "a == b", a=(Some(1), None), b=(Some(1), None)) is True
    assert value_of(sig, "a != b", a=(Some(1), None), b=(None, Some(1))) is True
    assert value_of(sig, "a == b", a=(Some(1),), b=(Some(1), None)) is False


def test_map_equality_ignores_insertion_order() -> None:
    m1 = MapValue((("a", 1), ("b", 2)))
    m2 = MapValue((("b", 2), ("a", 1)))
    assert m1 != m2
    assert value_of("f(a: map<string, i64>, b: map<string, i64>)", "a == b", a=m1, b=m2) is True
    m3 = MapValue((("b", 2), ("a", 3)))
    assert value_of("f(a: map<string, i64>, b: map<string, i64>)", "a == b", a=m1, b=m3) is False


def test_int_real_equality_is_by_value() -> None:
    assert value_of("f(a: i64)", "a / 2 == 2", a=4) is True
    assert value_of("f(a: i64)", "a == 4.0", a=4) is True


def test_bool_never_equals_int() -> None:
    assert value_of("f(xs: list<bool>)", "true in xs", xs=(1,)) is False


def test_membership() -> None:
    assert value_of("f(xs: list<i64>)", "2 in xs", xs=(1, 2)) is True
    assert value_of("f(xs: list<i64>)", "3 in xs", xs=(1, 2)) is False
    m = MapValue((("k", 1),))
    assert value_of("f(m: map<string, i64>)", '"k" in m', m=m) is True
    assert value_of("f(m: map<string, i64>)", '"v" in m', m=m) is False
    assert value_of("f(s: string)", '"ell" in s', s="hello") is True
    assert value_of("f(s: string)", '"" in s', s="") is True
    assert value_of("f(s: string)", '"le" in s', s="hello") is False
    assert value_of("f(xs: list<(i64, string)>)", '(1, "a") in xs', xs=((1, "a"),)) is True


# -- concatenation ---------------------------------------------------------------


def test_concatenation() -> None:
    assert value_of("f(xs: list<i64>)", "xs + [3] + xs", xs=(1, 2)) == (1, 2, 3, 1, 2)
    assert value_of("f(s: string)", 's + "!"', s="hi") == "hi!"
    assert value_of("f(b: bytes)", "b + b", b=b"\x00\xff") == b"\x00\xff\x00\xff"
    assert value_of("f(xs: list<i64>)", "xs + []", xs=[1]) == (1,)


# -- indexing and slicing ----------------------------------------------------------


def test_index() -> None:
    assert value_of("f(xs: list<i64>)", "xs[1]", xs=(5, 6)) == 6
    assert value_of("f(s: string)", "s[0]", s="héllo"[1:]) == "é"
    v = value_of("f(b: bytes)", "b[1]", b=b"\x01\xfe")
    assert v == 254 and type(v) is int
    m = MapValue(((1, "one"), (2, "two")))
    assert value_of("f(m: map<i64, string>)", "m[2]", m=m) == "two"


@pytest.mark.parametrize(
    ("expr", "message"),
    [
        ("xs[2]", "index 2 is out of range for a list of length 2"),
        ("xs[0 - 1]", "index -1 is out of range"),
        ("xs[len(xs)]", "out of range"),
    ],
)
def test_index_out_of_range(expr: str, message: str) -> None:
    with pytest.raises(EvalError, match=message):
        value_of("f(xs: list<i64>)", expr, xs=(5, 6))


def test_missing_key() -> None:
    m = MapValue(((1, "one"),))
    with pytest.raises(EvalError, match="key 2 is not in the map"):
        value_of("f(m: map<i64, string>)", "m[2]", m=m)


def test_map_lookup_does_not_confuse_bool_and_int() -> None:
    m = MapValue(((True, "t"),))
    with pytest.raises(EvalError, match="not in the map"):
        value_of("f(m: map<i64, string>)", "m[1]", m=m)


def test_slices() -> None:
    sig = "f(xs: list<i64>, s: string, b: bytes)"
    vals = {"xs": (1, 2, 3), "s": "abc", "b": b"xyz"}
    assert value_of(sig, "xs[1:3]", **vals) == (2, 3)
    assert value_of(sig, "xs[0:0]", **vals) == ()
    assert value_of(sig, "xs[3:3]", **vals) == ()
    assert value_of(sig, "s[1:2]", **vals) == "b"
    assert value_of(sig, "b[0:2]", **vals) == b"xy"
    assert value_of("f(xs: list<i64>)", "xs[0:1]", xs=[7, 8]) == (7,)


@pytest.mark.parametrize("bounds", ["2:1", "0:4", "0 - 1:1", "4:4"])
def test_slice_bounds_are_checked(bounds: str) -> None:
    with pytest.raises(EvalError, match="slice"):
        value_of("f(xs: list<i64>)", f"xs[{bounds}]", xs=(1, 2, 3))


def test_tuple_index() -> None:
    assert value_of("f(p: (i64, string))", "p.1", p=(1, "a")) == "a"
    assert value_of("f(ps: list<(i64, i64)>)", "map(p in ps: p.0)", ps=((1, 2), (3, 4))) == (1, 3)


# -- if and let ------------------------------------------------------------------


def test_if() -> None:
    assert value_of("f(a: i64)", "if a > 0 then a else -a", a=-3) == 3
    assert value_of("f(a: i64)", "if a > 0 then a else -a", a=3) == 3


def test_let_and_if_as_operands() -> None:
    sig = "f(a: i64)"
    assert value_of(sig, "a > 0 implies let b = a * 2 in b > a", a=3) is True
    assert value_of(sig, "1 + if a > 0 then a else 0", a=3) == 4


# -- comprehensions ---------------------------------------------------------------


def test_comprehensions_over_lists() -> None:
    sig = "f(xs: list<i64>)"
    xs = (3, -1, 4, -1, 5)
    assert value_of(sig, "all(x in xs: x != 0)", xs=xs) is True
    assert value_of(sig, "exists(x in xs: x == 4)", xs=xs) is True
    assert value_of(sig, "count(x in xs: x < 0)", xs=xs) == 2
    assert value_of(sig, "sum(x in xs: x)", xs=xs) == 10
    assert value_of(sig, "map(x in xs: x * x)", xs=xs) == (9, 1, 16, 1, 25)
    assert value_of(sig, "filter(x in xs: x > 0)", xs=xs) == (3, 4, 5)
    assert value_of(sig, "all(x in xs: false)", xs=()) is True
    assert value_of(sig, "exists(x in xs: true)", xs=()) is False


def test_comprehensions_over_strings_bytes_and_maps() -> None:
    assert value_of("f(s: string)", 'count(c in s: c == "l")', s="hello") == 2
    assert value_of("f(s: string)", "map(c in s: c)", s="añb") == ("a", "ñ", "b")
    assert value_of("f(b: bytes)", "sum(x in b: x)", b=b"\x01\x02\xff") == 258
    assert value_of("f(b: bytes)", "all(x in b: x < 256)", b=b"\xff") is True
    m = MapValue((("a", 1), ("b", 2)))
    assert value_of("f(m: map<string, i64>)", "map(k in m: k)", m=m) == ("a", "b")
    assert value_of("f(m: map<string, i64>)", "sum(k in m: m[k])", m=m) == 3


def test_comprehensions_over_range() -> None:
    assert value_of("f(n: u8)", "map(i in range(0, n): i * i)", n=4) == (0, 1, 4, 9)
    assert value_of("f(n: u8)", "sum(i in range(0, n): i)", n=101) == 5050


def test_sum_types() -> None:
    v = value_of("f(xs: list<i64>)", "sum(x in xs: x)", xs=())
    assert v == 0 and type(v) is int
    v = value_of("f(xs: list<f64>)", "sum(x in xs: x)", xs=())
    assert v == 0 and type(v) is Fraction
    v = value_of("f(xs: list<f64>)", "sum(x in xs: x)", xs=(f64(0.5), f64(0.25)))
    assert v == Fraction(3, 4) and type(v) is Fraction
    v = value_of("f(xs: list<i64>)", "sum(x in xs: x / 2)", xs=(1, 2))
    assert v == Fraction(3, 2)
    v = value_of("f(xs: list<i64>)", "sum(x in xs: x / 2)", xs=(2, 2))
    assert v == 2 and type(v) is Fraction
    with pytest.raises(EvalError, match="NaN"):
        value_of("f(xs: list<f64>)", "sum(x in xs: x)", xs=(floats.nan("f64"),))


def test_nested_comprehensions() -> None:
    rows = ((1, 2), (3,))
    sig = "f(rows: list<list<i64>>)"
    assert value_of(sig, "sum(r in rows: sum(c in r: c))", rows=rows) == 6
    assert value_of(sig, "map(r in rows: filter(c in r: c > 1))", rows=rows) == ((2,), (3,))
    assert value_of(sig, "all(r in rows: exists(c in r: c > 2))", rows=rows) is False


# -- errors -----------------------------------------------------------------------


def test_eval_errors_name_the_expression_and_location() -> None:
    spec, node = probe_spec("f(xs: list<i64>)", "len(xs) + xs[5]")
    with pytest.raises(EvalError) as info:
        evaluate(node, Env({"xs": (1,)}), spec, FakeCtx())
    msg = str(info.value)
    assert "index 5 is out of range" in msg
    assert "t.spec:4:" in msg and "xs[5]" in msg
    assert info.value.location.startswith("t.spec:4:")  # type: ignore[attr-defined]
    assert info.value.message.startswith("index 5")  # type: ignore[attr-defined]


def test_prelude_errors_are_located() -> None:
    spec, node = probe_spec("f(o: option<i64>)", "unwrap(o) + 1")
    with pytest.raises(
        EvalError, match=r"unwrap: the option is none \(at t\.spec:4:\d+: unwrap\(o\)\)"
    ):
        evaluate(node, Env({"o": None}), spec, FakeCtx())


class _Boom:
    def __init__(self, exc: BaseException) -> None:
        self.exc = exc

    def observe(self, h: object, name: str, args: tuple) -> object:
        raise self.exc

    def call_spec_fn(self, name: str, args: tuple) -> object:
        raise self.exc


def test_foreign_exceptions_become_eval_errors() -> None:
    spec = spec_of(
        """
        spec t
        model M
          observe items: list<i64>
        fn f(m: M) -> i64
          ensures e: len(m.items) == result
        """
    )
    c = spec.clause_ids["f.e"]
    env = Env({"m": handle("M"), "result": 0})
    with pytest.raises(EvalError, match=r"ZeroDivisionError: oops \(at t\.spec:5:\d+: m\.items\)"):
        holds(c, env, spec, _Boom(ZeroDivisionError("oops")))
    with pytest.raises(EvalError, match="KeyError"):
        holds(c, env, spec, _Boom(KeyError("items")))


def test_spec_errors_and_skips_pass_through() -> None:
    spec = spec_of(
        """
        spec t
        model M
          observe items: list<i64>
        fn f(m: M) -> i64
          ensures e: len(m.items) == result
        fn g(x: i64) -> i64
          relates r: g(x + 1) > result
        """
    )
    env = Env({"m": handle("M"), "result": 0})
    with pytest.raises(BindingError, match="observer broke"):
        holds(spec.clause_ids["f.e"], env, spec, _Boom(BindingError("observer broke")))
    with pytest.raises(SkipClause):
        holds(spec.clause_ids["g.r"], Env({"x": 1, "result": 0}), spec, _Boom(SkipClause("no")))


def test_hypothesis_control_flow_passes_through() -> None:
    from hypothesis.errors import UnsatisfiedAssumption

    spec = spec_of(
        """
        spec t
        fn g(x: i64) -> i64
          relates r: g(x + 1) > result
        """
    )
    with pytest.raises(UnsatisfiedAssumption):
        holds(
            spec.clause_ids["g.r"],
            Env({"x": 1, "result": 0}),
            spec,
            _Boom(UnsatisfiedAssumption()),
        )


def test_holds_needs_a_bool() -> None:
    spec = spec_of(
        """
        spec t
        fn f(x: i64) -> i64
          ensures e: x > 0
        """
    )
    c = ast.Clause("ensures", expr=ast.Num(3, "3"), id="f.bad")
    with pytest.raises(EvalError, match="must evaluate to a bool"):
        holds(c, Env({}), spec, FakeCtx())
    modifies = ast.Clause("modifies", names=["x"], id="f.m")
    with pytest.raises(EvalError, match="no condition"):
        holds(modifies, Env({}), spec, FakeCtx())
    assert holds(ast.Clause("may_raise", error="E"), Env({}), spec, FakeCtx()) is True


def test_raises_conditions() -> None:
    spec = spec_of(
        """
        spec t
        error StructError
        fn pack(x: i64) -> bytes
          raises StructError when not fits<i32>(x)
          may_raise StructError
        """
    )
    raises, may = spec.fns["pack"].clauses
    assert holds(raises, Env({"x": 2**31}), spec, FakeCtx()) is True
    assert holds(raises, Env({"x": 2**31 - 1}), spec, FakeCtx()) is False
    assert holds(may, Env({"x": 0}), spec, FakeCtx()) is True


def test_predicate_partition_classes_evaluate() -> None:
    spec = spec_of(
        """
        spec t
        fn f(xs: list<i64>) -> i64
          partition xs
            empty = len(xs) == 0
            other = not empty
        """
    )
    empty, other = spec.fns["f"].partitions[0].classes
    assert evaluate(empty.expr, Env({"xs": ()}), spec, FakeCtx()) is True
    assert evaluate(other.expr, Env({"xs": ()}), spec, FakeCtx()) is False
    assert evaluate(other.expr, Env({"xs": (1,)}), spec, FakeCtx()) is True


def test_unknown_nodes_are_eval_errors() -> None:
    spec = spec_of("spec t\n")
    with pytest.raises(EvalError, match="cannot evaluate a Expr node"):
        evaluate(ast.Expr(), Env({}), spec, FakeCtx())


def test_locals_may_come_from_the_environment_by_name() -> None:
    spec, node = probe_spec("f(xs: list<i64>)", "let n = len(xs) in n + 1")
    assert isinstance(node, ast.Let)
    assert evaluate(node.body, Env({"n": 41}), spec, FakeCtx()) == 42
    with pytest.raises(EvalError, match="no value for the local n"):
        evaluate(node.body, Env({}), spec, FakeCtx())


def test_errors_in_used_files_name_that_file(tmp_path) -> None:
    from spectest.lang import load

    (tmp_path / "base.spec").write_text(
        "spec base\nmodel Bag\n  observe items: list<i64>\n  invariant sized: len(items) >= 0\n"
    )
    (tmp_path / "main.spec").write_text('spec main\nuse "base.spec"\nfn f(b: Bag) -> i64\n')
    spec = load(tmp_path / "main.spec")
    h = handle("Bag", items=5)
    with pytest.raises(EvalError) as info:
        holds(spec.clause_ids["Bag.sized"], Env({}, fields=h), spec, FakeCtx())
    assert info.value.location.endswith("base.spec:4:20")  # type: ignore[attr-defined]
    assert "len(items)" in str(info.value)
