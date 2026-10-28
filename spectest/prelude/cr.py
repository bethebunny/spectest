"""Correctly rounded elementary functions in each float format.

``cr.f(x)`` returns f(x) rounded to nearest, ties to even, in the format of x.
MPFR rounds correctly by construction; computing in a context with the
format's precision, exponent range and ``subnormalize=True`` makes that
rounding IEEE 754's, subnormal results and overflow to infinity included.
Each call uses its own context, never the thread's current one.

IEEE 754's special cases: a NaN input, and an invalid operation (sqrt or
log of a negative, sin/cos/tan of an infinity), give the format's canonical
quiet NaN; signed zeros follow the function (sin(-0) = -0, sqrt(-0) = -0,
log(+-0) = -inf, cos(+-0) = 1); exp overflows to +inf and underflows to +0 or
a subnormal; atan(+-inf) = +-(pi/2 rounded).
"""

from __future__ import annotations

import struct
from collections.abc import Callable
from functools import cache
from typing import Any

import gmpy2

from spectest.prelude import floats
from spectest.values import EvalError, FloatValue

FUNCTIONS = ("sqrt", "exp", "log", "sin", "cos", "tan", "atan")

_STRUCT = {"f16": ("<e", "<H"), "f32": ("<f", "<I"), "f64": ("<d", "<Q")}


@cache
def _template(fmt: str) -> gmpy2.context:
    f = floats.fmt_info(fmt)
    return gmpy2.context(
        precision=f.precision,
        round=gmpy2.RoundToNearest,
        emax=f.emax + 1,
        emin=f.emin - f.precision + 2,
        subnormalize=True,
        trap_underflow=False,
        trap_overflow=False,
        trap_inexact=False,
        trap_invalid=False,
        trap_erange=False,
        trap_divzero=False,
    )


def context(fmt: str) -> gmpy2.context:
    """A fresh context that rounds to ``fmt`` exactly as IEEE 754 does."""
    return _template(floats.fmt_info(fmt).name).copy()


def _to_double(v: FloatValue) -> float:
    if v.fmt == "bf16":
        return struct.unpack("<f", struct.pack("<I", v.bits << 16))[0]
    value, raw = _STRUCT[v.fmt]
    return struct.unpack(value, struct.pack(raw, v.bits))[0]


def _from_double(x: float, fmt: str) -> FloatValue:
    if fmt == "bf16":
        return FloatValue(fmt, struct.unpack("<I", struct.pack("<f", x))[0] >> 16)
    value, raw = _STRUCT[fmt]
    return FloatValue(fmt, struct.unpack(raw, struct.pack(value, x))[0])


def _apply(name: str, op: Callable[[gmpy2.context, Any], Any], x: Any) -> FloatValue:
    if not isinstance(x, FloatValue):
        raise EvalError(f"cr.{name}: expected a float, got {x!r}")
    if floats.is_nan(x):
        return floats.nan(x.fmt)
    ctx = context(x.fmt)
    y = op(ctx, gmpy2.mpfr(_to_double(x), 0, ctx))
    if gmpy2.is_nan(y):
        return floats.nan(x.fmt)
    return _from_double(float(y), x.fmt)


def sqrt(x: Any) -> FloatValue:
    return _apply("sqrt", lambda c, a: c.sqrt(a), x)


def exp(x: Any) -> FloatValue:
    return _apply("exp", lambda c, a: c.exp(a), x)


def log(x: Any) -> FloatValue:
    return _apply("log", lambda c, a: c.log(a), x)


def sin(x: Any) -> FloatValue:
    return _apply("sin", lambda c, a: c.sin(a), x)


def cos(x: Any) -> FloatValue:
    return _apply("cos", lambda c, a: c.cos(a), x)


def tan(x: Any) -> FloatValue:
    return _apply("tan", lambda c, a: c.tan(a), x)


def atan(x: Any) -> FloatValue:
    return _apply("atan", lambda c, a: c.atan(a), x)
