"""Collections, options, text, identity and structural equality."""

from __future__ import annotations

import itertools
import math
import random
import struct
from collections import Counter
from collections.abc import Iterator
from fractions import Fraction
from typing import Any

import pytest
from budget import full
from hypothesis import given
from hypothesis import strategies as st

from spectest.prelude import collections as c
from spectest.prelude import floats
from spectest.values import (
    NEG_INF,
    POS_INF,
    EvalError,
    FloatValue,
    Handle,
    MapValue,
    RecordValue,
    Some,
)


def f64(x: float) -> FloatValue:
    return FloatValue("f64", struct.unpack("<Q", struct.pack("<d", x))[0])


PZ, NZ = f64(0.0), f64(-0.0)
NAN = f64(math.nan)
NAN2 = FloatValue("f64", NAN.bits | 1)
NAN32 = FloatValue("f32", 0x7FC00000)


class FakeCtx:
    """An evaluation context with model fields and identity queries."""

    def __init__(self, fields: dict[int, dict[str, Any]] | None = None) -> None:
        self._fields = fields or {}
        self.fresh_ids: set[int] = set()
        self.shared: set[frozenset[int]] = set()

    def fields(self, h: Handle) -> dict[str, Any]:
        return self._fields[h.id]

    def is_fresh(self, h: Handle) -> bool:
        return h.id in self.fresh_ids

    def same_object(self, a: Handle, b: Handle) -> bool:
        return a.obj is b.obj

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        return frozenset((a.id, b.id)) in self.shared


# ---------------------------------------------------------------------------
# len, keys, values, range


def test_len() -> None:
    assert c.len((1, 2, 3)) == 3
    assert c.len(()) == 0
    assert c.len("héllo") == 5
    assert c.len("\U0001f600") == 1
    assert c.len(b"\x00\x01") == 2
    assert c.len(MapValue((("a", 1), ("b", 2)))) == 2
    with pytest.raises(EvalError, match="len: expected a collection"):
        c.len(3)


def test_keys_values() -> None:
    m = MapValue((("b", 1), ("a", 2)))
    assert c.keys(m) == ("b", "a")
    assert c.values(m) == (1, 2)
    assert c.keys(MapValue(())) == ()
    with pytest.raises(EvalError, match="keys: expected a map"):
        c.keys((1, 2))


def test_range() -> None:
    assert c.range(0, 3) == (0, 1, 2)
    assert c.range(3, 0) == ()
    assert c.range(-2, 1) == (-2, -1, 0)
    with pytest.raises(EvalError, match="range: expected integers"):
        c.range(0, Fraction(1, 2))
    with pytest.raises(EvalError, match="more than"):
        c.range(0, 10**12)


# ---------------------------------------------------------------------------
# Orderings


def test_sorted_values() -> None:
    assert c.sorted((3, 1, 2)) == (1, 2, 3)
    assert c.sorted(()) == ()
    assert c.sorted(("b", "a", "B")) == ("B", "a", "b")
    assert c.sorted((b"\xff", b"\x00", b"")) == (b"", b"\x00", b"\xff")
    assert c.sorted((True, False, True)) == (False, True, True)
    assert c.sorted(((1, "b"), (1, "a"), (0, "z"))) == ((0, "z"), (1, "a"), (1, "b"))
    assert c.sorted(((1, 2), (1,), ())) == ((), (1,), (1, 2))
    assert c.sorted((POS_INF, Fraction(1, 2), -3, NEG_INF)) == (NEG_INF, -3, Fraction(1, 2), POS_INF)


@pytest.mark.parametrize(
    "xs",
    [
        (PZ, NZ),
        (PZ,),
        ((1, PZ), (0, PZ)),
        (Some(1), None),
        (RecordValue("R", (("a", 1),)),),
        (1, "a"),
        (True, 1),
    ],
)
def test_unordered_values_raise(xs: tuple[Any, ...]) -> None:
    with pytest.raises(EvalError, match="sorted"):
        c.sorted(xs)
    with pytest.raises(EvalError, match="is_sorted"):
        c.is_sorted(xs)


