"""Prelude calls, type constants, spec-function calls, observers, old(), defaults and coercion."""

from __future__ import annotations

from fractions import Fraction

import pytest
from eval_support import FakeCtx, f16, f32, f64, handle, spec_of, value_of

from spectest import ast
from spectest.eval import (
    Env,
    NullContext,
    coerce_arg,
    default_value,
    holds,
    old_calls,
    snapshot_olds,
)
from spectest.lang import Resolution, SpecCheckError
from spectest.prelude import floats
from spectest.types import (
    INT,
    REAL,
    STRING,
    FixedIntT,
    FloatT,
    ListT,
    MapT,
    OptionT,
    TupleT,
    TypeVarT,
)
from spectest.values import (
    NEG_INF,
    POS_INF,
    EvalError,
    FloatValue,
    MapValue,
    SkipClause,
    Some,
)

U8, I8, I32, U64 = (
    FixedIntT(8, False),
    FixedIntT(8, True),
    FixedIntT(32, True),
    FixedIntT(64, False),
)
F16, F32, F64 = FloatT("f16"), FloatT("f32"), FloatT("f64")

# -- prelude calls ---------------------------------------------------------------


def test_prelude_calls() -> None:
    assert value_of("f(xs: list<i64>)", "len(xs)", xs=(1, 2)) == 2
    assert value_of("f(xs: list<i64>)", "sorted(xs)", xs=(3, 1, 2)) == (1, 2, 3)
    assert value_of("f(x: f64)", "is_nan(x)", x=floats.nan("f64")) is True
    assert value_of("f(x: f64)", "bits(x)", x=f64(-0.0)) == 1 << 63
    assert value_of("f(x: f64)", "next_up(x)", x=f64(1.0)) == f64(1.0000000000000002)
    assert value_of("f(b: bytes)", "le_uint(b)", b=b"\x01\x01") == 257
    assert value_of("f(x: f64)", "mp.sqrt(x) == 2", x=f64(4.0)) is True


def test_generic_prelude_calls_resolve_type_arguments() -> None:
    assert value_of("f(x: i64)", "wrap<u32>(x)", x=-1) == 2**32 - 1
    assert value_of("f(x: i64)", "wrap<i8>(x)", x=255) == -1
    assert value_of("f(x: i64)", "fits<i32>(x)", x=2**31) is False
    assert value_of("f(x: f64)", "fits<f32>(x)", x=f64(0.5)) is True
    assert value_of("f(x: f64)", "same(round<f16>(x), round<f16>(x))", x=f64(0.1)) is True
    v = value_of("f(x: f64)", "round<f32>(real(x) * 3)", x=f64(0.1))
    assert v == floats.round_to(Fraction(0.1) * 3, "f32")
    assert value_of("f(x: f64)", "ulp<f64>(1)", x=f64(0.0)) == Fraction(1, 2**52)


def test_generic_functions_evaluate_with_a_type_environment() -> None:
    spec = spec_of(
        """
        spec t
        fn sort<T: Ord>(xs: list<T>) -> list<T>
          ensures ordered: is_sorted(result) and len(result) == len(xs)
        """
    )
    c = spec.clause_ids["sort.ordered"]
    for tenv, xs in (({"T": INT}, (3, 1)), ({"T": STRING}, ("b", "a"))):
        env = Env({"xs": xs, "result": tuple(sorted(xs))}, tenv=tenv)  # type: ignore[type-var]
        assert holds(c, env, spec, FakeCtx())


def test_keyword_arguments_reach_the_prelude() -> None:
    sig = "f(a: list<f64>, b: list<f64>)"
    nan1, nan2 = floats.nan("f64"), floats.nan("f64", payload=1)
    vals = {"a": (nan1, f64(0.0)), "b": (nan2, f64(-0.0))}
    assert value_of(sig, 'eq(a, b, float="bits")', **vals) is False
    assert value_of(sig, 'eq(a, b, float="ieee")', **vals) is False
    assert value_of(sig, 'eq(a, a, float="nan_any")', **vals) is True
    assert value_of(sig, 'eq(b, a, float="nan_any") or true', **vals) is True
    vals = {"a": (f64(1.0), f64(2.0)), "b": (f64(2.0), f64(1.0))}
    assert value_of(sig, 'eq(a, b, float="bits", order="ignore")', **vals) is True
    assert value_of(sig, 'eq(a, b, float="bits")', **vals) is False


