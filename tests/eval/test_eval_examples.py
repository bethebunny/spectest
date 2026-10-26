"""Every example spec's clauses, evaluated on inputs and results from real Python behaviour."""

from __future__ import annotations

import collections
import functools
import math
import struct
from typing import Any

import numpy as np
import pytest
from eval_support import FakeCtx, example, f16, f32, f64, handle, py

from spectest import ast
from spectest.eval import (
    Env,
    evaluate,
    evaluate_aggregate,
    explain,
    holds,
    snapshot_olds,
)
from spectest.lang import Spec
from spectest.prelude import cr, floats
from spectest.values import FloatValue, Handle, QError, Some


def _clauses(spec: Spec, decl: ast.Node, *kinds: str) -> list[ast.Clause]:
    return [c for c in spec.clauses_of(decl) if c.kind in kinds]


def _all_hold(spec: Spec, clauses: list[ast.Clause], env: Env, ctx: Any) -> None:
    for c in clauses:
        assert holds(c, env, spec, ctx), (c.id, explain(c.expr, env, spec, ctx))


# -- libm ---------------------------------------------------------------------------


F64_INPUTS = [
    0.0, -0.0, 1.0, -1.0, 0.5, 1e-300, 5e-324, -5e-324, 2.2250738585072014e-308,
    1e-9, -3e-9, 3.0, math.pi, -math.pi / 2, 1e5, 1048575.5, 1e10, -1e22, 1.7976931348623157e308,
    math.inf, -math.inf, math.nan,
]  # fmt: skip


def _round_from_double(fn: Any, x: FloatValue, fmt: str) -> FloatValue:
    v = py(x)
    return floats.from_python_float(fn(v) if math.isfinite(v) else math.nan, fmt)


@pytest.mark.parametrize("x", F64_INPUTS)
def test_libm_cos_holds_for_math_cos(x: float) -> None:
    spec = example("libm")
    fn = spec.fns["cos"]
    ctx = FakeCtx({"cos": lambda v: _round_from_double(math.cos, v, "f64")})
    xv = f64(x)
    result = f64(math.cos(x)) if math.isfinite(x) else f64(math.nan)
    _all_hold(spec, _clauses(spec, fn, "ensures", "relates"), Env({"x": xv, "result": result}), ctx)


@pytest.mark.parametrize("x", F64_INPUTS)
def test_libm_cos32_holds_for_rounded_math_cos(x: float) -> None:
    spec = example("libm")
    fn = spec.fns["cos32"]
    ctx = FakeCtx({"cos32": lambda v: _round_from_double(math.cos, v, "f32")})
    xv = f32(x)
    if floats.is_finite(xv):
        result = _round_from_double(math.cos, xv, "f32")
    else:
        result = floats.nan("f32")
    _all_hold(spec, _clauses(spec, fn, "ensures", "relates"), Env({"x": xv, "result": result}), ctx)


def _f16_sample(step: int) -> list[FloatValue]:
    return [FloatValue("f16", b) for b in range(0, 1 << 16, step)]


def _numpy_cos16(x: FloatValue) -> FloatValue:
    with np.errstate(invalid="ignore"):
        return floats.from_numpy(np.cos(floats.to_numpy(x)))


def _qe_of(spec: Spec, cid: str, env: Env) -> QError:
    expr = spec.clause_ids[cid].expr
    assert isinstance(expr, ast.Binary)
    return evaluate(expr.left, env, spec, FakeCtx())


@functools.cache
def all_f16() -> tuple[FloatValue, ...]:
    """Every f16, by bit pattern."""
    return tuple(FloatValue("f16", b) for b in range(1 << 16))


@pytest.mark.slow
def test_libm_cos16_accurate_on_every_f16_for_numpy_cos() -> None:
    """cos16.accurate holds on all 65,536 inputs for numpy's float16 cos.

    numpy computes in float32 and rounds to f16: 65,534 results are correctly
    rounded (qe 0) and the two at +-0.05847 are one step off (qe 1).
    """
    spec = example("libm")
    c = spec.clause_ids["cos16.accurate"]
    counts: collections.Counter[QError] = collections.Counter()
    for x in all_f16():
        env = Env({"x": x, "result": _numpy_cos16(x)})
        assert holds(c, env, spec, FakeCtx()), x
        counts[_qe_of(spec, "cos16.accurate", env)] += 1
    assert counts == {QError(0, 0): 65534, QError(1, 0): 2}


