"""The PRELUDE registry, call(), type constants, and clauses from the example specs."""

from __future__ import annotations

import math
import struct
from fractions import Fraction
from typing import Any

import numpy as np
import pytest
from hypothesis import given
from hypothesis import strategies as st

from spectest.prelude import PRELUDE, PreludeFn, call, floats, type_const
from spectest.types import BOOL, FixedIntT, FloatT, ListT
from spectest.values import EvalError, FloatValue, Handle, MapValue, QError, Some

CONTRACT_NAMES = {
    "is_nan", "is_inf", "is_finite", "is_zero", "is_subnormal", "signbit", "bits",
    "next_up", "next_down", "ulp", "qe", "steps", "nans", "same", "ieee_eq", "real", "round",
    "wrap", "fits", "mp.sqrt", "mp.exp", "mp.log", "mp.sin", "mp.cos", "mp.tan", "mp.atan",
    "cr.sqrt", "cr.exp", "cr.log", "cr.sin", "cr.cos", "cr.tan", "cr.atan",
    "le_uint", "len", "sorted", "is_sorted", "is_permutation", "is_subsequence", "distinct",
    "index_of", "keys", "values", "range", "some", "is_some", "is_none", "unwrap",
    "valid_utf8", "codepoints", "fresh", "same_object", "shares_memory", "eq",
}  # fmt: skip

I32, U32 = FixedIntT(32, True), FixedIntT(32, False)
F16, F32, F64 = FloatT("f16"), FloatT("f32"), FloatT("f64")


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


class Ctx:
    def __init__(self) -> None:
        self.fresh: set[int] = set()

    def fields(self, h: Handle) -> dict[str, Any]:
        return {"items": h.obj}

    def is_fresh(self, h: Handle) -> bool:
        return h.id in self.fresh

    def same_object(self, a: Handle, b: Handle) -> bool:
        return a.obj is b.obj

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        return False


def test_registry_matches_contract() -> None:
    assert set(PRELUDE) == CONTRACT_NAMES
    for name, fn in PRELUDE.items():
        assert isinstance(fn, PreludeFn) and fn.name == name
    assert {n for n, f in PRELUDE.items() if f.needs_types} == {
        "wrap",
        "fits",
        "round",
        "ulp",
        "qe",
    }
    assert {n for n, f in PRELUDE.items() if f.needs_ctx} == {
        "fresh",
        "same_object",
        "shares_memory",
        "eq",
    }


def test_call_plain() -> None:
    assert call("len", ((1, 2),)) == 2
    assert call("len", [b"abc"]) == 3
    assert call("is_nan", (f64(math.nan),)) is True
    assert call("bits", (f64(1.0),)) == 0x3FF0000000000000
    assert call("real", (f64(0.5),)) == Fraction(1, 2)
    assert call("mp.sqrt", (4,)) == 2
    assert call("some", (1,)) == Some(1)
    assert call("keys", (MapValue((("a", 1),)),)) == ("a",)


def test_call_generic() -> None:
    assert call("wrap", (2**31,), type_args=(I32,)) == -(2**31)
    assert call("wrap", (-1,), type_args=("u32",)) == 2**32 - 1
    assert call("fits", (2**31,), type_args=(I32,)) is False
    assert call("fits", (65504,), type_args=(F16,)) is True
    assert call("round", (Fraction(1, 3),), type_args=(F16,)) == FloatValue("f16", 0x3555)
    assert call("round", (1,), type_args=("f32",)) == FloatValue("f32", 0x3F800000)
    assert call("ulp", (1,), type_args=(F64,)) == Fraction(1, 2**52)
    assert call("ulp", (f64(1.0),), type_args=(F32,), arg_types=(F64,)) == Fraction(1, 2**23)


@pytest.mark.parametrize(
    ("name", "args", "type_args", "message"),
    [
        ("round", (1,), (I32,), "round<i32>: i32 is not a float format"),
        ("ulp", (1,), (), "ulp takes exactly one type argument"),
        ("wrap", (1,), (F32, I32), "exactly one type argument"),
        ("wrap", (1,), (F32,), "not a fixed-width integer type"),
        ("fits", (1,), (BOOL,), "not a fixed-width scalar type"),
        ("fits", (1,), ("nonsense",), "unknown type"),
        ("round", (f64(math.nan),), (F32,), "round<f32>: cannot promote NaN"),
    ],
)
def test_call_generic_errors(
    name: str, args: tuple[Any, ...], type_args: tuple[Any, ...], message: str
) -> None:
    with pytest.raises(EvalError, match=message):
        call(name, args, type_args=type_args)


def test_call_with_ctx_and_kwargs() -> None:
    ctx = Ctx()
    h1, h2 = Handle([1, 2], "Deque"), Handle([1, 2], "Deque")
    ctx.fresh.add(h1.id)
    assert call("fresh", (h1,), ctx=ctx) is True
    assert call("fresh", (h2,), ctx=ctx) is False
    assert call("same_object", (h1, h2), ctx=ctx) is False
    assert call("eq", (h1, h2), ctx=ctx) is True
    pz, nz = f64(0.0), f64(-0.0)
    assert call("eq", ((pz,), (nz,)), kwargs={"float": "ieee"}) is True
    assert call("eq", ((pz,), (nz,)), kwargs={"float": "bits"}) is False
    assert call("eq", ((1, 2), (2, 1)), kwargs={"order": "ignore"}) is True
    with pytest.raises(EvalError, match="fresh: needs an evaluation context"):
        call("fresh", (h1,))