def test_compare_values() -> None:
    assert c.compare_values(1, 2) == -1
    assert c.compare_values(False, True, "<") == -1
    assert c.compare_values("b", "a") == 1
    assert c.compare_values((1, "a"), (1, "a")) == 0
    assert c.compare_values(f64(-1.0), -1, "<=", promote=True) == 0
    assert c.compare_values(2, f64(1.5), "<", promote=True) == 1
    with pytest.raises(EvalError, match="<: floats have no total order"):
        c.compare_values(f64(1.0), 2, "<")
    with pytest.raises(EvalError, match="<: cannot promote NaN"):
        c.compare_values(NAN, 2, "<", promote=True)
    with pytest.raises(EvalError, match="floats have no total order"):
        c.compare_values((PZ,), (NZ,), "<", promote=True)
    with pytest.raises(EvalError, match="are not ordered"):
        c.compare_values(Some(1), Some(2), "<")


def test_ord_is_the_documented_order() -> None:
    # docs/language.md, Types and values: strings by code point, which is UTF-8 byte order
    # and not the UTF-16 code-unit order (U+10000 is D800 DC00 in UTF-16, below U+E000).
    assert c.sorted(("\U00010000", "\ue000", "\x7f", "\x80")) == (
        "\x7f", "\x80", "\ue000", "\U00010000",
    )  # fmt: skip
    assert c.compare_values("\U00010000", "\uffff") == 1
    # bytes by unsigned byte value, tuples and lists lexicographically (a prefix first),
    # false < true
    assert c.sorted((b"\x80", b"\x7f", b"\x7f\x00")) == (b"\x7f", b"\x7f\x00", b"\x80")
    assert c.sorted(((2, "a"), (1, "b"), (1, "a"))) == ((1, "a"), (1, "b"), (2, "a"))
    assert c.sorted(([1, 2], [1], [0, 9])) == ([0, 9], [1], [1, 2])
    assert c.sorted((True, False)) == (False, True)


SCALARS = st.text(alphabet=st.characters(codec="utf-8"))


@given(SCALARS, SCALARS)
def test_string_order_is_code_point_and_utf8_byte_order(a: str, b: str) -> None:
    def cmp(x: Any, y: Any) -> int:
        return (x > y) - (x < y)

    order = c.compare_values(a, b)
    assert order == cmp(c.codepoints(a), c.codepoints(b))
    assert order == cmp(a.encode("utf-8"), b.encode("utf-8"))


def test_sorted_does_not_use_pythons_sort(monkeypatch: pytest.MonkeyPatch) -> None:
    # The prelude's sorted may judge Python's own sort, so it must not be that sort.
    import builtins

    def refuse(*args: Any, **kwargs: Any) -> Any:
        raise AssertionError("the prelude called builtins.sorted")

    monkeypatch.setattr(builtins, "sorted", refuse)
    assert c.sorted((3, 1, 2, 1)) == (1, 1, 2, 3)
    assert c.sorted((("b", 1), ("a", 2))) == (("a", 2), ("b", 1))


@given(st.lists(st.tuples(st.integers(0, 3), st.integers())))
def test_sorted_is_stable_and_agrees_with_python(xs: list[tuple[int, int]]) -> None:
    keys = tuple(k for k, _ in xs)
    assert c.sorted(keys) == tuple(sorted(keys))
    assert c.sorted(tuple(xs)) == tuple(sorted(xs))
    assert c.sorted(tuple(map(str, keys))) == tuple(sorted(map(str, keys)))


def test_lists_and_tuples_are_interchangeable() -> None:
    assert c.same([1, PZ], (1, PZ))
    assert c.eq([1, [2]], (1, (2,)))
    assert c.is_permutation([1, 2], (2, 1))


def test_is_sorted() -> None:
    assert c.is_sorted(())
    assert c.is_sorted((5,))
    assert c.is_sorted((1, 1, 2))
    assert not c.is_sorted((2, 1))
    assert c.is_sorted(("a", "ab", "b"))
    assert not c.is_sorted(((1, 2), (1, 1)))
    assert c.is_sorted((NEG_INF, 0, POS_INF))


