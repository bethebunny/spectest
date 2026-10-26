"""Implementations of binary.spec: adapters over struct, int.to_bytes / int.from_bytes and
numpy, and three seeded bugs.

Each adapter is the one-line idiom a Python programmer would write; the spec
judges what that idiom does at the edges (out-of-range integers, buffers of the
wrong length, malformed UTF-8).
"""

from __future__ import annotations

import struct

import numpy as np

# ---------------------------------------------------------------------------
# struct and the str / bytes codecs


def struct_pack_i32(x: int) -> bytes:
    return struct.pack("<i", x)


def struct_unpack_i32(b: bytes) -> int:
    return struct.unpack("<i", b)[0]


def utf8_encode(s: str) -> bytes:
    return s.encode("utf-8")


def utf8_decode(b: bytes) -> str:
    return b.decode("utf-8")


# ---------------------------------------------------------------------------
# int.to_bytes / int.from_bytes


def int_pack_i32(x: int) -> bytes:
    return x.to_bytes(4, "little", signed=True)


def int_unpack_i32(b: bytes) -> int:
    return int.from_bytes(b, "little", signed=True)


# ---------------------------------------------------------------------------
# numpy


def numpy_pack_i32(x: int) -> bytes:
    return np.array([x], dtype="<i4").tobytes()


def numpy_unpack_i32(b: bytes) -> np.int32:
    return np.frombuffer(b, dtype="<i4")[0]


# ---------------------------------------------------------------------------
# Seeded bugs


def wrapping_pack_i32(x: int) -> bytes:
    """Packs the low 32 bits: out-of-range integers wrap silently instead of raising."""
    return (x & 0xFFFFFFFF).to_bytes(4, "little")


def replacing_utf8_decode(b: bytes) -> str:
    """Decodes leniently: malformed sequences become U+FFFD instead of raising."""
    return b.decode("utf-8", errors="replace")


def utf16_encode(s: str) -> bytes:
    """Encodes with the wrong codec: UTF-16-LE instead of UTF-8."""
    return s.encode("utf-16-le")


# ---------------------------------------------------------------------------
# For explore_binary.py: a bug that only one input reveals


def off_by_one_pack_i32(x: int) -> bytes:
    """Checks the range with <= 2**31, so x = 2**31 packs as i32.min instead of raising."""
    if not -(2**31) <= x <= 2**31:
        raise struct.error(f"{x} is out of range for i32")
    return (x & 0xFFFFFFFF).to_bytes(4, "little")