@pytest.mark.slow
def test_libm_cos16_accurate_for_math_cos_rounded_from_double() -> None:
    """math.cos rounded once from double to f16 is correctly rounded on every input."""
    spec = example("libm")
    c = spec.clause_ids["cos16.accurate"]
    counts: collections.Counter[QError] = collections.Counter()
    for x in all_f16():
        result = _round_from_double(math.cos, x, "f16")
        env = Env({"x": x, "result": result})
        assert holds(c, env, spec, FakeCtx()), x
        counts[_qe_of(spec, "cos16.accurate", env)] += 1
    assert counts == {QError(0, 0): 65536}


def test_libm_cos16_accurate_catches_bad_results() -> None:
    spec = example("libm")
    c = spec.clause_ids["cos16.accurate"]
    x = f16(0.5)
    two_off = floats.next_up(floats.next_up(_numpy_cos16(x)))
    assert not holds(c, Env({"x": x, "result": two_off}), spec, FakeCtx())
    assert not holds(c, Env({"x": x, "result": floats.nan("f16")}), spec, FakeCtx())
    assert not holds(c, Env({"x": floats.inf("f16"), "result": f16(1.0)}), spec, FakeCtx())
    assert holds(c, Env({"x": floats.inf("f16"), "result": floats.nan("f16")}), spec, FakeCtx())


def _explore_ctx(fns: dict[str, Any], **kw: Any) -> FakeCtx:
    return FakeCtx(fns, **kw)


@pytest.mark.slow
def test_explore_cos16_correctly_rounded_for_numpy_cos() -> None:
    spec = example("explore")
    c = spec.clause_ids["cos16.correctly_rounded"]
    ctx = _explore_ctx({"cos16": _numpy_cos16})
    r = evaluate_aggregate(c, spec, ctx)
    assert (r.holds, r.value, r.bound) == (False, QError(2, 0), 0)
    assert (r.evaluated, r.skipped, r.total, r.sampled) == (65536, 0, 65536, False)
    assert [(floats.format_float(m), t) for m, t in r.worst] == [
        ("0.05847", QError(1, 0)), ("-0.05847", QError(1, 0)),
    ]  # fmt: skip
    assert len(ctx.calls) == 65536
    assert holds(c, Env({}), spec, ctx) is False


@pytest.mark.slow
def test_explore_cos16_correctly_rounded_for_a_correctly_rounded_cos() -> None:
    spec = example("explore")
    c = spec.clause_ids["cos16.correctly_rounded"]
    r = evaluate_aggregate(c, spec, _explore_ctx({"cos16": cr.cos}))
    assert (r.holds, r.value, r.worst) == (True, QError.ZERO, [])


def test_explore_cos32_worst_small_is_sampled() -> None:
    spec = example("explore")
    c = spec.clause_ids["cos32.worst_small"]

    def cos32(x: FloatValue) -> FloatValue:
        return floats.from_numpy(np.cos(floats.to_numpy(x)))

    r = evaluate_aggregate(c, spec, _explore_ctx({"cos32": cos32}, sample=400))
    assert r.sampled and r.evaluated == 400 and r.total == 2 * 0x3F800000 + 1
    assert all(floats.to_python_float(m) ** 2 < 1 for m, _ in r.worst)
    assert r.holds == (r.value == QError.ZERO)
    assert all(t == QError(1, 0) for _, t in r.worst)
    exact = evaluate_aggregate(c, spec, _explore_ctx({"cos32": cr.cos}, sample=400))
    assert exact.holds and exact.value == QError.ZERO


SQRT_INPUTS = [0.0, -0.0, 1.0, 2.0, 0.25, 5e-324, 1e-310, 1e300, 1.7976931348623157e308,
               math.inf, math.nan, -math.nan]  # fmt: skip


@pytest.mark.parametrize("x", SQRT_INPUTS)
def test_libm_sqrt_holds_for_math_sqrt(x: float) -> None:
    spec = example("libm")
    fn = spec.fns["sqrt"]
    ctx = FakeCtx({"sqrt": lambda v: f64(math.sqrt(py(v)))})
    xv = f64(x)
    env = Env({"x": xv, "result": f64(math.sqrt(x))})
    _all_hold(spec, _clauses(spec, fn, "ensures", "relates"), env, ctx)
    (may_raise,) = _clauses(spec, fn, "may_raise")
    assert not holds(may_raise, Env({"x": xv}), spec, ctx)


