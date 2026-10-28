"""``_host.echo`` round-trips every wire kind through a Value."""

from __future__ import annotations

import gc
import math
import resource
import struct
import sys

import pytest

from spectest._host import echo, version
from spectest.driver.wire import Converted, Enum, Error, Float, Handle, Map, Record

F64_NAN_PAYLOAD = 0x7FF8_0000_0000_1234
FLOATS = {
    "f16": [0x0000, 0x8000, 0x3C00, 0x7C00, 0xFC00, 0x7E00, 0x7C01, 0xFE55],
    "bf16": [0x0000, 0x8000, 0x3F80, 0x7F80, 0xFF80, 0x7FC0, 0x7F81, 0xFFA5],
    "f32": [
        0,
        0x8000_0000,
        0x3F80_0000,
        0x7F80_0000,
        0xFF80_0000,
        0x7FC0_0000,
        0x7F80_0001,
    ],
    "f64": [
        0,
        1 << 63,
        0x3FF0 << 48,
        0x7FF0 << 48,
        0xFFF0 << 48,
        0x7FF8 << 48,
        F64_NAN_PAYLOAD,
    ],
}


def same(a: object, b: object) -> bool:
    return type(a) is type(b) and a == b


@pytest.mark.parametrize(
    "n", [0, -1, 1, 2**63 - 1, 2**63, -(2**63), -(2**63) - 1, 2**64, 2**200, -(2**200)]
)
def test_ints(n: int) -> None:
    assert same(echo(n), n)


@pytest.mark.parametrize("value", [True, False])
def test_bool_is_not_int(value: bool) -> None:
    assert echo(value) is value


@pytest.mark.parametrize(
    "fmt, bits", [(fmt, bits) for fmt, patterns in FLOATS.items() for bits in patterns]
)
def test_floats(fmt: str, bits: int) -> None:
    assert echo(Float(fmt, bits)) == Float(fmt, bits)


def test_float_values_are_untouched() -> None:
    assert struct.unpack("<d", FLOATS["f64"][1].to_bytes(8, "little"))[0] == -0.0
    assert math.isnan(struct.unpack("<d", F64_NAN_PAYLOAD.to_bytes(8, "little"))[0])


@pytest.mark.parametrize(
    "value",
    [
        [],
        (),
        [[]],
        ((), [()]),
        [1, (2, [3, ("x", b"y")])],
        [None, True, 0],
        None,
        "",
        "plain",
        "a\x00b",
        "café",
        "\U0001f600 outside the BMP \U00010348",
        b"",
        b"\x00",
        b"a\x00b\xff",
    ],
)
def test_plain(value: object) -> None:
    assert same(echo(value), value)


def test_map_with_list_keys() -> None:
    m = Map((([1, 2], "a"), ((), [3]), ("k", None)))
    assert echo(m) == m
    assert echo(Map(())) == Map(())


def test_map_duplicate_keys_are_refused() -> None:
    with pytest.raises(RuntimeError, match="duplicate"):
        echo(Map(((1, 2), (1, 3))))


def test_record() -> None:
    r = Record("pkg.Point", (("x", 1), ("y", [Float("f64", 0)])))
    assert echo(r) == r
    assert echo(Record("pkg.Empty", ())) == Record("pkg.Empty", ())


def test_enum() -> None:
    assert echo(Enum("pkg.Color", "RED")) == Enum("pkg.Color", "RED")
    assert echo(Enum("", "left")) == Enum("", "left")


def test_handle() -> None:
    h = Handle(2**64 - 1, "pkg.Thing")
    assert echo(h) == h


def test_error() -> None:
    e = Error("pkg.MyError", ("pkg.Base", "ValueError"), "msg é \x00 end")
    assert echo(e) == e
    assert echo(Error("spectest.ResolveError", (), "")) == Error(
        "spectest.ResolveError", (), ""
    )


def test_converted_reads_as_its_inner_value() -> None:
    assert echo(Converted("datetime.date", 738000)) == 738000
    assert echo(Converted("pkg.C", [Converted("pkg.D", "x")])) == ["x"]
    assert echo(Converted("pkg.C", None)) is None


@pytest.mark.parametrize(
    "value", [1.5, {}, {1}, object(), bytearray(b"a"), 1j, Float, ("a", 1.5), [{}]]
)
def test_non_wire_objects_are_type_errors(value: object) -> None:
    with pytest.raises(TypeError):
        echo(value)


def test_malformed_wire_objects_raise() -> None:
    with pytest.raises(RuntimeError, match="f128"):
        echo(Float("f128", 0))
    with pytest.raises(TypeError):
        echo(Record("a", ((1, 2),)))


def test_version() -> None:
    assert isinstance(version(), str)


def test_no_leaks() -> None:
    # Fresh (not interned) strings and ints: each is read through attribute lookups and
    # converted, so a reference the bridge forgets to drop shows in its refcount.
    sentinel = f"sentinel-{id(object())}"
    big = 10**30
    nested = [
        sentinel,
        big,
        [big, (sentinel, Float("f64", 5))],
        Record(sentinel, ((sentinel, big),)),
        Map((([sentinel], big),)),
        Enum(sentinel, sentinel),
        Handle(1, sentinel),
        Error(sentinel, (sentinel,), sentinel),
        Converted(sentinel, [big]),
        b"b",
    ]
    for _ in range(1000):
        echo(nested)
    gc.collect()
    counts = (sys.getrefcount(sentinel), sys.getrefcount(big))
    rss_before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    for _ in range(100_000):
        echo(nested)
    gc.collect()
    rss_after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    assert (sys.getrefcount(sentinel), sys.getrefcount(big)) == counts
    assert (rss_after - rss_before) / 1024 < 10  # ru_maxrss is in KiB on Linux


def test_errors_do_not_leak() -> None:
    sentinel = f"sentinel-{id(object())}"
    bad = [sentinel, (Record(sentinel, ((sentinel, 1.5),)),)]
    for _ in range(100):
        with pytest.raises(TypeError):
            echo(bad)
    before = sys.getrefcount(sentinel)
    for _ in range(10_000):
        with pytest.raises(TypeError):
            echo(bad)
    assert sys.getrefcount(sentinel) == before
