"""binary conformance: struct and the str/bytes codecs, int.to_bytes, numpy, and seeded bugs.

The conformances run as pytest items, one per clause. The plain test functions
at the end check the findings of examples/binary/FINDINGS.md without spectest.

Each seeded bug has its own conformance. A ``relates`` clause's planned calls go
to the same conformance's implementations (pack_i32.roundtrip calls unpack_i32,
the codecs' roundtrips call each other), so a correct partner is bound next to
each bug, and one bug never shows up in another's items.
"""

from __future__ import annotations

import random
import struct

import binary_impls as impls
import numpy as np
import pytest

import spectest

spec = spectest.load("binary.spec")

MAX_EXAMPLES = 500

test_struct = spectest.conformance(
    spec,
    impls={
        "pack_i32": impls.struct_pack_i32,
        "unpack_i32": impls.struct_unpack_i32,
        "utf8_encode": impls.utf8_encode,
        "utf8_decode": impls.utf8_decode,
    },
    errors={struct.error: "StructError", UnicodeDecodeError: "DecodeError"},
    max_examples=MAX_EXAMPLES,
)

test_int_bytes = spectest.conformance(
    spec,
    impls={"pack_i32": impls.int_pack_i32, "unpack_i32": impls.int_unpack_i32},
    errors={OverflowError: "StructError"},
    # FINDINGS.md, "int.from_bytes reads any length": the adapter never raises, so a
    # buffer that is not 4 bytes long returns instead of raising StructError (#1), its
    # value disagrees with le_uint(b) (value), and 5 or more bytes can give a value
    # outside i32 (#type). One cause, three clauses.
    expect_fail={"unpack_i32#1", "unpack_i32.value", "unpack_i32#type"},
    max_examples=MAX_EXAMPLES,
)

test_numpy = spectest.conformance(
    spec,
    impls={"pack_i32": impls.numpy_pack_i32, "unpack_i32": impls.numpy_unpack_i32},
    # numpy 2.x: OverflowError for an out-of-range Python int; frombuffer raises ValueError
    # for a buffer that is not a multiple of 4 bytes, and [0] raises IndexError on an
    # empty one. All three mean "not an i32 / not 4 bytes" here.
    errors={OverflowError: "StructError", ValueError: "StructError", IndexError: "StructError"},
    # FINDINGS.md, "numpy.frombuffer reads the first of several i32s": 8, 12 and 16 byte
    # buffers return their first element instead of raising (#1), and that element is not
    # le_uint(b) when the later bytes are not all zero (value).
    expect_fail={"unpack_i32#1", "unpack_i32.value"},
    max_examples=MAX_EXAMPLES,
)

test_seeded_wrapping_pack = spectest.conformance(
    spec,
    impls={"pack_i32": impls.wrapping_pack_i32, "unpack_i32": impls.struct_unpack_i32},
    errors={struct.error: "StructError"},
    expect_fail={
        # The seeded bug: out-of-range x packs its low 32 bits instead of raising.
        "pack_i32#1",
        # The wrapped bytes unpack to wrap<i32>(x), not x.
        "pack_i32.roundtrip",
    },
    max_examples=MAX_EXAMPLES,
)

test_seeded_replacing_decode = spectest.conformance(
    spec,
    impls={"utf8_encode": impls.utf8_encode, "utf8_decode": impls.replacing_utf8_decode},
    errors={UnicodeDecodeError: "DecodeError"},
    expect_fail={
        # The seeded bug: malformed input returns U+FFFD instead of raising.
        "utf8_decode#1",
        # U+FFFD encodes as EF BF BD, not as the malformed bytes it replaced.
        "utf8_decode.roundtrip",
    },
    max_examples=MAX_EXAMPLES,
)

