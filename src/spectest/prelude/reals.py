"""Arithmetic and comparison on extended reals: exact rationals plus +-infinity.

Operands may be ints (and fixed-width ints, which are ints), Fractions,
POS_INF / NEG_INF, or FloatValues, which are promoted (NaN is an EvalError).
Integer operands stay ints where the result is an integer; ``/`` always gives
a Fraction. Undefined cases raise EvalError naming the operation.
"""

from __future__ import annotations

from fractions import Fraction
from typing import Any

from spectest.prelude import floats
from spectest.values import NEG_INF, POS_INF, EvalError, FloatValue, Real, is_infinity

Number = int | Fraction | Real


def promote(x: Any, fn: str = "real") -> Real:
    """The extended-real value of an int, Fraction, infinity or float (``real(x)``)."""
    return floats.as_real(x, fn)


def _num(x: Any, op: str) -> Number:
    if isinstance(x, bool):
        raise EvalError(f"{op}: expected a number, got {x!r}")
    if isinstance(x, (int, Fraction)) or is_infinity(x):
        return x
    if isinstance(x, FloatValue):
        return floats.to_real(x, op)
    raise EvalError(f"{op}: expected a number, got {x!r}")


def _inf(sign: int) -> Real:
    return POS_INF if sign > 0 else NEG_INF


def _sign(x: Number) -> int:
    if is_infinity(x):
        return x.sign
    return (x > 0) - (x < 0)


def add(a: Any, b: Any) -> Number:
    a, b = _num(a, "+"), _num(b, "+")
    if is_infinity(a) or is_infinity(b):
        if is_infinity(a) and is_infinity(b) and a.sign != b.sign:
            raise EvalError(f"+: {a!r} + {b!r} is undefined")
        return a if is_infinity(a) else b
    return a + b


def sub(a: Any, b: Any) -> Number:
    a, b = _num(a, "-"), _num(b, "-")
    if is_infinity(a) or is_infinity(b):
        if is_infinity(a) and is_infinity(b) and a.sign == b.sign:
            raise EvalError(f"-: {a!r} - {b!r} is undefined")
        return a if is_infinity(a) else _inf(-b.sign)
    return a - b


def mul(a: Any, b: Any) -> Number:
    a, b = _num(a, "*"), _num(b, "*")
    if is_infinity(a) or is_infinity(b):
        sign = _sign(a) * _sign(b)
        if sign == 0:
            raise EvalError(f"*: {a!r} * {b!r} is undefined")
        return _inf(sign)
    return a * b


def truediv(a: Any, b: Any) -> Real:
    a, b = _num(a, "/"), _num(b, "/")
    if not is_infinity(b) and b == 0:
        raise EvalError(f"/: division by zero ({format_real(a)} / 0)")
    if is_infinity(a):
        if is_infinity(b):
            raise EvalError(f"/: {a!r} / {b!r} is undefined")
        return _inf(a.sign * _sign(b))
    if is_infinity(b):
        return Fraction(0)
    return Fraction(a) / b


def floordiv(a: Any, b: Any) -> int:
    """floor(a / b) for finite a and b."""
    a, b = _num(a, "//"), _num(b, "//")
    if is_infinity(a) or is_infinity(b):
        raise EvalError(f"//: {a!r} // {b!r} is undefined")
    if b == 0:
        raise EvalError(f"//: division by zero ({format_real(a)} // 0)")
    return int(a // b)


def mod(a: Any, b: Any) -> int:
    """Floored modulus of integers: the result has the sign of b."""
    for x in (a, b):
        if isinstance(x, bool) or not isinstance(x, int):
            raise EvalError(f"%: expected integers, got {x!r}")
    if b == 0:
        raise EvalError(f"%: division by zero ({a} % 0)")
    return a % b


def neg(a: Any) -> Any:
    """Unary minus. On a float it flips the sign bit and keeps the format."""
    if isinstance(a, FloatValue):
        return floats.negate(a)
    a = _num(a, "-")
    if is_infinity(a):
        return _inf(-a.sign)
    return -a


def compare(a: Any, b: Any, op: str = "compare") -> int:
    """-1, 0 or 1 as a <, ==, > b."""
    a, b = _num(a, op), _num(b, op)
    ra = a.sign if is_infinity(a) else 0
    rb = b.sign if is_infinity(b) else 0
    if ra or rb:
        return (ra > rb) - (ra < rb)
    return (a > b) - (a < b)


def lt(a: Any, b: Any) -> bool:
    return compare(a, b, "<") < 0


def le(a: Any, b: Any) -> bool:
    return compare(a, b, "<=") <= 0


def gt(a: Any, b: Any) -> bool:
    return compare(a, b, ">") > 0


def ge(a: Any, b: Any) -> bool:
    return compare(a, b, ">=") >= 0


def eq(a: Any, b: Any) -> bool:
    return compare(a, b, "==") == 0


def ne(a: Any, b: Any) -> bool:
    return compare(a, b, "!=") != 0


def format_real(r: Any, digits: int = 20) -> str:
    """A human string for an extended real.

    Integers and terminating decimals of at most 25 significant digits print
    exactly; other values print as "~" and ``digits`` significant digits.
    """
    if is_infinity(r):
        return "inf" if r.sign > 0 else "-inf"
    if isinstance(r, FloatValue):
        return floats.format_float(r)
    if isinstance(r, bool) or not isinstance(r, (int, Fraction)):
        return repr(r)
    r = Fraction(r)
    if r == 0:
        return "0"
    sign = "-" if r < 0 else ""
    a = abs(r)
    exact = _exact_decimal(a, 25)
    if exact is not None:
        return sign + exact
    return f"~{sign}{_approximate(a, digits)}"


def _exact_decimal(a: Fraction, limit: int) -> str | None:
    d = a.denominator
    twos = (d & -d).bit_length() - 1
    rest = d >> twos
    fives = 0
    while rest % 5 == 0:
        rest //= 5
        fives += 1
    places = max(twos, fives)
    if rest != 1 or places > limit:
        return None
    scaled = a * 10**places
    if scaled.numerator >= 10**limit:
        return None
    if places == 0:
        return str(scaled.numerator)
    text = str(scaled.numerator).rjust(places + 1, "0")
    return f"{text[:-places]}.{text[-places:].rstrip('0')}"


def _approximate(a: Fraction, digits: int) -> str:
    k = floats.floor_log10(a)
    shift = k - digits + 1
    scaled = a / 10**shift if shift >= 0 else a * 10**-shift
    n = round(scaled)
    if n >= 10**digits:
        n //= 10
        k += 1
    text = str(n)
    if -5 <= k < digits:
        if k >= 0:
            return f"{text[: k + 1]}.{text[k + 1 :]}".rstrip("0").rstrip(".")
        return "0." + "0" * (-k - 1) + text.rstrip("0")
    return f"{text[0]}.{text[1:].rstrip('0') or '0'}e{k:+d}"