@given(st.lists(st.integers() | st.fractions()))
def test_sorted_numbers(xs: list[Any]) -> None:
    out = c.sorted(tuple(xs))
    assert out == tuple(sorted(xs))
    assert c.is_sorted(out)
    assert c.is_permutation(out, tuple(xs))


@given(st.lists(st.tuples(st.integers(-3, 3), st.text(max_size=2))))
def test_sorted_tuples(xs: list[tuple[int, str]]) -> None:
    assert c.sorted(tuple(xs)) == tuple(sorted(xs))
    assert c.is_sorted(tuple(xs)) == (xs == sorted(xs))


# ---------------------------------------------------------------------------
# Element equality is `same`


def test_is_permutation() -> None:
    assert c.is_permutation((1, 2, 2), (2, 1, 2))
    assert not c.is_permutation((1, 2), (1, 2, 2))
    assert not c.is_permutation((1, 1, 2), (1, 2, 2))
    assert c.is_permutation((), ())
    assert not c.is_permutation((PZ,), (NZ,))
    assert c.is_permutation((NAN, PZ), (PZ, FloatValue("f64", NAN.bits)))
    assert not c.is_permutation((NAN,), (NAN2,))
    assert c.is_permutation(((1, PZ), Some("x"), None), (None, Some("x"), (1, PZ)))
    h1, h2 = Handle(object(), "M"), Handle(object(), "M")
    assert c.is_permutation((h1, h2), (h2, h1))
    assert not c.is_permutation((h1, h1), (h1, h2))
    assert not c.is_permutation((1,), (True,))
    assert c.is_permutation((1,), (Fraction(1),))


@given(st.lists(st.integers(0, 5)), st.data())
def test_is_permutation_of_shuffles(xs: list[int], data: st.DataObject) -> None:
    ys = data.draw(st.permutations(xs))
    assert c.is_permutation(tuple(xs), tuple(ys))
    zs = data.draw(st.lists(st.integers(0, 5)))
    assert c.is_permutation(tuple(xs), tuple(zs)) == (Counter(xs) == Counter(zs))


def test_is_subsequence() -> None:
    assert c.is_subsequence((), (1, 2))
    assert c.is_subsequence((), ())
    assert c.is_subsequence((1, 3), (1, 2, 3))
    assert not c.is_subsequence((3, 1), (1, 2, 3))
    assert not c.is_subsequence((1, 1), (1, 2))
    assert c.is_subsequence((1, 1), (1, 2, 1))
    assert not c.is_subsequence((1,), ())
    assert not c.is_subsequence((NZ,), (PZ,))


@given(st.lists(st.integers(0, 3)), st.data())
def test_is_subsequence_of_selection(xs: list[int], data: st.DataObject) -> None:
    keep = data.draw(st.lists(st.booleans(), min_size=len(xs), max_size=len(xs)))
    sub = tuple(x for x, k in zip(xs, keep) if k)
    assert c.is_subsequence(sub, tuple(xs))


def test_distinct() -> None:
    assert c.distinct(())
    assert c.distinct((1, 2, 3))
    assert not c.distinct((1, 2, 1))
    assert c.distinct((PZ, NZ))
    assert not c.distinct((NAN, FloatValue("f64", NAN.bits)))
    assert c.distinct((NAN, NAN2))
    assert not c.distinct((1, Fraction(1)))
    assert c.distinct(("a", b"a"))
    assert not c.distinct(((1, "a"), (1, "a")))


def test_index_of() -> None:
    assert c.index_of(("a", "b", "a"), "a") == 0
    assert c.index_of(("a", "b", "a"), "b") == 1
    assert c.index_of((PZ, NZ), NZ) == 1
    with pytest.raises(EvalError, match="index_of: 'z' is not in the list"):
        c.index_of(("a",), "z")


# ---------------------------------------------------------------------------
# Options and text