def test_identity_functions_use_the_context() -> None:
    spec = spec_of(
        """
        spec t
        model M
          observe items: list<i64>
        fn copy(m: M) -> M
          ensures fresh: fresh(result)
          ensures distinct: not same_object(result, m)
          ensures items: eq(result, m)
        """
    )
    m = handle("M", items=(1, 2))
    r = handle("M", items=(1, 2))
    ctx = FakeCtx(fresh=(r,))
    env = Env({"m": m, "result": r})
    for cid in ("copy.fresh", "copy.distinct", "copy.items"):
        assert holds(spec.clause_ids[cid], env, spec, ctx), cid
    assert not holds(spec.clause_ids["copy.fresh"], Env({"m": m, "result": m}), spec, ctx)
    other = handle("M", items=(2, 1))
    assert not holds(spec.clause_ids["copy.items"], Env({"m": m, "result": other}), spec, ctx)


# -- type constants --------------------------------------------------------------


def test_type_constants() -> None:
    assert value_of("f()", "i32.max") == 2**31 - 1
    assert value_of("f()", "i32.min") == -(2**31)
    assert value_of("f()", "u8.max + 1") == 256
    assert value_of("f()", "u64.min") == 0
    assert value_of("f()", "f64.max") == floats.max_finite("f64")
    assert value_of("f()", "f16.max") == floats.max_finite("f16")
    assert value_of("f()", "same(f64.min, -f64.max)") is True
    assert value_of("f()", "real(f32.max)") == floats.to_real(floats.max_finite("f32"))


# -- spec-function calls -----------------------------------------------------------


LIBM = """
spec t
fn cos(x: f64) -> f64
  relates even: not is_nan(x) implies same(cos(-x), result)
fn half(x: f32) -> f32
  relates twice: same(half(x * 2), x)
fn small(x: u8) -> u8
  relates next: small(x + 1) >= result
fn opts(x: i64, how: "any" | "all" = "any", scale: f64 = 0.5) -> i64
  relates dflt: opts(x) == result and opts(x, how="all") == result
"""


def test_spec_fn_calls_go_through_the_context() -> None:
    spec = spec_of(LIBM)
    ctx = FakeCtx({"cos": lambda x: f64(1.0)})
    x = f64(0.0)
    assert holds(spec.clause_ids["cos.even"], Env({"x": x, "result": f64(1.0)}), spec, ctx)
    ((name, args),) = ctx.calls
    assert name == "cos"
    assert isinstance(args[0], FloatValue) and floats.signbit(args[0]) and floats.is_zero(args[0])


def test_spec_fn_arguments_are_coerced_to_parameter_types() -> None:
    spec = spec_of(LIBM)
    ctx = FakeCtx({"half": lambda x: f32(floats.to_python_float(x) / 2)})
    x = f32(1.5)
    assert holds(spec.clause_ids["half.twice"], Env({"x": x, "result": f32(0.75)}), spec, ctx)
    assert ctx.calls == [("half", (f32(3.0),))]
    ctx = FakeCtx({"half": lambda x: x})
    big = floats.max_finite("f32")
    with pytest.raises(EvalError, match="not exactly representable as f32"):
        holds(spec.clause_ids["half.twice"], Env({"x": big, "result": big}), spec, ctx)
    assert ctx.calls == []


def test_spec_fn_fixed_width_arguments_must_fit() -> None:
    spec = spec_of(LIBM)
    ctx = FakeCtx({"small": lambda x: x})
    assert holds(spec.clause_ids["small.next"], Env({"x": 3, "result": 3}), spec, ctx)
    assert ctx.calls == [("small", (4,))]
    with pytest.raises(EvalError, match="256 is out of range for u8"):
        holds(spec.clause_ids["small.next"], Env({"x": 255, "result": 0}), spec, ctx)


def test_spec_fn_defaults_and_keywords() -> None:
    spec = spec_of(LIBM)
    ctx = FakeCtx({"opts": lambda x, how, scale: x})
    assert holds(spec.clause_ids["opts.dflt"], Env({"x": 1, "result": 1}), spec, ctx)
    assert ctx.calls == [("opts", (1, "any", f64(0.5))), ("opts", (1, "all", f64(0.5)))]


def test_spec_fn_skip_passes_through() -> None:
    spec = spec_of(LIBM)

    def skip(x: FloatValue) -> FloatValue:
        raise SkipClause("planned call raised")

    with pytest.raises(SkipClause):
        holds(
            spec.clause_ids["cos.even"],
            Env({"x": f64(1.0), "result": f64(0.5)}),
            spec,
            FakeCtx({"cos": skip}),
        )