@pytest.mark.parametrize("x", [-1.0, -5e-324, -math.inf, -1e300])
def test_libm_sqrt_of_negatives_may_raise_or_return_nan(x: float) -> None:
    spec = example("libm")
    fn = spec.fns["sqrt"]
    with pytest.raises(ValueError):
        math.sqrt(x)
    (may_raise,) = _clauses(spec, fn, "may_raise")
    assert holds(may_raise, Env({"x": f64(x)}), spec, FakeCtx())
    rounded = spec.clause_ids["sqrt.correctly_rounded"]
    assert holds(rounded, Env({"x": f64(x), "result": f64(math.nan)}), spec, FakeCtx())
    assert not holds(rounded, Env({"x": f64(x), "result": f64(0.0)}), spec, FakeCtx())


def test_libm_sqrt_correctly_rounded_catches_one_step() -> None:
    spec = example("libm")
    rounded = spec.clause_ids["sqrt.correctly_rounded"]
    x = f64(2.0)
    good = f64(math.sqrt(2.0))
    assert holds(rounded, Env({"x": x, "result": good}), spec, FakeCtx())
    env = Env({"x": x, "result": floats.next_up(good)})
    assert not holds(rounded, env, spec, FakeCtx())
    assert dict(explain(rounded.expr, env, spec, FakeCtx()))["qe(result, cr.sqrt(x))"] == "1"


def test_libm_sqrt_monotone_catches_a_non_monotone_sqrt() -> None:
    spec = example("libm")
    c = spec.clause_ids["sqrt.monotone"]
    ctx = FakeCtx({"sqrt": lambda v: f64(1.0)})
    env = Env({"x": f64(4.0), "result": f64(2.0)})
    assert not holds(c, env, spec, ctx)
    got = dict(explain(c.expr, env, spec, ctx))
    assert got["y"] == "1.0 (0x3ff0000000000000)"
    assert got["real(result)"] == "2" and got["real(y)"] == "1"
    assert ctx.calls[0] == ("sqrt", (floats.next_up(f64(4.0)),))


# -- binary -------------------------------------------------------------------------


def _unpack(b: bytes) -> int:
    return struct.unpack("<i", b)[0]


@pytest.mark.parametrize("x", [0, 1, -1, 255, -256, 2**31 - 1, -(2**31), 123456789, -987654321])
def test_binary_pack_i32_holds_for_struct_pack(x: int) -> None:
    spec = example("binary")
    fn = spec.fns["pack_i32"]
    ctx = FakeCtx({"unpack_i32": _unpack})
    env = Env({"x": x, "result": struct.pack("<i", x)})
    _all_hold(spec, _clauses(spec, fn, "ensures", "relates"), env, ctx)
    (raises,) = _clauses(spec, fn, "raises")
    assert not holds(raises, env, spec, ctx)


@pytest.mark.parametrize("x", [2**31, -(2**31) - 1, 2**63 - 1, -(2**63)])
def test_binary_pack_i32_raises_out_of_range(x: int) -> None:
    spec = example("binary")
    with pytest.raises(struct.error):
        struct.pack("<i", x)
    (raises,) = _clauses(spec, spec.fns["pack_i32"], "raises")
    assert holds(raises, Env({"x": x}), spec, FakeCtx())


def test_binary_pack_i32_big_endian_fails_little_endian() -> None:
    spec = example("binary")
    c = spec.clause_ids["pack_i32.little_endian"]
    env = Env({"x": 1, "result": struct.pack(">i", 1)})
    assert not holds(c, env, spec, FakeCtx())
    got = dict(explain(c.expr, env, spec, FakeCtx()))
    assert got == {
        "result": 'b"\\x00\\x00\\x00\\x01"',
        "le_uint(result)": "16777216",
        "x": "1",
        "wrap<u32>(x)": "1",
    }


@pytest.mark.parametrize("b", [b"\x00\x00\x00\x00", b"\xff\xff\xff\xff", b"\x01\x02\x03\x80"])
def test_binary_unpack_i32_holds_for_struct_unpack(b: bytes) -> None:
    spec = example("binary")
    fn = spec.fns["unpack_i32"]
    env = Env({"b": b, "result": _unpack(b)})
    _all_hold(spec, _clauses(spec, fn, "ensures"), env, FakeCtx())
    assert not holds(_clauses(spec, fn, "raises")[0], env, spec, FakeCtx())


