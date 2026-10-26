"""Fixed-width integers: wrap, fits, bounds and little-endian bytes."""

from __future__ import annotations

from fractions import Fraction
from typing import Any

from spectest.prelude import floats
from spectest.types import FixedIntT, FloatT, Type, scalar_type
from spectest.values import EvalError, is_infinity


def int_type(t: Type | str, fn: str = "wrap") -> FixedIntT:
    """A fixed-width integer type given as a Type or a name like "i32"."""
    resolved = scalar_type(t) if isinstance(t, str) else t
    if not isinstance(resolved, FixedIntT):
        raise EvalError(f"{fn}: {t} is not a fixed-width integer type")
    return resolved


def int_min(t: Type | str) -> int:
    """``I.min``."""
    return int_type(t, "min").min


def int_max(t: Type | str) -> int:
    """``I.max``."""
    return int_type(t, "max").max


def _integer(n: Any, fn: str) -> int:
    if isinstance(n, bool) or not isinstance(n, int):
        raise EvalError(f"{fn}: expected an integer, got {n!r}")
    return n


def wrap(n: Any, t: Type | str) -> int:
    """n reduced modulo 2^bits into the range of the fixed-width type."""
    it = int_type(t, "wrap")
    n = _integer(n, f"wrap<{it}>")
    m = n & ((1 << it.bits) - 1)
    if it.signed and m >> (it.bits - 1):
        m -= 1 << it.bits
    return m


def fits(x: Any, t: Type | str) -> bool:
    """Is x exactly a value of t? For integer types: an integer within bounds.

    For a float format: the real is exactly representable (infinities are).
    Floats given as x are promoted first, so a NaN raises EvalError.
    """
    resolved = scalar_type(t) if isinstance(t, str) else t
    if isinstance(resolved, FloatT):
        return floats.fits(floats.as_real(x, f"fits<{resolved}>"), resolved)
    it = int_type(resolved, "fits")
    if isinstance(x, int) and not isinstance(x, bool):
        return it.min <= x <= it.max
    r = floats.as_real(x, f"fits<{it}>")
    if is_infinity(r):
        return False
    r = Fraction(r)
    return r.denominator == 1 and it.min <= r.numerator <= it.max


def le_uint(b: Any) -> int:
    """The unsigned little-endian value of a byte string (0 for b"")."""
    if not isinstance(b, (bytes, bytearray)):
        raise EvalError(f"le_uint: expected bytes, got {b!r}")
    return int.from_bytes(b, "little")