def test_call_errors_are_eval_errors() -> None:
    with pytest.raises(EvalError, match="unknown prelude function 'nope'"):
        call("nope", ())
    with pytest.raises(EvalError, match="^len: "):
        call("len", ())
    with pytest.raises(EvalError, match="^is_nan: "):
        call("is_nan", (f64(1.0), f64(2.0)))
    with pytest.raises(EvalError, match="^eq: "):
        call("eq", (1, 1), kwargs={"tolerance": 1})


def test_type_const() -> None:
    assert type_const(I32, "min") == -(2**31) and type_const("i32", "max") == 2**31 - 1
    assert type_const("u8", "max") == 255
    assert type_const(F16, "max") == FloatValue("f16", 0x7BFF)
    assert type_const("f64", "min") == FloatValue("f64", 0xFFEFFFFFFFFFFFFF)
    with pytest.raises(EvalError, match="f64.nan is not a constant"):
        type_const("f64", "nan")
    with pytest.raises(EvalError):
        type_const(ListT(BOOL), "max")


# ---------------------------------------------------------------------------
# Clauses of examples/, evaluated with the prelude alone


def accurate(result: FloatValue, x: FloatValue) -> bool:
    """libm cos.accurate: qe(result, cr.cos(x)) <= 1."""
    e = call("qe", (result, call("cr.cos", (x,))))
    return e.le(QError(1, 0))


@given(st.floats())
def test_libm_cos_accurate_holds_for_math_cos(x: float) -> None:
    result = f64(math.cos(x)) if math.isfinite(x) else f64(math.nan)
    assert accurate(result, f64(x))


def test_libm_cos_accurate_demands_nan_for_nonfinite_inputs() -> None:
    for x in (math.inf, -math.inf, math.nan):
        assert accurate(f64(math.nan), f64(x))
        assert not accurate(f64(1.0), f64(x))


def test_libm_cos_accurate_catches_a_two_step_error() -> None:
    x = f64(0.5)
    good = f64(math.cos(0.5))
    bad = call("next_up", (call("next_up", (good,)),))
    assert accurate(good, x) and not accurate(bad, x)


def test_libm_sqrt_correctly_rounded() -> None:
    """libm sqrt.correctly_rounded: qe(result, cr.sqrt(x)) == 0, against math.sqrt."""
    for x in (2.0, 3.0, 1e-310, 1.7976931348623157e308, 0.1, 0.0, -0.0, math.inf, math.nan):
        v = f64(x)
        expected = call("round", (call("mp.sqrt", (v,)),), type_args=(F64,)) if x > 0 else v
        assert call("same", (call("cr.sqrt", (v,)), expected)) or math.isnan(x)
        assert call("qe", (f64(math.sqrt(x)), call("cr.sqrt", (v,)))) == QError.ZERO
    assert call("qe", (f64(math.nan), call("cr.sqrt", (f64(-1.0),)))) == QError.ZERO


def test_explore_cos16_correctly_rounded_sample() -> None:
    """explore.spec: the terms qe(cos16(v), cr.cos(v)) against numpy's float16 cos."""
    total = QError.ZERO
    for b in range(0, 0x7C00, 97):
        x = FloatValue("f16", b)
        result = floats.from_numpy(np.cos(floats.to_numpy(x)))
        expected = call("round", (call("mp.cos", (x,)),), type_args=(F16,))
        term = call("qe", (result, call("cr.cos", (x,))))
        assert term.le(QError(1, 0))
        assert (term == QError.ZERO) == call("same", (result, expected))
        total = total + term
    assert call("steps", (total,)) <= 10 and call("nans", (total,)) == 0


@given(st.integers(-(2**63), 2**63 - 1))
def test_binary_pack_i32_clauses(x: int) -> None:
    if not call("fits", (x,), type_args=(I32,)):
        return
    result = struct.pack("<i", x)
    assert call("len", (result,)) == 4
    assert call("le_uint", (result,)) == call("wrap", (x,), type_args=(U32,))


def test_sorting_clauses() -> None:
    xs = ((2, "b"), (1, "z"), (2, "a"), (1, "y"))
    result = tuple(sorted(xs, key=lambda p: p[0]))
    assert call("is_permutation", (result, xs))
    assert call("is_sorted", (tuple(p[0] for p in result),))
    assert not call("is_sorted", (tuple(p[0] for p in xs),))


def test_frames_select_clause() -> None:
    columns = ("a", "b", "c")
    rows = ((Some(f64(1.0)), None, Some(f64(math.nan))),)
    names = ("c", "a")
    expected = tuple(tuple(r[call("index_of", (columns, n))] for n in names) for r in rows)
    observed = ((Some(f64(math.nan)), Some(f64(1.0))),)
    assert call("distinct", (names,))
    assert call("eq", (observed, expected), kwargs={"float": "bits"})