@pytest.mark.parametrize("b", [b"", b"\x00", b"\x00\x00\x00\x00\x00"])
def test_binary_unpack_i32_raises_on_wrong_length(b: bytes) -> None:
    spec = example("binary")
    with pytest.raises(struct.error):
        _unpack(b)
    assert holds(
        _clauses(spec, spec.fns["unpack_i32"], "raises")[0], Env({"b": b}), spec, FakeCtx()
    )


@pytest.mark.parametrize("s", ["", "a", "héllo", "日本語", "😀x", "\x00߿￿\U0010ffff"])
def test_binary_utf8_encode_holds_for_str_encode(s: str) -> None:
    spec = example("binary")
    ctx = FakeCtx({"utf8_decode": lambda b: b.decode("utf-8")})
    env = Env({"s": s, "result": s.encode("utf-8")})
    _all_hold(spec, _clauses(spec, spec.fns["utf8_encode"], "ensures", "relates"), env, ctx)


def test_binary_utf8_encode_with_surrogatepass_is_invalid() -> None:
    spec = example("binary")
    s = "\ud800"
    env = Env({"s": s, "result": s.encode("utf-8", "surrogatepass")})
    assert not holds(spec.clause_ids["utf8_encode.valid"], env, spec, FakeCtx())


@pytest.mark.parametrize("b", [b"", b"abc", "ü€😀".encode(), b"\xc3\xa9"])
def test_binary_utf8_decode_holds_for_bytes_decode(b: bytes) -> None:
    spec = example("binary")
    fn = spec.fns["utf8_decode"]
    ctx = FakeCtx({"utf8_encode": lambda s: s.encode("utf-8")})
    env = Env({"b": b, "result": b.decode("utf-8")})
    _all_hold(spec, _clauses(spec, fn, "relates"), env, ctx)
    assert not holds(_clauses(spec, fn, "raises")[0], env, spec, ctx)


@pytest.mark.parametrize(
    "b", [b"\xff", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"a\x80"]
)
def test_binary_utf8_decode_raises_on_invalid(b: bytes) -> None:
    spec = example("binary")
    with pytest.raises(UnicodeDecodeError):
        b.decode("utf-8")
    assert holds(
        _clauses(spec, spec.fns["utf8_decode"], "raises")[0], Env({"b": b}), spec, FakeCtx()
    )


# -- sorting ------------------------------------------------------------------------


@pytest.mark.parametrize(
    "xs", [(), (1,), (3, 1, 2), (2, 2, 1, 1), (-(2**63), 2**63 - 1, 0), ("b", "a", "ab", "")]
)
def test_sorting_sort_holds_for_sorted(xs: tuple) -> None:
    spec = example("sorting")
    env = Env({"xs": xs, "result": tuple(sorted(xs))})
    _all_hold(spec, _clauses(spec, spec.fns["sort"], "ensures"), env, FakeCtx())


def test_sorting_sort_partitions() -> None:
    spec = example("sorting")
    from spectest.eval import evaluate

    classes = spec.fns["sort"].partitions[0].classes
    for xs, name in (((), "empty"), ((1,), "single"), ((1, 2), "unique"), ((2, 2), "duplicates")):
        hits = [c.name for c in classes if evaluate(c.expr, Env({"xs": xs}), spec, FakeCtx())]
        assert hits == [name]


def test_sorting_sort_by_first_holds_for_stable_sorted() -> None:
    spec = example("sorting")
    xs = ((2, "a"), (1, "b"), (2, "c"), (1, "d"), (0, "e"))
    env = Env({"xs": xs, "result": tuple(sorted(xs, key=lambda p: p[0]))})
    _all_hold(spec, _clauses(spec, spec.fns["sort_by_first"], "ensures"), env, FakeCtx())