test_seeded_utf16_encode = spectest.conformance(
    spec,
    impls={"utf8_encode": impls.utf16_encode, "utf8_decode": impls.utf8_decode},
    errors={UnicodeDecodeError: "DecodeError"},
    expect_fail={
        # The seeded bug, caught three times: U+0080 and above give bytes that are not
        # UTF-8 (valid); an ASCII character or one from U+0800 to U+FFFF takes another
        # number of bytes than in UTF-8 (length: 2 bytes for "0", where UTF-8 takes 1); and
        # a non-empty ASCII string decodes back with a NUL after each character (roundtrip).
        "utf8_encode.valid",
        "utf8_encode.length",
        "utf8_encode.roundtrip",
        # utf8_decode's roundtrip calls the buggy utf8_encode: the pair breaks the relation,
        # and the item is utf8_decode's.
        "utf8_decode.roundtrip",
    },
    max_examples=MAX_EXAMPLES,
)


# ---------------------------------------------------------------------------
# The findings, checked without spectest

I32_MIN, I32_MAX = -(2**31), 2**31 - 1
BOUNDARIES = (0, 1, -1, 127, 128, -128, 255, 256, I32_MIN, I32_MIN + 1, I32_MAX - 1, I32_MAX)


def le_uint(b: bytes) -> int:
    return sum(byte << (8 * i) for i, byte in enumerate(b))


def wrap_u32(n: int) -> int:
    return n % 2**32


def four_byte_samples() -> list[bytes]:
    rng = random.Random(0)
    fixed = [struct.pack("<i", x) for x in BOUNDARIES]
    return fixed + [rng.randbytes(4) for _ in range(2000)]


def test_struct_rejects_every_length_but_four() -> None:
    for n in (0, 1, 2, 3, 5, 7, 8, 12, 16):
        with pytest.raises(struct.error, match="requires a buffer of 4 bytes"):
            struct.unpack("<i", bytes(n))
    for x in (I32_MAX + 1, I32_MIN - 1, 2**63 - 1, -(2**63)):
        with pytest.raises(struct.error):
            struct.pack("<i", x)


def test_int_from_bytes_reads_any_length() -> None:
    """Finding 1: the counterexamples of unpack_i32#1, unpack_i32.value and unpack_i32#type."""
    assert impls.int_unpack_i32(b"") == 0
    assert impls.int_unpack_i32(b"\x80") == -128
    assert wrap_u32(-128) == 4294967168 != le_uint(b"\x80") == 128
    assert impls.int_unpack_i32(b"\x00\x00\x00\x00\x01") == 2**32 > I32_MAX
    for b in four_byte_samples():
        assert impls.int_unpack_i32(b) == struct.unpack("<i", b)[0]


def test_int_to_bytes_raises_overflow_error_out_of_range() -> None:
    for x in (I32_MAX + 1, I32_MIN - 1, 2**63 - 1, -(2**63)):
        with pytest.raises(OverflowError, match="int too big to convert"):
            impls.int_pack_i32(x)
    for x in BOUNDARIES:
        assert impls.int_pack_i32(x) == struct.pack("<i", x)


def test_numpy_array_raises_overflow_error_out_of_range() -> None:
    for x in (I32_MAX + 1, I32_MIN - 1, 2**63 - 1, -(2**63)):
        with pytest.raises(OverflowError, match=f"Python integer {x} out of bounds for int32"):
            impls.numpy_pack_i32(x)
    for x in BOUNDARIES:
        assert impls.numpy_pack_i32(x) == struct.pack("<i", x)


def test_numpy_frombuffer_by_length() -> None:
    """Finding 2: what frombuffer(b, "<i4")[0] does for each length up to 16."""
    rng = random.Random(1)
    for n in range(17):
        b = rng.randbytes(n)
        if n == 0:
            with pytest.raises(IndexError, match="index 0 is out of bounds for axis 0 with size 0"):
                impls.numpy_unpack_i32(b)
        elif n % 4:
            with pytest.raises(ValueError, match="buffer size must be a multiple of element size"):
                impls.numpy_unpack_i32(b)
        else:
            got = impls.numpy_unpack_i32(b)
            assert isinstance(got, np.int32)
            assert got == struct.unpack("<i", b[:4])[0]
    for b in four_byte_samples():
        assert impls.numpy_unpack_i32(b) == struct.unpack("<i", b)[0]


