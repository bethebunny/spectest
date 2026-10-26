"""IEEE 754 binary floats: exact values, rounding, classification and formatting.

Every computation is exact integer or Fraction arithmetic on bit patterns.
Python floats appear only at the interop boundary (``from_python_float``,
``to_python_float``, numpy scalars).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from fractions import Fraction
from functools import cache
from typing import Any

from spectest.types import FLOAT_FORMATS, FloatT
from spectest.values import (
    NEG_INF,
    POS_INF,
    EvalError,
    FloatValue,
    Handle,
    MapValue,
    QError,
    Real,
    RecordValue,
    Some,
    is_infinity,
)


@dataclass(frozen=True)
class Format:
    """Parameters of a binary interchange format."""

    name: str
    exp_bits: int
    man_bits: int
    width: int
    precision: int  # significand bits, hidden bit included
    bias: int
    emin: int  # exponent of the smallest normal
    emax: int  # exponent of the largest finite
    sign_mask: int
    exp_all: int  # the all-ones exponent field (inf and NaN)
    man_mask: int
    quiet_bit: int

    @property
    def inf_bits(self) -> int:
        return self.exp_all << self.man_bits

    @property
    def max_bits(self) -> int:
        return self.inf_bits - 1


@cache
def _format(name: str) -> Format:
    if name not in FLOAT_FORMATS:
        raise EvalError(f"unknown float format {name!r}")
    exp_bits, man_bits = FLOAT_FORMATS[name]
    width = 1 + exp_bits + man_bits
    bias = (1 << (exp_bits - 1)) - 1
    return Format(
        name=name,
        exp_bits=exp_bits,
        man_bits=man_bits,
        width=width,
        precision=man_bits + 1,
        bias=bias,
        emin=1 - bias,
        emax=bias,
        sign_mask=1 << (width - 1),
        exp_all=(1 << exp_bits) - 1,
        man_mask=(1 << man_bits) - 1,
        quiet_bit=1 << (man_bits - 1),
    )


def fmt_info(fmt: str | FloatT | Format) -> Format:
    """The parameters of a format given by name, FloatT or Format."""
    if isinstance(fmt, Format):
        return fmt
    if isinstance(fmt, FloatT):
        return _format(fmt.fmt)
    return _format(fmt)


# ---------------------------------------------------------------------------
# Bits


def from_bits(fmt: str | FloatT, bits: int) -> FloatValue:
    """The value of format ``fmt`` with raw bit pattern ``bits``."""
    return FloatValue(fmt_info(fmt).name, bits)


def to_bits(v: FloatValue) -> int:
    return v.bits


def _check(v: Any, fn: str) -> FloatValue:
    if not isinstance(v, FloatValue):
        raise EvalError(f"{fn}: expected a float, got {v!r}")
    return v


def _fields(v: FloatValue) -> tuple[Format, int, int, int]:
    f = _format(v.fmt)
    sign = v.bits >> (f.width - 1)
    exp = (v.bits >> f.man_bits) & f.exp_all
    return f, sign, exp, v.bits & f.man_mask


def decode(v: FloatValue) -> tuple[int, int, int]:
    """(sign, biased exponent field, mantissa field)."""
    _, sign, exp, man = _fields(v)
    return sign, exp, man


# ---------------------------------------------------------------------------
# Constants


def zero(fmt: str | FloatT, negative: bool = False) -> FloatValue:
    f = fmt_info(fmt)
    return FloatValue(f.name, f.sign_mask if negative else 0)


def inf(fmt: str | FloatT, negative: bool = False) -> FloatValue:
    f = fmt_info(fmt)
    return FloatValue(f.name, f.inf_bits | (f.sign_mask if negative else 0))


def nan(fmt: str | FloatT, negative: bool = False, payload: int = 0) -> FloatValue:
    """A quiet NaN; ``payload`` fills the mantissa bits below the quiet bit."""
    f = fmt_info(fmt)
    bits = f.inf_bits | f.quiet_bit | (payload & (f.quiet_bit - 1))
    return FloatValue(f.name, bits | (f.sign_mask if negative else 0))


def max_finite(fmt: str | FloatT) -> FloatValue:
    """The largest finite value (``F.max``)."""
    f = fmt_info(fmt)
    return FloatValue(f.name, f.max_bits)


def min_finite(fmt: str | FloatT) -> FloatValue:
    """The most negative finite value (``F.min``)."""
    f = fmt_info(fmt)
    return FloatValue(f.name, f.sign_mask | f.max_bits)


def min_subnormal(fmt: str | FloatT) -> FloatValue:
    return FloatValue(fmt_info(fmt).name, 1)


def min_normal(fmt: str | FloatT) -> FloatValue:
    f = fmt_info(fmt)
    return FloatValue(f.name, 1 << f.man_bits)


# ---------------------------------------------------------------------------
# Classification


def is_nan(v: FloatValue) -> bool:
    _, _, exp, man = _fields(_check(v, "is_nan"))
    return exp == _format(v.fmt).exp_all and man != 0


def is_inf(v: FloatValue) -> bool:
    _, _, exp, man = _fields(_check(v, "is_inf"))
    return exp == _format(v.fmt).exp_all and man == 0


def is_finite(v: FloatValue) -> bool:
    f, _, exp, _ = _fields(_check(v, "is_finite"))
    return exp != f.exp_all


def is_zero(v: FloatValue) -> bool:
    _, _, exp, man = _fields(_check(v, "is_zero"))
    return exp == 0 and man == 0


def is_subnormal(v: FloatValue) -> bool:
    _, _, exp, man = _fields(_check(v, "is_subnormal"))
    return exp == 0 and man != 0


def is_normal(v: FloatValue) -> bool:
    f, _, exp, _ = _fields(_check(v, "is_normal"))
    return 0 < exp < f.exp_all


def signbit(v: FloatValue) -> bool:
    _, sign, _, _ = _fields(_check(v, "signbit"))
    return sign == 1


def bits(v: FloatValue) -> int:
    """The unsigned bit pattern."""
    return _check(v, "bits").bits


# ---------------------------------------------------------------------------
# Exact values


def _pow2(k: int) -> Fraction:
    return Fraction(1 << k) if k >= 0 else Fraction(1, 1 << -k)


def _scaled(sig: int, k: int) -> Fraction:
    return Fraction(sig << k) if k >= 0 else Fraction(sig, 1 << -k)


def _magnitude(f: Format, exp: int, man: int) -> Fraction:
    if exp == 0:
        return _scaled(man, f.emin - f.man_bits)
    return _scaled(man | (1 << f.man_bits), exp - f.bias - f.man_bits)


def to_real(v: FloatValue, fn: str = "real") -> Real:
    """The exact extended-real value; both zeros are 0. NaN raises EvalError."""
    f, sign, exp, man = _fields(_check(v, fn))
    if exp == f.exp_all:
        if man:
            raise EvalError(f"{fn}: cannot promote NaN {format_float(v)} ({v.fmt}) to a real")
        return NEG_INF if sign else POS_INF
    mag = _magnitude(f, exp, man)
    return -mag if sign else mag


def as_real(x: Any, fn: str) -> Real:
    """Promote an int, Fraction, infinity or FloatValue to an extended real."""
    if isinstance(x, bool):
        raise EvalError(f"{fn}: expected a number, got {x!r}")
    if isinstance(x, int):
        return Fraction(x)
    if isinstance(x, Fraction) or is_infinity(x):
        return x
    if isinstance(x, FloatValue):
        return to_real(x, fn)
    raise EvalError(f"{fn}: expected a number, got {x!r}")


def floor_log2(a: Fraction) -> int:
    """floor(log2(a)) for a > 0, exactly."""
    n, d = a.numerator, a.denominator
    e = n.bit_length() - d.bit_length()
    if (n << -e if e < 0 else n) < (d << e if e > 0 else d):
        e -= 1
    return e


def _div_round_even(n: int, d: int) -> int:
    q, r = divmod(n, d)
    twice = 2 * r
    if twice > d or (twice == d and q & 1):
        q += 1
    return q


def _encode(f: Format, sign: int, m: int, q: int) -> FloatValue:
    """The value (-1)^sign * m * 2^q, where m fits the format's significand at quantum q."""
    sign_bits = f.sign_mask if sign else 0
    if m == 0:
        return FloatValue(f.name, sign_bits)
    if m >> f.precision:
        m >>= 1
        q += 1
    if m >> f.man_bits:
        exp = q + f.man_bits + f.bias
        if exp >= f.exp_all:
            return FloatValue(f.name, sign_bits | f.inf_bits)
        return FloatValue(f.name, sign_bits | (exp << f.man_bits) | (m & f.man_mask))
    return FloatValue(f.name, sign_bits | m)