# -- observers ----------------------------------------------------------------------


FRAMES = """
spec t
model Frame
  observe columns: list<string>
  observe cell(i: u64, name: string): option<f64>
fn first(df: Frame) -> option<f64>
  requires len(df.columns) > 0
  ensures e: is_none(result) or same(unwrap(result), unwrap(df.cell(0, df.columns[0])))
fn at(df: Frame, i: i64) -> option<f64>
  ensures e: is_some(df.cell(i, "a")) implies is_some(result)
"""


def test_observers_with_arguments() -> None:
    spec = spec_of(FRAMES)
    cells = {(0, "a"): Some(f64(1.5))}
    df = handle("Frame", columns=("a",), cell=lambda i, n: cells.get((i, n)))
    ctx = FakeCtx()
    assert holds(spec.clause_ids["first.e"], Env({"df": df, "result": Some(f64(1.5))}), spec, ctx)
    assert (df, "cell", (0, "a")) in ctx.observations
    assert (df, "columns", ()) in ctx.observations


def test_observer_arguments_are_coerced() -> None:
    spec = spec_of(FRAMES)
    df = handle("Frame", columns=("a",), cell=lambda i, n: None)
    with pytest.raises(EvalError, match="-1 is out of range for u64"):
        holds(spec.clause_ids["at.e"], Env({"df": df, "i": -1, "result": None}), spec, FakeCtx())


def test_observer_on_a_non_handle_is_an_eval_error() -> None:
    spec = spec_of(FRAMES)
    with pytest.raises(EvalError, match="needs a handle"):
        holds(spec.clause_ids["at.e"], Env({"df": 3, "i": 0, "result": None}), spec, FakeCtx())


# -- old ----------------------------------------------------------------------------


STACK = """
spec t
interface Stack<T: Eq>
  observe items: list<T>
  new empty() -> Stack
  method push(self, x: T)
    modifies self
    ensures items: self.items == old(self.items) + [x]
    ensures grows: len(self.items) == len(old(self.items)) + 1
  method pop(self) -> T
    modifies self
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
    ensures letbound: let n = len(self.items) in old(len(self.items)) == n + 1
    ensures inner: old(let xs = self.items in all(i in xs: i == i)) or true
"""


def _stack(items: list[int]):
    return handle("Stack", items=lambda: tuple(items))


def test_old_calls() -> None:
    spec = spec_of(STACK)
    push = spec.interfaces["Stack"].methods[0]
    items, grows = push.clauses[1], push.clauses[2]
    assert len(old_calls(items.expr)) == 1
    assert len(old_calls(grows.expr, spec)) == 1
    assert old_calls(None) == []
    pop = spec.interfaces["Stack"].methods[1]
    assert len(old_calls(pop.clauses[1].expr)) == 2


def test_snapshot_olds_then_evaluate_post_state() -> None:
    spec = spec_of(STACK)
    push = spec.interfaces["Stack"].methods[0]
    items: list[int] = [1, 2]
    h = _stack(items)
    ctx = FakeCtx()
    pre = Env({"self": h, "x": 3})
    olds = snapshot_olds(push.clauses, pre, spec, ctx)
    assert sorted(olds.values()) == [(1, 2), (1, 2)]
    items.append(3)
    post = Env({"self": h, "x": 3, "result": None}, olds=olds)
    assert holds(push.clauses[1], post, spec, ctx)
    assert holds(push.clauses[2], post, spec, ctx)
    items.append(4)
    assert not holds(push.clauses[1], post, spec, ctx)


def test_old_without_snapshot_is_an_eval_error() -> None:
    spec = spec_of(STACK)
    push = spec.interfaces["Stack"].methods[0]
    with pytest.raises(EvalError, match="no snapshot"):
        holds(push.clauses[1], Env({"self": _stack([1]), "x": 1}), spec, FakeCtx())


def test_old_errors_are_recorded_and_raised_on_use() -> None:
    spec = spec_of(STACK)
    pop = spec.interfaces["Stack"].methods[1]
    items: list[int] = []
    h = _stack(items)
    olds = snapshot_olds(pop.clauses, Env({"self": h}), spec, FakeCtx())
    value = pop.clauses[1]
    env = Env({"self": h, "result": 1}, olds=olds)
    with pytest.raises(EvalError, match="index -1 is out of range"):
        holds(value, env, spec, FakeCtx())