def test_numpy_unpack_counterexamples() -> None:
    """Finding 2: the counterexamples of unpack_i32#1 and unpack_i32.value (seed 0), and
    those of earlier runs, which shrinking left longer or less simple."""
    assert impls.numpy_unpack_i32(bytes(8)) == 0
    b = bytes(7) + b"\x01"
    assert impls.numpy_unpack_i32(b) == 0 and le_uint(b) == 2**56
    assert impls.numpy_unpack_i32(bytes(16)) == 0
    b = b"\xf0\x90\x80\x80\xf0\x90\x80\x80"
    got = int(impls.numpy_unpack_i32(b))
    assert got == -2139057936
    assert wrap_u32(got) == 2155909360 != le_uint(b) == 9259560196496199920
    b = bytes(4) + b"\x01" + bytes(3)
    assert impls.numpy_unpack_i32(b) == 0 and le_uint(b) == 2**32


def test_wrapping_pack_counterexamples() -> None:
    """Seeded bug 1: both boundaries wrap, and the bytes unpack to another integer."""
    assert impls.wrapping_pack_i32(I32_MIN - 1) == b"\xff\xff\xff\x7f"
    assert struct.unpack("<i", b"\xff\xff\xff\x7f")[0] == I32_MAX
    assert impls.wrapping_pack_i32(I32_MAX + 1) == b"\x00\x00\x00\x80"
    assert struct.unpack("<i", b"\x00\x00\x00\x80")[0] == I32_MIN
    with pytest.raises(struct.error):
        struct.pack("<i", I32_MIN - 1)
    for x in BOUNDARIES:
        assert impls.wrapping_pack_i32(x) == struct.pack("<i", x)
    for x in (I32_MIN - 1, I32_MAX + 1, 2**63 - 1, -(2**63)):
        packed = impls.wrapping_pack_i32(x)
        assert len(packed) == 4 and le_uint(packed) == wrap_u32(x)


def test_replacing_decode_counterexamples() -> None:
    """Seeded bug 2: b"\\x80" decodes to U+FFFD, which encodes to EF BF BD."""
    assert impls.replacing_utf8_decode(b"\x80") == "\ufffd"
    assert "\ufffd".encode() == b"\xef\xbf\xbd"
    with pytest.raises(UnicodeDecodeError):
        b"\x80".decode("utf-8")
    for s in ("", "0", "\u00e9", "\u20ac", "\U0001f600", "a\x00b"):
        b = s.encode("utf-8")
        assert impls.replacing_utf8_decode(b) == impls.utf8_decode(b) == s


def utf8_length(s: str) -> int:
    """utf8_encode.length's bound: 1, 2, 3 or 4 bytes per code point."""
    return sum(1 if c < 0x80 else 2 if c < 0x800 else 3 if c < 0x10000 else 4 for c in map(ord, s))


def test_utf8_length_is_the_encoded_length() -> None:
    for cp in (*range(0, 0xD800, 3), *range(0xE000, 0x110000, 7), 0x7F, 0x80, 0x7FF, 0x800):
        s = chr(cp) * 2
        assert utf8_length(s) == len(impls.utf8_encode(s)), hex(cp)


