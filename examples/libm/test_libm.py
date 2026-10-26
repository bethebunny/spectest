"""libm conformance: Python's math module, numpy, and two seeded bugs.

The conformances run as pytest items, one per clause. The plain test functions
at the end check the findings of examples/libm/FINDINGS.md without spectest:
they compute the correctly rounded results with MPFR (gmpy2) directly.
"""

from __future__ import annotations

import math
import struct

import gmpy2
import libm_impls
import numpy as np
import pytest

import spectest

spec = spectest.load("libm.spec")

test_math = spectest.conformance(
    spec,
    impls={"cos": math.cos, "sqrt": math.sqrt},
    errors={ValueError: "DomainError"},
    # FINDINGS.md, "math.cos raises for infinite arguments": IEEE 754 cos(+-inf) is an
    # invalid operation whose default result is NaN, which cos.accurate demands; math.cos
    # raises ValueError, and no raises or may_raise of cos admits DomainError.
    expect_fail={"cos#raises"},
)

test_numpy = spectest.conformance(
    spec,
    impls={"cos": np.cos, "cos32": np.cos, "cos16": np.cos, "sqrt": np.sqrt},
    scalars="numpy",
)

test_seeded_bugs = spectest.conformance(
    spec,
    impls={"cos": libm_impls.cos, "sqrt": libm_impls.sqrt},
    errors={ValueError: "DomainError"},
    expect_fail={
        # The seeded bugs: both formulas break their accuracy clause.
        "cos.accurate",
        "sqrt.correctly_rounded",
        # sin(x + pi/2) is not even: x + pi/2 and -x + pi/2 round differently.
        "cos.even",
        # math.sin(inf) raises ValueError, as math.cos does (see test_math).
        "cos#raises",
        # math.log(0.0) raises ValueError, so sqrt(+-0) raises DomainError, which sqrt
        # admits only for negative arguments.
        "sqrt#raises",
    },
)


# ---------------------------------------------------------------------------
# The findings, checked without spectest

FORMATS = {"f16": (11, -23, 16), "f32": (24, -148, 128), "f64": (53, -1073, 1024)}


def from_bits(bits: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


def to_bits(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def correctly_rounded(fn: str, x: float, fmt: str) -> float:
    """fn(x) rounded once, to nearest, into an IEEE format (as a Python float), with MPFR."""
    precision, emin, emax = FORMATS[fmt]
    ctx = gmpy2.context(precision=precision, emin=emin, emax=emax, subnormalize=True)
    exact = gmpy2.mpfr(x, 64)
    return float(getattr(ctx, fn)(exact))


def test_math_cos_raises_for_infinite_arguments() -> None:
    for x in (math.inf, -math.inf):
        with pytest.raises(ValueError, match="math domain error"):
            math.cos(x)
        with np.errstate(invalid="ignore"):
            assert math.isnan(np.cos(np.float64(x)))
        assert math.isnan(correctly_rounded("cos", x, "f64"))


def test_seeded_cos_is_two_ulps_off() -> None:
    x = from_bits(0x402FA0435A46547E)
    assert to_bits(correctly_rounded("cos", x, "f64")) == 0xBFEFD2D6F1C1BC67
    assert to_bits(libm_impls.cos(x)) == 0xBFEFD2D6F1C1BC69
    assert to_bits(math.cos(x)) == 0xBFEFD2D6F1C1BC67


def test_seeded_cos_is_not_even() -> None:
    assert to_bits(libm_impls.cos(1.0)) == 0x3FE14A280FB5068C
    assert to_bits(libm_impls.cos(-1.0)) == 0x3FE14A280FB5068B
    assert to_bits(correctly_rounded("cos", 1.0, "f64")) == 0x3FE14A280FB5068C


def test_seeded_sqrt_is_a_hundred_ulps_off_at_the_smallest_subnormal() -> None:
    x = from_bits(1)
    assert math.sqrt(x) == 2.0**-537 == correctly_rounded("sqrt", x, "f64")
    assert to_bits(libm_impls.sqrt(x)) - to_bits(2.0**-537) == 100
    with pytest.raises(ValueError):
        libm_impls.sqrt(0.0)


def test_numpy_half_precision_cos_is_not_correctly_rounded() -> None:
    for bits in (0x2B7C, 0xAB7C):
        x = np.frombuffer(struct.pack("<H", bits), dtype=np.float16)[0]
        got = np.cos(x)
        want = np.float16(correctly_rounded("cos", float(x), "f16"))
        ulps = abs(int(got.view(np.uint16)) - int(want.view(np.uint16)))
        assert ulps == 1, (bits, got, want)
        single = np.cos(np.float32(x))
        assert got == np.float16(single)
        exact = gmpy2.context(precision=200).cos(gmpy2.mpfr(float(x), 64))
        lo, hi = sorted((float(got), float(want)))
        midpoint = gmpy2.mpfr((lo + hi) / 2, 64)
        assert float(single) == float(midpoint), "cos rounds to the f16 midpoint in f32"
        assert (exact < midpoint) == (float(want) < float(got))


def test_numpy_single_precision_cos_is_not_correctly_rounded() -> None:
    x = np.frombuffer(struct.pack("<I", 0x3F787778), dtype=np.float32)[0]
    got = np.cos(x)
    want = np.float32(correctly_rounded("cos", float(x), "f32"))
    assert abs(int(got.view(np.uint32)) - int(want.view(np.uint32))) == 1