def test_sorting_sort_by_first_unstable_result_fails_stable() -> None:
    spec = example("sorting")
    xs = ((2, "a"), (1, "b"), (2, "c"))
    unstable = ((1, "b"), (2, "c"), (2, "a"))
    env = Env({"xs": xs, "result": unstable})
    assert holds(spec.clause_ids["sort_by_first.permutation"], env, spec, FakeCtx())
    assert holds(spec.clause_ids["sort_by_first.ordered"], env, spec, FakeCtx())
    c = spec.clause_ids["sort_by_first.stable"]
    assert not holds(c, env, spec, FakeCtx())
    got = dict(explain(c.expr, env, spec, FakeCtx()))
    assert got["p"] == '(2, "a")'
    assert got["filter(q in result: q.0 == p.0)"] == '[(2, "c"), (2, "a")]'
    assert got["filter(q in xs: q.0 == p.0)"] == '[(2, "a"), (2, "c")]'


def test_sorting_sort_in_place_holds_for_list_sort() -> None:
    spec = example("sorting")
    fn = spec.fns["sort_in_place"]
    data = [5, 3, 9, 3]
    h = Handle(None, "MutableList")
    h.obj = {"items": lambda: tuple(data)}
    ctx = FakeCtx()
    clauses = _clauses(spec, fn, "ensures")
    olds = snapshot_olds(clauses, Env({"xs": h}), spec, ctx)
    data.sort()
    _all_hold(spec, clauses, Env({"xs": h, "result": None}, olds=olds), ctx)
    data.append(0)
    assert not holds(
        spec.clause_ids["sort_in_place.permutation"], Env({"xs": h}, olds=olds), spec, ctx
    )


# -- deque --------------------------------------------------------------------------


def _deque_handle(d: collections.deque) -> Handle:
    return handle(
        "Deque",
        items=lambda: tuple(d),
        maxlen=lambda: None if d.maxlen is None else Some(d.maxlen),
    )


def _run_method(spec: Spec, method: str, d: collections.deque, *args: Any) -> None:
    iface = spec.interfaces["Deque"]
    decl = next(m for m in iface.methods if m.name == method)
    h = _deque_handle(d)
    ctx = FakeCtx()
    params = {p.name: a for p, a in zip(decl.params, args, strict=True)}
    pre = Env({"self": h, **params})
    raises = _clauses(spec, decl, "raises")
    expected_error = any(holds(c, pre, spec, ctx) for c in raises)
    ensures = _clauses(spec, decl, "ensures")
    olds = snapshot_olds(ensures, pre, spec, ctx)
    try:
        result = getattr(d, method)(*args)
    except IndexError:
        assert expected_error
        return
    assert not expected_error
    post = Env({"self": h, "result": result, **params}, olds=olds, fields=h)
    _all_hold(spec, ensures, post, ctx)
    _all_hold(spec, _clauses(spec, iface, "invariant"), Env({"self": h}, fields=h), ctx)


DEQUES = [
    lambda: collections.deque(),
    lambda: collections.deque([1, 2, 3]),
    lambda: collections.deque([1, 2, 3], maxlen=3),
    lambda: collections.deque([7], maxlen=1),
    lambda: collections.deque([], maxlen=0),
    lambda: collections.deque([4, 5], maxlen=4),
]


@pytest.mark.parametrize("make", DEQUES)
@pytest.mark.parametrize(
    ("method", "args"),
    [
        ("append", (9,)),
        ("appendleft", (9,)),
        ("pop", ()),
        ("popleft", ()),
        ("rotate", (0,)),
        ("rotate", (1,)),
        ("rotate", (-2,)),
        ("rotate", (7,)),
        ("rotate", (-128,)),
    ],
)
def test_deque_methods_hold_for_collections_deque(make: Any, method: str, args: tuple) -> None:
    _run_method(example("deque"), method, make(), *args)


def test_deque_constructors_hold_for_collections_deque() -> None:
    spec = example("deque")
    iface = spec.interfaces["Deque"]
    empty, bounded = iface.ctors
    h = _deque_handle(collections.deque())
    _all_hold(spec, _clauses(spec, empty, "ensures"), Env({"result": h}), FakeCtx())
    for n in (0, 1, 255):
        h = _deque_handle(collections.deque(maxlen=n))
        _all_hold(spec, _clauses(spec, bounded, "ensures"), Env({"n": n, "result": h}), FakeCtx())


class _WrongEndDeque(collections.deque):
    """A bounded append that drops the newest item instead of the oldest."""

    def append(self, x: Any) -> None:
        if self.maxlen is not None and len(self) == self.maxlen:
            if self.maxlen:
                super().pop()
                super().append(x)
            return
        super().append(x)


