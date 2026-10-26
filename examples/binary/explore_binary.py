"""How well generation reaches binary.spec's partitions: measured on the generator itself.

Run it explicitly (it does not match test_*.py), with -s to see the tables:
    uv run pytest examples/binary/explore_binary.py -s
Each test draws arguments the way a spectest item does (spectest.generate.args_strategy
inside a seeded Hypothesis run, generate phase only) and prints what share of draws
falls in each partition class and in a few finer classes the partitions do not name.
The assertions record the measured shape loosely, so a change in the generator that
moves a share a lot shows up here.
"""

from __future__ import annotations

import struct
from collections import Counter
from collections.abc import Callable
from typing import Any

import binary_impls as impls
from hypothesis import HealthCheck, Phase, given, seed, settings

import spectest
from spectest import generate

spec = spectest.load("binary.spec")

# Does spectest find a range check that is off by one? Only x = 2**31 reveals it
# (pack_i32#1 and pack_i32.roundtrip fail there). Measured: found with seeds 0 to 19,
# every time, within 2 to 14 examples, and always shown as x = 2147483648.
test_explore_off_by_one_pack = spectest.conformance(
    spec,
    impls={"pack_i32": impls.off_by_one_pack_i32, "unpack_i32": impls.struct_unpack_i32},
    errors={struct.error: "StructError"},
    max_examples=500,
)

DRAWS = 2000
I32_MIN, I32_MAX = -(2**31), 2**31 - 1


def draws(fn: str, n: int = DRAWS, run_seed: int = 0) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    @seed(run_seed)
    @settings(
        max_examples=n,
        database=None,
        phases=[Phase.generate],
        suppress_health_check=list(HealthCheck),
    )
    @given(generate.args_strategy(fn, spec))
    def collect(args: dict[str, Any]) -> None:
        out.append(args)

    collect()
    return out


def shares(values: list[Any], classes: dict[str, Callable[[Any], bool]]) -> dict[str, float]:
    table = {
        name: sum(1 for v in values if test(v)) / len(values) for name, test in classes.items()
    }
    print(f"\n{len(values)} draws")
    for name, share in table.items():
        print(f"  {name:<42} {share:6.1%}")
    return table


def valid_utf8(b: bytes) -> bool:
    try:
        b.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def test_pack_i32_reaches_all_three_classes_and_both_boundaries() -> None:
    xs = [a["x"] for a in draws("pack_i32")]
    t = shares(
        xs,
        {
            "in_range": lambda x: I32_MIN <= x <= I32_MAX,
            "too_small": lambda x: x < I32_MIN,
            "too_large": lambda x: x > I32_MAX,
            "x == i32.min - 1 or x == i32.max + 1": lambda x: x in (I32_MIN - 1, I32_MAX + 1),
            "x == i32.min or x == i32.max": lambda x: x in (I32_MIN, I32_MAX),
            "|x| <= 255": lambda x: abs(x) <= 255,
        },
    )
    assert min(t["in_range"], t["too_small"], t["too_large"]) > 0.25


def test_pack_i32_draws_the_out_of_range_boundaries_early() -> None:
    """Uniform draws rarely hit i32.max + 1 or i32.min - 1, but each run tries them early."""
    first: dict[int, tuple[int | None, int | None]] = {}
    for run_seed in range(10):
        xs = [a["x"] for a in draws("pack_i32", 100, run_seed)]
        at = {v: (xs.index(v) + 1 if v in xs else None) for v in (I32_MAX + 1, I32_MIN - 1)}
        first[run_seed] = (at[I32_MAX + 1], at[I32_MIN - 1])
    print("\nfirst draw of (i32.max + 1, i32.min - 1) per seed, in 100 draws:")
    for run_seed, pair in first.items():
        print(f"  seed {run_seed}: {pair}")
    assert all(at is not None and at <= 20 for pair in first.values() for at in pair)


def test_unpack_i32_draws_four_bytes_a_fair_share() -> None:
    """The predicate partition steers generation: a class (or no class) is drawn first,
    and len(b) == 4 draws four bytes, so four gets about a third of the draws."""
    bs = [a["b"] for a in draws("unpack_i32")]
    lengths = Counter(len(b) for b in bs)
    print("\nlengths:", dict(sorted(lengths.items())))
    t = shares(
        bs,
        {
            "four (len(b) == 4)": lambda b: len(b) == 4,
            "other": lambda b: len(b) != 4,
            "len(b) in {8, 12, 16}": lambda b: len(b) in (8, 12, 16),
            "len(b) == 0": lambda b: len(b) == 0,
        },
    )
    assert t["four (len(b) == 4)"] > 0.3
    assert t["len(b) in {8, 12, 16}"] > 0.02


def test_utf8_decode_reaches_valid_multibyte_text() -> None:
    bs = [a["b"] for a in draws("utf8_decode")]
    t = shares(
        bs,
        {
            "valid": valid_utf8,
            "invalid": lambda b: not valid_utf8(b),
            "valid, empty": lambda b: b == b"",
            "valid, ASCII only, non-empty": lambda b: b != b"" and max(b) < 0x80,
            "valid, with a multi-byte sequence": lambda b: (
                valid_utf8(b) and any(c >= 0x80 for c in b)
            ),
            "valid, with a 4-byte sequence": lambda b: valid_utf8(b) and any(c >= 0xF0 for c in b),
        },
    )
    assert 0.25 < t["valid"] < 0.6
    assert t["valid, with a multi-byte sequence"] > 0.15


def test_utf8_encode_draws_every_utf8_width() -> None:
    ss = [a["s"] for a in draws("utf8_encode")]
    t = shares(
        ss,
        {
            "empty": lambda s: s == "",
            "has U+0080..U+07FF (2 bytes)": lambda s: any(0x80 <= ord(c) < 0x800 for c in s),
            "has U+0800..U+FFFF (3 bytes)": lambda s: any(0x800 <= ord(c) < 0x10000 for c in s),
            "has U+10000.. (4 bytes)": lambda s: any(ord(c) >= 0x10000 for c in s),
            "ASCII only, non-empty": lambda s: s != "" and all(ord(c) < 0x80 for c in s),
        },
    )
    assert min(t["has U+0080..U+07FF (2 bytes)"], t["has U+10000.. (4 bytes)"]) > 0.05