def round_to(r: Real | int, fmt: str | FloatT) -> FloatValue:
    """Correct rounding of an extended real to ``fmt``: nearest, ties to even.

    Overflow gives infinity, exact zero gives +0, and a nonzero value that
    underflows to zero keeps its sign.
    """
    f = fmt_info(fmt)
    if is_infinity(r):
        return inf(f.name, r.sign < 0)
    if isinstance(r, bool) or not isinstance(r, (int, Fraction)):
        raise EvalError(f"round<{f.name}>: expected a real, got {r!r}")
    r = Fraction(r)
    if r == 0:
        return FloatValue(f.name, 0)
    sign = 1 if r < 0 else 0
    a = -r if sign else r
    q = max(floor_log2(a), f.emin) - f.man_bits
    n, d = a.numerator, a.denominator
    if q >= 0:
        d <<= q
    else:
        n <<= -q
    return _encode(f, sign, _div_round_even(n, d), q)


def fits(r: Real | int, fmt: str | FloatT) -> bool:
    """Is the extended real exactly representable in ``fmt``? Infinities are."""
    if is_infinity(r):
        return True
    return to_real(round_to(r, fmt)) == r


def convert(v: FloatValue, fmt: str | FloatT) -> FloatValue:
    """Format conversion: correctly rounded, signed zeros kept.

    A NaN keeps its sign and the leading payload bits, and becomes quiet.
    """
    f = fmt_info(fmt)
    if v.fmt == f.name:
        return v
    src, sign, exp, man = _fields(v)
    sign_bits = f.sign_mask if sign else 0
    if exp == src.exp_all:
        if man == 0:
            return FloatValue(f.name, sign_bits | f.inf_bits)
        shift = src.man_bits - f.man_bits
        payload = man >> shift if shift >= 0 else man << -shift
        return FloatValue(f.name, sign_bits | f.inf_bits | f.quiet_bit | (payload & f.man_mask))
    if exp == 0 and man == 0:
        return FloatValue(f.name, sign_bits)
    return round_to(to_real(v), f)