def test_options() -> None:
    assert c.some(3) == Some(3)
    assert c.is_some(Some(None)) and not c.is_some(None)
    assert c.is_none(None) and not c.is_none(Some(0))
    assert c.unwrap(Some(PZ)) is PZ
    with pytest.raises(EvalError, match="unwrap: the option is none"):
        c.unwrap(None)
    with pytest.raises(EvalError, match="is_some: expected an option"):
        c.is_some(3)


@pytest.mark.parametrize(
    ("b", "ok"),
    [
        (b"", True),
        (b"abc", True),
        ("é€\U0001f600".encode(), True),
        (b"\xc3", False),
        (b"\xc0\xaf", False),
        (b"\xe0\x80\xaf", False),
        (b"\xed\xa0\x80", False),
        (b"\xf4\x90\x80\x80", False),
        (b"\xff", False),
        (b"\x80", False),
    ],
)
def test_valid_utf8(b: bytes, ok: bool) -> None:
    assert c.valid_utf8(b) == ok


@given(st.text(alphabet=st.characters(exclude_categories=("Cs",))))
def test_encoded_text_is_valid_utf8(s: str) -> None:
    assert c.valid_utf8(s.encode("utf-8"))


def test_valid_utf8_rejects_non_bytes() -> None:
    with pytest.raises(EvalError, match="valid_utf8: expected bytes"):
        c.valid_utf8("abc")


def strict_decodes(b: bytes) -> bool:
    """CPython's strict UTF-8 decoder, the codec valid_utf8 must not depend on."""
    try:
        b.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return False
    return True


def test_valid_utf8_does_not_decode() -> None:
    # valid_utf8 judges UTF-8 codecs, so it must not be one: it reads the bytes itself.
    class NoDecode(bytes):
        def decode(self, *args: Any, **kwargs: Any) -> str:
            raise AssertionError("valid_utf8 called bytes.decode")

    assert c.valid_utf8(NoDecode("é€\U0001f600".encode()))
    assert not c.valid_utf8(NoDecode(b"\xed\xa0\x80"))


FIRST_BYTES = [range(lo, lo + 32) for lo in range(0, 256, 32)]


def short_strings(firsts: range) -> Iterator[bytes]:
    """The byte strings of 1 to 3 bytes whose first byte is in ``firsts``, and the empty
    string with the first part: the eight parts hold the 16,843,009 strings of 0 to 3
    bytes. The dev loop takes the strings of 1 or 2 bytes, the 3-byte strings of boundary
    bytes, and a seeded sample of the 3-byte strings that start like a multi-byte form."""
    if firsts.start == 0:
        yield b""
    yield from (bytes([a]) for a in firsts)
    yield from map(bytes, itertools.product(firsts, range(256)))
    if full():
        yield from map(bytes, itertools.product(firsts, range(256), range(256)))
        return
    edges = (0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0)
    edges += (0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF)
    yield from (bytes(p) for p in itertools.product(edges, repeat=3) if p[0] in firsts)
    leads = range(max(firsts.start, 0xC0), firsts.stop)
    rng = random.Random(firsts.start)
    for _ in range(10_000 if leads else 0):
        yield bytes([rng.choice(leads), rng.randrange(256), rng.randrange(256)])


@pytest.mark.parametrize("firsts", FIRST_BYTES, ids=lambda r: f"{r.start:02x}-{r.stop - 1:02x}")
def test_valid_utf8_agrees_with_the_strict_decoder_on_every_short_string(firsts: range) -> None:
    mismatches = [b for b in short_strings(firsts) if c.valid_utf8(b) != strict_decodes(b)]
    assert mismatches == []


