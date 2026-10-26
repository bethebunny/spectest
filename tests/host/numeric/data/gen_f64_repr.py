"""Writes f64_repr.txt: lines of `<bit pattern in decimal> <Python repr of that float>`.

Run from the repository root: `python tests/host/numeric/data/gen_f64_repr.py`.
The patterns are fixed: a seeded random sample plus the extremes and powers of ten.
"""

import random
import struct
from pathlib import Path

rng = random.Random(20240601)


def bits_of(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def value_of(bits: int) -> float:
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


patterns = {
    0,
    1,
    2,
    0x000FFFFFFFFFFFFF,
    0x0010000000000000,
    0x7FEFFFFFFFFFFFFF,
    0x3FF0000000000000,
    0x3FF0000000000001,
    0x3FEFFFFFFFFFFFFF,
}
for e in range(-330, 310):
    patterns.add(bits_of(float(f"1e{e}")))
for e in range(-20, 60):
    patterns.add(bits_of(2.0**e))
    patterns.add(bits_of(2.0**e) + 1)
    patterns.add(bits_of(2.0**e) - 1)
for _ in range(8000):
    patterns.add(rng.getrandbits(64) & 0x7FFFFFFFFFFFFFFF)
for _ in range(1000):
    patterns.add(bits_of(rng.uniform(-1000, 1000)) & 0x7FFFFFFFFFFFFFFF)
patterns |= {p | (1 << 63) for p in list(patterns)[:1500]}

lines = []
for p in sorted(patterns):
    x = value_of(p)
    if x != x or x in (float("inf"), float("-inf")):
        continue
    lines.append(f"{p} {x!r}")
Path(__file__).with_name("f64_repr.txt").write_text("\n".join(lines) + "\n")
print(len(lines), "lines")
