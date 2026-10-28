"""Reference elementary functions: MPFR (gmpy2) at 256 bits, as exact Fractions.

Each call uses its own gmpy2 context object and never touches the thread's
current context. An input converts to MPFR exactly when it is a dyadic
rational of at most 256 significant bits (every float is), and is otherwise
rounded to nearest at 256 bits. The result is MPFR's correctly rounded
256-bit value, returned exactly as a Fraction.

Domain errors (sqrt of a negative, log of a non-positive, a trigonometric
function of an infinity) and results outside the reference exponent range
(|e| > 2^18, far beyond every IEEE format here) raise EvalError.
"""

from __future__ import annotations

from collections.abc import Callable
from fractions import Fraction
from typing import Any

import gmpy2

from spectest.prelude import floats
from spectest.values import NEG_INF, POS_INF, EvalError, Real, is_infinity

PRECISION = 256
EXP_LIMIT = 1 << 18


def context() -> gmpy2.context:
    """A fresh 256-bit, round-to-nearest context with no traps."""
    return gmpy2.context(
        precision=PRECISION,
        round=gmpy2.RoundToNearest,
        emax=EXP_LIMIT,
        emin=-EXP_LIMIT,
        subnormalize=False,
        trap_underflow=False,
        trap_overflow=False,
        trap_inexact=False,
        trap_invalid=False,
        trap_erange=False,
        trap_divzero=False,
    )


def to_mpfr(r: Real, ctx: gmpy2.context) -> Any:
    """The extended real as an mpfr of ``ctx`` (rounded to nearest when not exact)."""
    if is_infinity(r):
        return gmpy2.mpfr("inf" if r.sign > 0 else "-inf", 0, 10, ctx)
    return gmpy2.mpfr(gmpy2.mpq(r.numerator, r.denominator), 0, ctx)


def from_mpfr(x: Any) -> Real:
    """An mpfr as an exact extended real (NaN raises EvalError)."""
    if gmpy2.is_nan(x):
        raise EvalError("mp: NaN result")
    if gmpy2.is_infinite(x):
        return POS_INF if x > 0 else NEG_INF
    n, d = x.as_integer_ratio()
    return Fraction(int(n), int(d))


def _apply(name: str, op: Callable[[gmpy2.context, Any], Any], r: Real) -> Real:
    fn = f"mp.{name}"
    ctx = context()
    arg = to_mpfr(r, ctx)
    if gmpy2.is_infinite(arg) and not is_infinity(r):
        raise EvalError(f"{fn}: argument {_show(r)} is outside the reference range")
    y = op(ctx, arg)
    if gmpy2.is_nan(y):
        raise EvalError(f"{fn}: undefined at {_show(r)}")
    if ctx.overflow or ctx.underflow or (gmpy2.is_infinite(y) and not is_infinity(r)):
        raise EvalError(f"{fn}: result at {_show(r)} is outside the reference range")
    return from_mpfr(y)


def _show(r: Real) -> str:
    from spectest.prelude.reals import format_real

    return format_real(r)


def _sign(r: Real) -> int:
    if is_infinity(r):
        return r.sign
    return (r > 0) - (r < 0)


def sqrt(x: Any) -> Real:
    r = floats.as_real(x, "mp.sqrt")
    if _sign(r) < 0:
        raise EvalError(f"mp.sqrt: argument must be non-negative, got {_show(r)}")
    return _apply("sqrt", lambda c, a: c.sqrt(a), r)


def exp(x: Any) -> Real:
    return _apply("exp", lambda c, a: c.exp(a), floats.as_real(x, "mp.exp"))


def log(x: Any) -> Real:
    r = floats.as_real(x, "mp.log")
    if _sign(r) <= 0:
        raise EvalError(f"mp.log: argument must be positive, got {_show(r)}")
    return _apply("log", lambda c, a: c.log(a), r)


def sin(x: Any) -> Real:
    return _apply("sin", lambda c, a: c.sin(a), floats.as_real(x, "mp.sin"))


def cos(x: Any) -> Real:
    return _apply("cos", lambda c, a: c.cos(a), floats.as_real(x, "mp.cos"))


def tan(x: Any) -> Real:
    return _apply("tan", lambda c, a: c.tan(a), floats.as_real(x, "mp.tan"))


def atan(x: Any) -> Real:
    return _apply("atan", lambda c, a: c.atan(a), floats.as_real(x, "mp.atan"))


def pi() -> Fraction:
    """pi rounded to 256 bits."""
    return from_mpfr(context().const_pi())