def negate(v: FloatValue) -> FloatValue:
    """Flip the sign bit (unary minus on a float); NaNs included."""
    f = _format(_check(v, "-").fmt)
    return FloatValue(v.fmt, v.bits ^ f.sign_mask)


def next_up(v: FloatValue) -> FloatValue:
    """IEEE nextUp: the least value greater than v. NaN gives NaN, +inf gives +inf."""
    f, sign, exp, man = _fields(_check(v, "next_up"))
    if exp == f.exp_all and man:
        return v
    if v.bits == f.inf_bits:
        return v
    if exp == 0 and man == 0:
        return FloatValue(v.fmt, 1)
    return FloatValue(v.fmt, v.bits - 1 if sign else v.bits + 1)


def next_down(v: FloatValue) -> FloatValue:
    """IEEE nextDown: the greatest value less than v."""
    _check(v, "next_down")
    return negate(next_up(negate(v)))


def ulp(r: Real | int, fmt: str | FloatT) -> Fraction:
    """The spacing of ``fmt`` in the binade of |r|.

    2^(max(floor(log2|r|), emin) - p + 1); ulp(0) is the smallest subnormal,
    and magnitudes beyond the largest finite (infinities included) use the
    top binade.
    """
    f = fmt_info(fmt)
    if is_infinity(r):
        e = f.emax
    else:
        a = abs(Fraction(r))
        e = f.emin if a == 0 else min(max(floor_log2(a), f.emin), f.emax)
    return _pow2(e - f.man_bits)


def ordinal(v: FloatValue) -> int:
    """The monotone ordinal of a non-NaN value: consecutive values differ by 1.

    bits for non-negative values, -(bits without the sign) for negative ones,
    so both zeros are 0 and the infinities are the extreme ordinals.
    """
    f = _format(_check(v, "ordinal").fmt)
    mag = v.bits & ~f.sign_mask
    return -mag if v.bits & f.sign_mask else mag


