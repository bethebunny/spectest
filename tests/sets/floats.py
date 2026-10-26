"""Float helpers for the set tests: Python floats to and from FloatValue."""

from __future__ import annotations

import struct

from spectest.values import FloatValue

STRUCT = {"f16": (">e", ">H"), "f32": (">f", ">I"), "f64": (">d", ">Q")}


def fv(fmt: str, x: float) -> FloatValue:
    """The FloatValue of a Python float (exact for f64, rounded by struct otherwise)."""
    if fmt == "bf16":
        return FloatValue(fmt, struct.unpack(">I", struct.pack(">f", x))[0] >> 16)
    flt, uint = STRUCT[fmt]
    return FloatValue(fmt, struct.unpack(uint, struct.pack(flt, x))[0])


def to_float(v: FloatValue) -> float:
    if v.fmt == "bf16":
        return struct.unpack(">f", struct.pack(">I", v.bits << 16))[0]
    flt, uint = STRUCT[v.fmt]
    return struct.unpack(flt, struct.pack(uint, v.bits))[0]


def f16_values() -> list[float]:
    """Every f16 by bit pattern, as Python floats (``to_float`` of each, in one struct call)."""
    return list(_F16_VALUES)


_F16_VALUES = struct.unpack(f">{1 << 16}e", struct.pack(f">{1 << 16}H", *range(1 << 16)))