def test_deque_wrong_bounded_append_fails_items() -> None:
    spec = example("deque")
    d = _WrongEndDeque([1, 2, 3], maxlen=3)
    h = _deque_handle(d)
    c = spec.clause_ids["Deque.append.items"]
    olds = snapshot_olds([c], Env({"self": h, "x": 4}), spec, FakeCtx())
    d.append(4)
    env = Env({"self": h, "x": 4, "result": None}, olds=olds)
    assert not holds(c, env, spec, FakeCtx())
    got = dict(explain(c.expr, env, spec, FakeCtx()))
    assert got["ys"] == "[1, 2, 3, 4]" and got["self.items"] == "[1, 2, 4]"


# -- frames -------------------------------------------------------------------------


def _pandas() -> Any:
    """pandas, imported by the first test that needs it rather than at collection."""
    return pytest.importorskip("pandas")


def _frame_handle(df: Any) -> Handle:
    pd = _pandas()

    def rows() -> tuple:
        return tuple(
            tuple(None if pd.isna(v) else Some(f64(float(v))) for v in row)
            for row in df.itertuples(index=False, name=None)
        )

    return handle(
        "Frame", columns=lambda: tuple(map(str, df.columns)), rows=rows, nrows=lambda: len(df)
    )


def _frame(data: dict[str, list[float]]) -> Any:
    return _pandas().DataFrame(data, dtype="float64")


FRAMES = [
    {"a": [1.0, math.nan, 3.0], "b": [math.nan, math.nan, -0.0]},
    {"x": [0.5, 1.5]},
    {"a": [], "b": []},
    {"p": [math.nan], "q": [math.nan], "r": [2.0]},
]


@pytest.mark.parametrize("data", FRAMES)
def test_frames_invariants_hold_for_pandas(data: dict) -> None:
    spec = example("frames")
    h = _frame_handle(_frame(data))
    _all_hold(
        spec,
        _clauses(spec, spec.models["Frame"], "invariant"),
        Env({"self": h}, fields=h),
        FakeCtx(),
    )


@pytest.mark.parametrize("data", FRAMES)
@pytest.mark.parametrize("how", ["any", "all"])
def test_frames_dropna_holds_for_pandas(data: dict, how: str) -> None:
    spec = example("frames")
    df = _frame(data)
    out = _frame_handle(df.dropna(how=how))
    ctx = FakeCtx(fresh=(out,))
    env = Env({"df": _frame_handle(df), "how": how, "result": out})
    _all_hold(spec, _clauses(spec, spec.fns["dropna"], "ensures"), env, ctx)


@pytest.mark.parametrize("data", FRAMES)
def test_frames_fillna_holds_for_pandas(data: dict) -> None:
    spec = example("frames")
    df = _frame(data)
    value = f64(-2.5)
    out = _frame_handle(df.fillna(-2.5))
    ctx = FakeCtx(fresh=(out,))
    env = Env({"df": _frame_handle(df), "value": value, "result": out})
    fn = spec.fns["fillna"]
    _all_hold(spec, _clauses(spec, fn, "requires", "ensures"), env, ctx)


def test_frames_select_holds_for_pandas() -> None:
    spec = example("frames")
    df = _frame(FRAMES[0])
    fn = spec.fns["select"]
    for names in (("b",), ("b", "a"), ()):
        env = Env(
            {"df": _frame_handle(df), "names": names, "result": _frame_handle(df[list(names)])}
        )
        _all_hold(spec, _clauses(spec, fn, "requires", "ensures"), env, FakeCtx())
        assert not holds(_clauses(spec, fn, "raises")[0], env, spec, FakeCtx())
    with pytest.raises(KeyError):
        df[["a", "zz"]]
    env = Env({"df": _frame_handle(df), "names": ("a", "zz")})
    assert holds(_clauses(spec, fn, "raises")[0], env, spec, FakeCtx())


def test_frames_dropna_that_keeps_all_rows_fails() -> None:
    spec = example("frames")
    df = _frame(FRAMES[0])
    out = _frame_handle(df.copy())
    env = Env({"df": _frame_handle(df), "how": "any", "result": out})
    c = spec.clause_ids["dropna.rows"]
    assert not holds(c, env, spec, FakeCtx())
    assert not holds(spec.clause_ids["dropna.fresh"], env, spec, FakeCtx())