def qe(x: FloatValue, y: FloatValue) -> QError:
    """The quantized error between two values of one format.

    The number of values of the format in [min(x, y), max(x, y)), with -0 and +0
    one value and the infinities counted as values; 0 when both are NaN and
    1·nan when exactly one is. Commutative; the ulp distance within a binade.
    """
    _check(x, "qe")
    _check(y, "qe")
    if x.fmt != y.fmt:
        raise EvalError(f"qe: compares two values of one format, got {x.fmt} and {y.fmt}")
    x_nan, y_nan = is_nan(x), is_nan(y)
    if x_nan or y_nan:
        return QError(0, 0 if x_nan and y_nan else 1)
    return QError(abs(ordinal(x) - ordinal(y)), 0)


def _qerror(e: Any, fn: str) -> QError:
    if not isinstance(e, QError):
        raise EvalError(f"{fn}: expected a qerr, got {e!r}")
    return e


def steps(e: QError) -> int:
    """The step count k of a quantized error k + m·nan."""
    return _qerror(e, "steps").steps


def nans(e: QError) -> int:
    """The NaN count m of a quantized error k + m·nan."""
    return _qerror(e, "nans").nans


def ieee_eq(a: FloatValue, b: FloatValue) -> bool:
    """IEEE equality: NaN equals nothing, +0 equals -0."""
    _check(a, "ieee_eq")
    _check(b, "ieee_eq")
    if is_nan(a) or is_nan(b):
        return False
    return to_real(a) == to_real(b)


def same(a: Any, b: Any) -> bool:
    """Structural identity: floats by format and bits, handles by identity, qerr by parts."""
    if isinstance(a, FloatValue) or isinstance(b, FloatValue):
        return isinstance(a, FloatValue) and isinstance(b, FloatValue) and a == b
    if isinstance(a, (tuple, list)) or isinstance(b, (tuple, list)):
        return (
            isinstance(a, (tuple, list))
            and isinstance(b, (tuple, list))
            and len(a) == len(b)
            and all(same(x, y) for x, y in zip(a, b))
        )
    if a is None or b is None:
        return a is b
    if isinstance(a, Some) or isinstance(b, Some):
        return isinstance(a, Some) and isinstance(b, Some) and same(a.value, b.value)
    if isinstance(a, MapValue) or isinstance(b, MapValue):
        return _same_map(a, b)
    if isinstance(a, RecordValue) or isinstance(b, RecordValue):
        return (
            isinstance(a, RecordValue)
            and isinstance(b, RecordValue)
            and a.name == b.name
            and len(a.fields) == len(b.fields)
            and all(ka == kb and same(x, y) for (ka, x), (kb, y) in zip(a.fields, b.fields))
        )
    if isinstance(a, Handle) or isinstance(b, Handle):
        return a is b
    if isinstance(a, QError) or isinstance(b, QError):
        return isinstance(a, QError) and isinstance(b, QError) and a == b
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if is_infinity(a) or is_infinity(b):
        return is_infinity(a) and is_infinity(b) and a.sign == b.sign
    if isinstance(a, (str, bytes)) or isinstance(b, (str, bytes)):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, Fraction)) and isinstance(b, (int, Fraction)):
        return a == b
    raise EvalError(f"same: cannot compare {a!r} and {b!r}")


def _same_map(a: Any, b: Any) -> bool:
    if not (isinstance(a, MapValue) and isinstance(b, MapValue)):
        return False
    if len(a.items) != len(b.items):
        return False
    unmatched = list(b.items)
    for ka, va in a.items:
        for i, (kb, vb) in enumerate(unmatched):
            if same(ka, kb):
                if not same(va, vb):
                    return False
                del unmatched[i]
                break
        else:
            return False
    return True


# ---------------------------------------------------------------------------
# Formatting


def _pow10(k: int) -> Fraction:
    return Fraction(10**k) if k >= 0 else Fraction(1, 10**-k)


def floor_log10(a: Fraction) -> int:
    """floor(log10(a)) for a > 0, exactly."""
    e2 = floor_log2(a)
    k = (e2 * 30103) // 100000
    while _pow10(k) > a:
        k -= 1
    while _pow10(k + 1) <= a:
        k += 1
    return k


def shortest_digits(v: FloatValue) -> tuple[str, int]:
    """The shortest decimal that rounds back to v in v's format.

    Returns (digits, e): the value of |v| is 0.d... scaled so that it reads
    d[0].d[1:] x 10^e. Among shortest candidates the nearest to v wins.
    v must be finite and nonzero.
    """
    f = _format(v.fmt)
    target = v.bits & ~f.sign_mask
    a = abs(to_real(v))
    k = floor_log10(a)
    n = 1
    while True:
        scale = k - n + 1
        q = a / _pow10(scale)
        lo = q.numerator // q.denominator
        for c in sorted((lo, lo + 1), key=lambda c: (abs(c - q), c & 1)):
            if round_to(c * _pow10(scale), f).bits == target:
                digits = str(c)
                e = scale + len(digits) - 1
                return digits.rstrip("0") or "0", e
        n += 1