def test_old_of_a_clause_local_cannot_be_snapshotted() -> None:
    """The checker rejects such an old(...); snapshot_olds still refuses one it is given."""
    with pytest.raises(SpecCheckError, match="cannot use i, which all"):
        spec_of(
            STACK
            + "    ensures bad: all(i in range(0, len(self.items)): old(self.items[i]) == 1)\n"
        )
    spec = spec_of(STACK)
    pop = spec.interfaces["Stack"].methods[1]
    letbound = pop.clauses[2]
    assert isinstance(letbound.expr, ast.Let)
    (call,) = old_calls(letbound.expr, spec)
    (inner,) = [n for n in ast.walk(call.args[0]) if isinstance(n, ast.Name) and n.id == "self"]
    spec.resolution[inner] = Resolution("local", "n", letbound.expr)
    try:
        olds = snapshot_olds([letbound], Env({"self": _stack([1])}), spec, FakeCtx())
    finally:
        spec.resolution[inner] = Resolution("self", "self", "Stack")
    assert isinstance(olds[call], EvalError)
    assert "uses self, which let binds inside the clause" in str(olds[call])


def test_snapshot_olds_finds_a_clauses_old_calls_once(monkeypatch: pytest.MonkeyPatch) -> None:
    """Interface steps snapshot the same clauses on every call; the AST is walked only once."""
    import spectest.eval as ev

    spec = spec_of(STACK)
    pop = spec.interfaces["Stack"].methods[1]
    first = snapshot_olds(pop.clauses, Env({"self": _stack([1, 2])}), spec, FakeCtx())

    def walked(*args: object) -> list[ast.Call]:
        raise AssertionError("old_calls ran again")

    monkeypatch.setattr(ev, "old_calls", walked)
    monkeypatch.setattr(ev, "_inner_local", walked)
    again = snapshot_olds(pop.clauses, Env({"self": _stack([1, 2])}), spec, FakeCtx())
    assert list(again) == list(first)
    assert list(again.values()) == list(first.values())
    other = spec_of(STACK).interfaces["Stack"].methods[1]
    with pytest.raises(AssertionError, match="ran again"):
        snapshot_olds(other.clauses, Env({"self": _stack([1])}), spec, FakeCtx())


def test_old_may_use_names_bound_outside_it() -> None:
    spec = spec_of(STACK)
    pop = spec.interfaces["Stack"].methods[1]
    items = [1, 2, 3]
    h = _stack(items)
    olds = snapshot_olds(pop.clauses, Env({"self": h}), spec, FakeCtx())
    items.pop()
    assert holds(pop.clauses[2], Env({"self": h, "result": 3}, olds=olds), spec, FakeCtx())


def test_old_may_bind_names_inside_its_argument() -> None:
    spec = spec_of(STACK)
    pop = spec.interfaces["Stack"].methods[1]
    inner = pop.clauses[3]
    h = _stack([1, 2])
    olds = snapshot_olds([inner], Env({"self": h}), spec, FakeCtx())
    assert list(olds.values()) == [True]
    assert holds(inner, Env({"self": h, "result": 2}, olds=olds), spec, FakeCtx())


def test_snapshot_records_skips_and_binding_errors() -> None:
    spec = spec_of(STACK)
    push = spec.interfaces["Stack"].methods[0]

    def broken() -> tuple[int, ...]:
        raise SkipClause("not now")

    h = handle("Stack", items=broken)
    olds = snapshot_olds(push.clauses, Env({"self": h, "x": 1}), spec, FakeCtx())
    assert all(isinstance(v, SkipClause) for v in olds.values())


# -- defaults ------------------------------------------------------------------------


def test_default_values() -> None:
    spec = spec_of(
        """
        spec t
        model Frame
          observe nrows: u64
          observe cell(i: u64 = 0): option<f64>
        fn f(how: "any" | "all" = "any", scale: f64 = 0.25, n: i8 = -3, big: int = 2 * 10,
             r: f32 = 0x1p-3, xs: list<u8> = [1, 2]) -> i64
        """
    )
    params = {p.name: p for p in spec.fns["f"].params}
    assert default_value(params["how"], spec) == "any"
    assert default_value(params["scale"], spec) == f64(0.25)
    assert default_value(params["n"], spec) == -3
    assert default_value(params["big"], spec) == 20
    assert default_value(params["r"], spec) == f32(0.125)
    assert default_value(params["xs"], spec) == (1, 2)
    obs = spec.models["Frame"].observers[1]
    assert default_value(obs.params[0], spec) == 0
    with pytest.raises(EvalError, match="no default"):
        default_value(ast.Param("q", ast.TypeExpr("i64")), spec)