@pytest.mark.slow
def test_valid_utf8_agrees_with_the_strict_decoder_on_longer_strings() -> None:
    # Four-byte strings: every lead byte of a 3- or 4-byte form (and past them) with every
    # second byte (edge values only, in the dev loop) and edge values for the others (each
    # boundary of Table 3-7), then random strings and damaged encodings.
    edges = (0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xF0, 0xF4, 0xFF)
    seconds = range(256) if full() else edges
    cases = [bytes(p) for p in itertools.product(range(0xE0, 0x100), seconds, edges, edges)]
    rng = random.Random(0)
    scalars = ((0, 0x80), (0x80, 0x800), (0x800, 0xD800), (0xE000, 0x10000), (0x10000, 0x110000))
    for _ in range(20_000):
        cases.append(rng.randbytes(rng.randrange(4, 33)))
        good = "".join(chr(rng.randrange(*rng.choice(scalars))) for _ in range(4)).encode()
        cases.append(good)
        cut = rng.randrange(len(good))
        cases.append(good[:cut])
        cases.append(good[:cut] + bytes([rng.randrange(256)]) + good[cut + 1 :])
    for cp in (0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF):
        cases.append(chr(cp).encode("utf-8") * 3)
    cases += [b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xf0\x8f\xbf\xbf", b"\xed\xbf"]
    mismatches = [b for b in cases if c.valid_utf8(b) != strict_decodes(b)]
    assert mismatches == []
    assert sum(map(c.valid_utf8, cases)) > 20_000


def test_codepoints() -> None:
    assert c.codepoints("") == ()
    assert c.codepoints("aé€\U0001f600") == (0x61, 0xE9, 0x20AC, 0x1F600)
    with pytest.raises(EvalError, match="codepoints: expected a string"):
        c.codepoints(b"a")


# ---------------------------------------------------------------------------
# eq


def test_eq_float_modes() -> None:
    assert c.eq((PZ,), (PZ,), float="bits")
    assert not c.eq((PZ,), (NZ,), float="bits")
    assert c.eq((NAN,), (FloatValue("f64", NAN.bits),), float="bits")
    assert not c.eq((NAN,), (NAN2,), float="bits")
    assert c.eq((PZ,), (NZ,), float="ieee")
    assert not c.eq((NAN,), (NAN,), float="ieee")
    x = (Some(NAN),)
    assert not c.eq(x, x, float="ieee")
    assert c.eq((NAN,), (NAN2,), float="nan_any")
    assert not c.eq((PZ,), (NZ,), float="nan_any")
    assert not c.eq(NAN, NAN32, float="nan_any")
    assert c.eq(PZ, PZ)


def test_eq_order_ignore() -> None:
    assert c.eq((1, 2, 3), (3, 2, 1), order="ignore")
    assert not c.eq((1, 2, 3), (3, 2, 1))
    assert c.eq(((1, 2), (3,)), ((3,), (2, 1)), order="ignore")
    assert not c.eq((1, 1, 2), (1, 2, 2), order="ignore")
    assert not c.eq((NAN, PZ), (PZ, NAN), float="ieee", order="ignore")
    assert c.eq((NAN, PZ), (NZ, NAN2), float="nan_any", order="ignore") is False
    assert c.eq((NAN, NZ), (NZ, NAN2), float="nan_any", order="ignore")
    assert c.eq((NZ, PZ), (PZ, NZ), float="ieee", order="ignore")


def test_eq_structures() -> None:
    m1 = MapValue((("a", PZ), ("b", Some(1))))
    m2 = MapValue((("b", Some(1)), ("a", NZ)))
    assert c.eq(m1, m2, float="ieee")
    assert not c.eq(m1, m2, float="bits")
    r1 = RecordValue("R", (("x", PZ),))
    assert c.eq(r1, RecordValue("R", (("x", NZ),)), float="ieee")
    assert not c.eq(r1, RecordValue("S", (("x", PZ),)), float="ieee")
    rows = ((Some(f64(1.0)), None), (Some(NAN), Some(f64(2.0))))
    same_rows = ((Some(f64(1.0)), None), (Some(FloatValue("f64", NAN.bits)), Some(f64(2.0))))
    assert c.eq(rows, same_rows, float="bits")
    assert not c.eq(rows, same_rows, float="ieee")
    assert not c.eq(rows, rows[:1], float="bits")
    assert c.eq("a", "a") and not c.eq("a", b"a") and c.eq(POS_INF, POS_INF)


def test_eq_knobs_are_validated() -> None:
    with pytest.raises(EvalError, match="eq: float= must be one of"):
        c.eq(1, 1, float="exact")
    with pytest.raises(EvalError, match="eq: order= must be one of"):
        c.eq(1, 1, order="sorted")


def test_eq_handles() -> None:
    h1, h2, h3 = (Handle(object(), "Frame") for _ in range(3))
    with pytest.raises(EvalError, match="cannot compare model handles"):
        c.eq(h1, h2, float="bits")
    with pytest.raises(EvalError, match="cannot compare model handles"):
        c.eq(h1, h2, float="bits", ctx=object())
    ctx = FakeCtx(
        {
            h1.id: {"columns": ("a",), "rows": ((Some(PZ),),)},
            h2.id: {"rows": ((Some(PZ),),), "columns": ("a",)},
            h3.id: {"columns": ("a",), "rows": ((Some(NZ),),)},
        }
    )
    assert c.eq(h1, h2, float="bits", ctx=ctx)
    assert not c.eq(h1, h3, float="bits", ctx=ctx)
    assert c.eq(h1, h3, float="ieee", ctx=ctx)
    assert c.eq((h1, h3), (h3, h2), float="ieee", order="ignore", ctx=ctx)


def test_eq_handle_cycles_raise() -> None:
    h = Handle(object(), "Node")
    ctx = FakeCtx({h.id: {"next": Some(h)}})
    with pytest.raises(EvalError, match="contains itself"):
        c.eq(h, h, ctx=ctx)


values_tree = st.recursive(
    st.one_of(
        st.integers(-3, 3),
        st.booleans(),
        st.text(max_size=2),
        st.sampled_from([PZ, NZ, NAN, NAN2, f64(1.0), POS_INF, None]),
    ),
    lambda inner: st.one_of(
        st.lists(inner, max_size=3).map(tuple),
        inner.map(Some),
        st.lists(st.tuples(st.text(max_size=1), inner), max_size=3, unique_by=lambda kv: kv[0]).map(
            lambda items: MapValue(tuple(items))
        ),
    ),
    max_leaves=10,
)


@given(values_tree, values_tree)
def test_eq_bits_is_same(a: Any, b: Any) -> None:
    assert c.eq(a, b, float="bits") == floats.same(a, b) == c.same(a, b)
    assert c.eq(a, a, float="bits")
    assert floats.same(a, a)


@given(values_tree)
def test_eq_ignore_order_accepts_reversal(a: Any) -> None:
    def rev(v: Any) -> Any:
        if isinstance(v, tuple):
            return tuple(rev(x) for x in reversed(v))
        if isinstance(v, Some):
            return Some(rev(v.value))
        if isinstance(v, MapValue):
            return MapValue(tuple((k, rev(x)) for k, x in reversed(v.items)))
        return v

    assert c.eq(a, rev(a), float="bits", order="ignore")


# ---------------------------------------------------------------------------
# Identity


def test_identity_functions_delegate_to_ctx() -> None:
    obj = object()
    a, b, d = Handle(obj, "M"), Handle(obj, "M"), Handle(object(), "M")
    ctx = FakeCtx()
    ctx.fresh_ids.add(a.id)
    ctx.shared.add(frozenset((a.id, d.id)))
    assert c.fresh(a, ctx=ctx) and not c.fresh(b, ctx=ctx)
    assert c.same_object(a, b, ctx=ctx) and not c.same_object(a, d, ctx=ctx)
    assert c.shares_memory(a, d, ctx=ctx) and not c.shares_memory(a, b, ctx=ctx)
    with pytest.raises(EvalError, match="fresh: needs an evaluation context"):
        c.fresh(a)
    with pytest.raises(EvalError, match="same_object: expected a model handle"):
        c.same_object(a, 3, ctx=ctx)
    with pytest.raises(EvalError, match="shares_memory: needs an evaluation context"):
        c.shares_memory(a, d)