def _render(digits: str, e: int) -> str:
    if -4 <= e < 16:
        if e >= 0:
            whole = digits[: e + 1].ljust(e + 1, "0")
            frac = digits[e + 1 :] or "0"
        else:
            whole, frac = "0", "0" * (-e - 1) + digits
        return f"{whole}.{frac}"
    mantissa = digits[0] + ("." + digits[1:] if len(digits) > 1 else "")
    return f"{mantissa}e{'-' if e < 0 else '+'}{abs(e):02d}"


def format_float(v: FloatValue) -> str:
    """A short human string: "1.5", "-0.0", "inf", "nan", "nan:0x7ff8000000000001".

    Finite values print as the shortest decimal that round-trips in their own
    format, in the style of Python's float repr. The canonical quiet NaN
    prints as "nan"; every other NaN shows its full bit pattern.
    """
    f, sign, exp, man = _fields(v)
    if exp == f.exp_all:
        if man == 0:
            return "-inf" if sign else "inf"
        if v.bits == f.inf_bits | f.quiet_bit:
            return "nan"
        return f"nan:0x{v.bits:0{f.width // 4}x}"
    if exp == 0 and man == 0:
        return "-0.0" if sign else "0.0"
    if f.name == "f64":
        return repr(struct.unpack("<d", struct.pack("<Q", v.bits))[0])
    return ("-" if sign else "") + _render(*shortest_digits(v))


# ---------------------------------------------------------------------------
# Python and numpy interop


def from_python_float(
    x: float, fmt: str | FloatT = "f64", *, exact: bool = False
) -> FloatValue:
    """A Python float (or int) as a value of ``fmt``.

    f64 is bit-exact. Other formats round correctly (NaNs keep sign and leading
    payload bits); with ``exact=True`` a value that would change raises
    ValueError.
    """
    f = fmt_info(fmt)
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        raise TypeError(f"expected a float, got {x!r}")
    if isinstance(x, int):
        v = round_to(x, f)
        if exact and to_real(v) != x:
            raise ValueError(f"{x} is not exactly representable as {f.name}")
        return v
    v64 = FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])
    v = convert(v64, f)
    if exact and not is_nan(v64) and to_real(v) != to_real(v64):
        raise ValueError(f"{x!r} is not exactly representable as {f.name}")
    return v


def to_python_float(v: FloatValue) -> float:
    """The Python float with v's value (exact: every format widens into f64)."""
    v64 = convert(_check(v, "to_python_float"), "f64")
    return struct.unpack("<d", struct.pack("<Q", v64.bits))[0]


_NUMPY = {
    "float16": ("f16", "uint16"),
    "float32": ("f32", "uint32"),
    "float64": ("f64", "uint64"),
    "bfloat16": ("bf16", "uint16"),
}


def from_numpy(x: Any) -> FloatValue:
    """A numpy float16/float32/float64 (or ml_dtypes bfloat16) scalar, bit-exact."""
    import numpy as np

    arr = np.asarray(x)
    if arr.shape != () or arr.dtype.name not in _NUMPY:
        raise TypeError(f"expected a numpy float scalar, got {x!r}")
    fmt, uint = _NUMPY[arr.dtype.name]
    return FloatValue(fmt, int(arr.view(uint)[()]))


def to_numpy(v: FloatValue) -> Any:
    """The numpy scalar with v's exact bits (bf16 needs ml_dtypes)."""
    import numpy as np

    _check(v, "to_numpy")
    if v.fmt == "bf16":
        try:
            import ml_dtypes
        except ImportError as exc:
            raise TypeError("bf16 needs the ml_dtypes package for numpy scalars") from exc
        return np.array(v.bits, dtype=np.uint16).view(ml_dtypes.bfloat16)[()]
    dtype = {"f16": np.float16, "f32": np.float32, "f64": np.float64}[v.fmt]
    uint = {"f16": np.uint16, "f32": np.uint32, "f64": np.uint64}[v.fmt]
    return np.array(v.bits, dtype=uint).view(dtype)[()]