def test_utf16_encode_counterexamples() -> None:
    """Seeded bug 3: what valid, roundtrip and length see."""
    assert impls.utf16_encode("\x80") == b"\x80\x00"
    with pytest.raises(UnicodeDecodeError):
        b"\x80\x00".decode("utf-8")
    assert impls.utf16_encode("0") == b"0\x00"
    assert b"0\x00".decode("utf-8") == "0\x00"
    assert impls.utf16_encode(b"\x00".decode("utf-8")) == b"\x00\x00"
    for s in (
        "",
        "0",
        "\x7f",
        "\x80",
        "\u00e9",
        "\u07ff",
        "\u0800",
        "\u20ac",
        "\uffff",
        "\U00010000",
    ):
        n = len(impls.utf16_encode(s))
        assert len(s) <= 2 * len(s) <= n <= 4 * len(s)
        assert (n == utf8_length(s)) == (s in ("", "\x80", "\u00e9", "\u07ff", "\U00010000"))


# ---------------------------------------------------------------------------
# CPython's UTF-8 decoder against the Unicode standard
#
# spectest's valid_utf8 is CPython's strict decoder, so for test_struct the spec's
# oracle and the implementation are the same code. This checks that code against
# Unicode Table 3-7 ("Well-Formed UTF-8 Byte Sequences"), written out independently.

TRAIL = (0x80, 0xBF)
TABLE_3_7: dict[int, tuple[tuple[int, int], ...]] = {
    **{c: (TRAIL,) for c in range(0xC2, 0xE0)},
    0xE0: ((0xA0, 0xBF), TRAIL),
    **{c: (TRAIL, TRAIL) for c in (*range(0xE1, 0xED), 0xEE, 0xEF)},
    0xED: ((0x80, 0x9F), TRAIL),
    0xF0: ((0x90, 0xBF), TRAIL, TRAIL),
    **{c: (TRAIL, TRAIL, TRAIL) for c in range(0xF1, 0xF4)},
    0xF4: ((0x80, 0x8F), TRAIL, TRAIL),
}


def well_formed_utf8(b: bytes) -> bool:
    i = 0
    while i < len(b):
        lead = b[i]
        if lead < 0x80:
            i += 1
            continue
        trail = TABLE_3_7.get(lead)
        if trail is None or i + len(trail) >= len(b):
            return False
        for k, (lo, hi) in enumerate(trail, start=1):
            if not lo <= b[i + k] <= hi:
                return False
        i += 1 + len(trail)
    return True


def strict_decodes(b: bytes) -> bool:
    try:
        b.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def test_python_utf8_decoder_accepts_exactly_table_3_7() -> None:
    edges = (0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF)
    cases: list[bytes] = [b""]
    cases += [bytes([a]) for a in range(256)]
    cases += [bytes([a, b]) for a in range(256) for b in range(256)]
    cases += [bytes([a, b, c]) for a in range(0xC0, 0x100) for b in range(256) for c in edges]
    cases += [
        bytes([a, b, c, d])
        for a in range(0xE0, 0x100)
        for b in range(256)
        for c in edges
        for d in edges
        if a >= 0xF0 or d == 0x80
    ]
    rng = random.Random(2)
    cases += [rng.randbytes(rng.randrange(1, 17)) for _ in range(20_000)]
    accepted = 0
    for b in cases:
        ok = well_formed_utf8(b)
        assert strict_decodes(b) == ok, b
        if ok:
            accepted += 1
            assert b.decode("utf-8").encode("utf-8") == b
    assert accepted > 10_000


def test_table_3_7_is_written_out_correctly() -> None:
    for cp in (*range(0, 0xD800, 7), *range(0xE000, 0x110000, 13), 0xD7FF, 0xE000, 0x10FFFF):
        assert well_formed_utf8(chr(cp).encode("utf-8")), hex(cp)
    for bad in (
        b"\xc0\x80",
        b"\xc1\xbf",
        b"\xe0\x9f\xbf",
        b"\xed\xa0\x80",
        b"\xf0\x8f\xbf\xbf",
        b"\xf4\x90\x80\x80",
        b"\xf5\x80\x80\x80",
        b"\x80",
        b"\xe2\x82",
        b"\xff",
    ):
        assert not well_formed_utf8(bad), bad