def test_observer_defaults_fill_missing_arguments() -> None:
    spec = spec_of(
        """
        spec t
        model M
          observe cell(i: u64 = 0): i64
        fn f(m: M) -> i64
          ensures e: m.cell() == result
        """
    )
    m = handle("M", cell=lambda i: i + 10)
    assert holds(spec.clause_ids["f.e"], Env({"m": m, "result": 10}), spec, FakeCtx())


def test_null_context_refuses_everything() -> None:
    ctx = NullContext()
    h = handle("M")
    for call in (
        lambda: ctx.observe(h, "x", ()),
        lambda: ctx.fields(h),
        lambda: ctx.call_spec_fn("f", ()),
        lambda: ctx.is_fresh(h),
        lambda: ctx.same_object(h, h),
        lambda: ctx.shares_memory(h, h),
    ):
        with pytest.raises(EvalError, match="not available"):
            call()


# -- coercion -----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "t", "expected"),
    [
        (255, U8, 255),
        (-128, I8, -128),
        (Fraction(4, 2), I32, 2),
        (7, INT, 7),
        (Fraction(1, 3), REAL, Fraction(1, 3)),
        ("s", STRING, "s"),
        (1, F64, f64(1.0)),
        (Fraction(1, 2), F16, f16(0.5)),
        (0, F32, f32(0.0)),
        (POS_INF, F32, floats.inf("f32")),
        (NEG_INF, F16, floats.inf("f16", negative=True)),
        (f32(0.1), F64, floats.convert(f32(0.1), "f64")),
        (f64(0.5), F32, f32(0.5)),
        (f64(-0.0), F16, f16(-0.0)),
        (floats.nan("f32"), F64, floats.nan("f64")),
        (floats.nan("f64"), F32, floats.nan("f32")),
        (floats.inf("f64"), F32, floats.inf("f32")),
        ((1, 2), ListT(U8), (1, 2)),
        ((1, Fraction(1, 2)), TupleT((U8, F32)), (1, f32(0.5))),
        (Some(3), OptionT(F64), Some(f64(3.0))),
        (None, OptionT(F64), None),
        (MapValue(((1, 2),)), MapT(U8, F64), MapValue(((1, f64(2.0)),))),
        ((1, 2), ListT(TypeVarT("T")), (1, 2)),
    ],
)
def test_coerce_arg(value: object, t: object, expected: object) -> None:
    assert coerce_arg(value, t) == expected  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("value", "t", "message"),
    [
        (256, U8, "out of range for u8"),
        (-1, U64, "out of range for u64"),
        (Fraction(1, 2), I32, "expected an integer"),
        (True, U8, "expected an integer"),
        (f64(1.0), I32, "expected an integer"),
        (POS_INF, I32, "expected an integer"),
        (Fraction(1, 10), F64, "not exactly representable as f64"),
        (2**1024, F64, "not exactly representable"),
        (f64(0.1), F32, "not exactly representable as f32"),
        (floats.nan("f64", payload=1), F32, "not exactly representable"),
        (FloatValue("f32", 0x7F800001), F64, "not exactly representable"),
        (f64(1e-40), F16, "not exactly representable"),
        ("x", F64, "expected a number"),
        ((1, 300), ListT(U8), "300 is out of range"),
    ],
)
def test_coerce_arg_rejects_inexact_values(value: object, t: object, message: str) -> None:
    with pytest.raises(EvalError, match=message):
        coerce_arg(value, t)  # type: ignore[arg-type]


def test_default_values_are_cached_per_parameter() -> None:
    spec = spec_of(
        """
        spec t
        fn f(scale: f64 = 0.25) -> i64
        """
    )
    p = spec.fns["f"].params[0]
    assert default_value(p, spec) is default_value(p, spec)


def test_old_errors_can_be_raised_repeatedly() -> None:
    spec = spec_of(STACK)
    pop = spec.interfaces["Stack"].methods[1]
    h = _stack([])
    olds = snapshot_olds(pop.clauses, Env({"self": h}), spec, FakeCtx())
    env = Env({"self": h, "result": 1}, olds=olds)
    for _ in range(3):
        with pytest.raises(EvalError, match="index -1 is out of range"):
            holds(pop.clauses[1], env, spec, FakeCtx())
