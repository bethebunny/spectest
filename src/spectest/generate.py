"""Hypothesis strategies for spec inputs: types, partitions, models and exhaustive domains.

``strategy`` draws runtime values (spectest.values) of a type. Floats are
drawn class-first over a default partition through spectest.sets, and
fixed-width integers uniformly over their bit patterns with extra weight on
boundaries, so special values (NaN, infinities, signed zeros, subnormals,
min, max, powers of two) are common. Every strategy shrinks toward small,
simple values. ``args_strategy`` draws the arguments of a function,
constructor or method, partition-uniform where a parameter has a set
partition. ``model_strategy`` draws a model's fields, reading its invariants
as constraints. ``exhaustive_inputs`` enumerates a small fixed-width domain.
"""

from __future__ import annotations

import functools
import inspect
import itertools
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Any, Literal, Self

from bitpattern import BDDSet
from hypothesis import strategies as st

from spectest import ast, sets
from spectest import types as _types
from spectest import values as _values
from spectest.types import (
    BoolT,
    BytesT,
    EnumT,
    FixedIntT,
    FloatT,
    IntT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    RealT,
    RecordT,
    StringT,
    TupleT,
    Type,
    TypeVarT,
    UnitT,
    has_canonical_eq,
    has_total_order,
    is_fixed_width,
    substitute,
)
from spectest.values import (
    NEG_INF,
    POS_INF,
    FloatValue,
    MapValue,
    RecordValue,
    Some,
    SpecError,
)

__all__ = [
    "DEFAULT",
    "DEFAULT_SIZES",
    "FieldPlan",
    "GenerateError",
    "GeneratedModel",
    "PartitionInfo",
    "Sizes",
    "admitted_set",
    "args_strategy",
    "broken_invariants",
    "computed_fields",
    "exhaustive_inputs",
    "field_plans",
    "fixed_strategy",
    "invariants_hold",
    "model_strategy",
    "partitions",
    "residual_invariants",
    "strategy",
]


class GenerateError(SpecError):
    """No strategy exists: an uninstantiated type variable, an interface handle, a bad type."""


class _Default:
    """The DEFAULT sentinel: omit the argument so the implementation uses its default."""

    _instance: _Default | None = None

    def __new__(cls) -> Self:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "DEFAULT"

    def __reduce__(self) -> str:
        return "DEFAULT"


DEFAULT = _Default()


@dataclass(frozen=True)
class Sizes:
    """Bounds on generated collections: top-level lists, nested lists, text, bytes.

    A ``long_share`` of top-level lists, strings and bytes (parameters and model
    fields, not their elements) is long: from twice ``max_list`` plus one up to
    ``long_list`` elements, and likewise for text and bytes, so code that
    switches algorithm above some size (numpy's portable argsort above 16
    elements, timsort's merges from 64) runs on both sides. A long value
    shrinks toward the shortest long length, and toward a short value when one
    still fails.
    """

    max_list: int = 8
    max_inner: int = 4
    max_text: int = 12
    max_bytes: int = 16
    long_list: int = 100
    long_text: int = 100
    long_bytes: int = 100
    long_share: float = 1 / 16

    @property
    def max_len(self) -> int:
        longest = [self.long_list, self.long_text, self.long_bytes] if self.long_share > 0 else []
        return max(self.max_list, self.max_inner, self.max_text, self.max_bytes, *longest)

    def long_bounds(self, kind: Literal["list", "text", "bytes"]) -> tuple[int, int] | None:
        """The lengths of long values of a kind, or None when there are none."""
        short, long = {
            "list": (self.max_list, self.long_list),
            "text": (self.max_text, self.long_text),
            "bytes": (self.max_bytes, self.long_bytes),
        }[kind]
        if self.long_share <= 0 or long <= 2 * short:
            return None
        return 2 * short + 1, long

    def problems(self) -> list[str]:
        """What makes these sizes unusable, if anything."""
        out = []
        for name in ("max_list", "max_inner", "max_text", "max_bytes"):
            v = getattr(self, name)
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                out.append(f"{name} must be a non-negative integer, got {v!r}")
        for name in ("long_list", "long_text", "long_bytes"):
            v = getattr(self, name)
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                out.append(f"{name} must be a non-negative integer, got {v!r}")
            elif v > MAX_LONG:
                out.append(f"{name} must be at most {MAX_LONG}, got {v}")
        share = self.long_share
        if isinstance(share, bool) or not isinstance(share, (int, float)) or not 0 <= share < 1:
            out.append(f"long_share must be a number in [0, 1), got {share!r}")
        return out


MAX_LONG = 1000


DEFAULT_SIZES = Sizes()


@dataclass(eq=False)
class GeneratedModel:
    """A drawn model value: its field values, for the binding's concretizer to build."""

    model: str
    targs: tuple[Type, ...]
    fields: dict[str, Any]

    def __repr__(self) -> str:
        args = f"<{', '.join(map(str, self.targs))}>" if self.targs else ""
        inner = ", ".join(f"{k}={v!r}" for k, v in self.fields.items())
        return f"{self.model}{args}({inner})"


@dataclass
class PartitionInfo:
    """A parameter's partition: compiled BDDSets ("set") or class expressions ("predicate")."""

    param: str
    kind: Literal["set", "predicate"]
    classes: list[tuple[str, Any]]
    elem: Type | None = None
    partition: ast.Partition | None = field(default=None, repr=False)

    @property
    def names(self) -> list[str]:
        return [name for name, _ in self.classes]

    def classify(self, value: Any) -> str | None:
        """The class of a value of a set partition (first match), or None."""
        if self.kind != "set":
            raise GenerateError(f"partition {self.param} has predicate classes; evaluate them")
        return sets.classify(value, self.classes)


Tenv = Mapping[str, Type | str] | None


# ---------------------------------------------------------------------------
# Scalars


_SIMPLE_FLOATS: tuple[Fraction | int, ...] = tuple(
    v
    for k in (*range(1, 11), 100, 1000, Fraction(1, 2), Fraction(3, 2), Fraction(1, 4))
    for v in (k, -k)
)

_INTERESTING_CODEPOINTS = (
    "00 09 0a 0d 20 7f a0 e9 df 130 301 3a3 645 5d0 e01 4e2d 3042 200b 200d 2028 202e feff fffd "
    "ffff 1f600 1f468 1d11e 10ffff"
)
_INTERESTING_CHARS = tuple(chr(int(c, 16)) for c in _INTERESTING_CODEPOINTS.split())

_BAD_UTF8 = (
    b"\x80",
    b"\xbf",
    b"\xc3",
    b"\xe2\x82",
    b"\xf0\x9f\x98",
    b"\xc0\x80",
    b"\xc1\xbf",
    b"\xe0\x80\xaf",
    b"\xf0\x80\x80\x80",
    b"\xed\xa0\x80",
    b"\xed\xbf\xbf",
    b"\xf4\x90\x80\x80",
    b"\xf8\x88\x80\x80\x80",
    b"\xfe",
    b"\xff",
)

_HUGE_POWERS = (8, 16, 31, 32, 53, 63, 64, 100, 128)
_INT_BOUND = 1 << 256
_OFFSET = 1 << 128
_MAX_WEIGHTS = 250


def _by_magnitude(values: Sequence[int]) -> list[int]:
    return sorted(values, key=lambda v: (abs(v), v < 0))


def _powers(t: FixedIntT) -> list[int]:
    """Powers of two and their neighbours, the most telling (2^k, 2^k - 1, -2^k) first."""
    first, second = [], []
    for k in range(1, t.bits + 1):
        p = 1 << k
        first += [p, p - 1, -p]
        second += [p + 1, -p + 1, -p - 1]
    return [v for v in dict.fromkeys(first + second) if t.min <= v <= t.max]


Emphasis = Sequence[tuple[Sequence[int], float]]


_SIMPLE_INTS = (0, 1, -1)
_SIMPLE_SHARE = 0.08


def _fixed_int_emphasis(t: FixedIntT) -> Emphasis:
    return (
        ([t.min, t.max, t.min + 1, t.max - 1], 0.10),
        (_by_magnitude(range(-16, 17)), 0.10),
        (_powers(t), 0.20),
    )


_INT_EMPHASIS: Emphasis = (
    ([0, 1, -1], 0.06),
    (_by_magnitude(range(-64, 65)), 0.44),
    ([s * ((1 << k) + d) for k in _HUGE_POWERS for d in (0, -1, 1) for s in (1, -1)], 0.15),
)


def _weights(emphasis: Emphasis, choice: Callable[[int], int | None]) -> dict[int, float]:
    """Point masses on choices: each group's total spread evenly over its values."""
    weights: dict[int, float] = {}
    for values, total in emphasis:
        found = [c for v in dict.fromkeys(values) if (c := choice(v)) is not None]
        found = [c for c in found if c not in weights][: _MAX_WEIGHTS - len(weights)]
        for c in found:
            weights[c] = total / len(found)
    return weights


def _has_weighted_draws() -> bool:
    try:
        from hypothesis.internal.conjecture.data import ConjectureData
    except ImportError:
        return False
    return "weights" in inspect.signature(ConjectureData.draw_integer).parameters


WEIGHTED_DRAWS = _has_weighted_draws()


class _WeightedChoice(st.SearchStrategy[Any]):
    """One integer choice in [lo, hi] with point masses on some values, then decoded.

    Hypothesis draws its own bounded integers this way to favour the range ends.
    Shrinking lowers the single choice toward lo, so thresholds come out exact.
    For a range of at most 2^64 values starting at _OFFSET (2^128), Hypothesis's
    integer distribution is flat in float64 and falls back to a uniform draw, so
    the unweighted mass is uniform; each such choice costs about 18 bytes of
    the 8 KiB a test case may use.
    """

    def __init__(
        self,
        lo: int,
        hi: int,
        weights: dict[int, float],
        decode: Callable[[int], Any] | None = None,
        name: str = "weighted",
    ) -> None:
        super().__init__()
        self.lo, self.hi, self.decode, self.name = lo, hi, decode, name
        self.weights = weights if weights and hi > lo else None

    def __repr__(self) -> str:
        return self.name

    def do_draw(self, data: Any) -> Any:
        choice = data.draw_integer(self.lo, self.hi, weights=self.weights)
        return choice if self.decode is None else self.decode(choice)


class _SimpleFirst(st.SearchStrategy[Any]):
    """One of a few simple values, or a draw from ``rest``.

    A leading choice picks simple value i < k (each with an even part of
    ``share``), or k for ``rest``. Shrinking lowers the leading choice, so it
    reaches every simple value that still fails wherever ``rest`` orders it: a
    failure on every negative i64 shrinks to -1, not to -2, where the
    negatives start in the member order.
    """

    def __init__(self, simple: Sequence[Any], share: float, rest: st.SearchStrategy[Any]) -> None:
        super().__init__()
        self.simple = tuple(simple)
        self.rest = rest
        self.probs = (*[share / len(self.simple)] * len(self.simple), 1 - share)

    def __repr__(self) -> str:
        return f"simple_first({list(self.simple)}, {self.rest!r})"

    def do_draw(self, data: Any) -> Any:
        i = _pick(data, self.probs)
        return self.simple[i] if i < len(self.simple) else data.draw(self.rest)


def _int_strategy(t: FixedIntT, within: BDDSet | None = None) -> st.SearchStrategy[int]:
    """Integers uniform over bit patterns (or a set's members), with extra weight on
    0, +-1, small values, powers of two and their neighbours, and the extremes."""
    if not (WEIGHTED_DRAWS and sets.FAR_INTEGERS_ARE_UNIFORM):
        return _class_first(_narrow(_fixed_classes(t), within))
    s = sets.domain(t) if within is None or not within else within

    def choice(v: int) -> int | None:
        return _OFFSET + sets.index_of(s, v) if v in s else None

    def decode(c: int) -> int:
        return sets.member(s, c - _OFFSET)

    emphasis = list(_fixed_int_emphasis(t))
    if within is not None and within:
        lo, hi = _int_bounds(within, t)
        emphasis.insert(0, ([lo, hi, lo + 1, hi - 1], 0.10))
    weights = _weights(emphasis, choice)
    members = _WeightedChoice(_OFFSET, _OFFSET + s.size - 1, weights, decode, f"{t}s({s.size})")
    simple = [v for v in _SIMPLE_INTS if v in s]
    return _SimpleFirst(simple, _SIMPLE_SHARE, members) if simple else members


def _int_bounds(s: BDDSet, t: FixedIntT) -> tuple[int, int]:
    """The least and greatest members of a non-empty set of integers."""

    def least(lo: int, hi: int, has: Callable[[int], bool]) -> int:
        while lo < hi:
            mid = (lo + hi) // 2
            if has(mid):
                hi = mid
            else:
                lo = mid + 1
        return lo

    low = least(t.min, t.max, lambda v: bool(s & sets.int_range(t, None, v + 1)))
    high = least(t.min, t.max, lambda v: not s & sets.int_range(t, v + 1, None))
    return low, high


def _unbounded_ints() -> st.SearchStrategy[int]:
    """Mostly small integers, sometimes near big powers of two, up to +-2^256."""
    if not WEIGHTED_DRAWS:
        return st.integers()
    weights = _weights(_INT_EMPHASIS, lambda v: v)
    return _WeightedChoice(-_INT_BOUND, _INT_BOUND, weights, None, "ints()")


@functools.cache
def _fixed_classes(t: Type, cells: bool = False) -> tuple[tuple[str, BDDSet], ...]:
    """The default partition of a fixed-width type, simplest class first.

    Integers (when weighted draws are unavailable): small values, powers of two
    and their neighbours, the extremes, then the whole type. Floats: zeros,
    simple values, moderate and all normals, subnormals, infinities, NaNs (the
    two quiet NaNs only, for model cells).
    """
    if isinstance(t, BoolT):
        return (("all", sets.domain(t)),)
    codec = sets.codec_for(t)
    if isinstance(t, FixedIntT):
        extremes = [t.min, t.min + 1, t.max - 1, t.max]
        return (
            ("small", sets.int_range(t, -16, 17)),
            ("powers", codec.set(_powers(t))),
            ("extreme", codec.set(extremes)),
            ("uniform", sets.domain(t)),
        )
    if not isinstance(t, FloatT):
        raise GenerateError(f"{t} is not a fixed-width scalar type")
    layout = sets.LAYOUTS[t.fmt]
    normal = sets.named_set(t, "normal")
    simple = codec.set(
        [FloatValue(t.fmt, bits) for v in _SIMPLE_FLOATS if (bits := layout.exact(v)) is not None]
    )
    e = min(20, layout.bias // 2)
    moderate = normal & (
        sets.float_range(t, -(1 << e), 1 << e)
        - sets.float_range(t, Fraction(-1, 1 << e), Fraction(1, 1 << e))
    )
    if cells:
        nan = codec.set(
            [FloatValue(t.fmt, layout.qnan), FloatValue(t.fmt, layout.qnan | layout.sign)]
        )
    else:
        nan = sets.named_set(t, "nan")
    return (
        ("zero", sets.named_set(t, "zero")),
        ("simple", simple),
        ("moderate", moderate),
        ("normal", normal),
        ("subnormal", sets.named_set(t, "subnormal")),
        ("inf", sets.named_set(t, "inf")),
        ("nan", nan),
    )


def _narrow(
    classes: Sequence[tuple[str, BDDSet]], within: BDDSet | None
) -> list[tuple[str, BDDSet]]:
    """Classes intersected with a set; unchanged if that would leave nothing to draw."""
    if within is None:
        return list(classes)
    narrowed = [(name, s & within) for name, s in classes]
    narrowed = [(name, s) for name, s in narrowed if s]
    return narrowed or list(classes)


def _members(s: BDDSet) -> st.SearchStrategy[Any]:
    """Members of a set uniformly, in spectest.sets' index order (simple values first),
    from one compact choice that shrinks toward index 0."""
    n = s.size
    if n <= sets.SMALL_SET:
        return st.integers(0, n - 1).map(lambda i: sets.member(s, i))
    if not (WEIGHTED_DRAWS and sets.FAR_INTEGERS_ARE_UNIFORM):
        return sets.strategy_for_set(s)
    return _WeightedChoice(
        _OFFSET, _OFFSET + n - 1, {}, lambda c: sets.member(s, c - _OFFSET), f"members({n})"
    )


def _class_first(classes: Sequence[tuple[str, BDDSet]]) -> st.SearchStrategy[Any]:
    """A non-empty class uniformly, then one of its members uniformly."""
    live = [cls for _, cls in classes if cls]
    if not live:
        return st.nothing()
    members = [_members(cls) for cls in live]

    @st.composite
    def class_first(draw: st.DrawFn) -> Any:
        return draw(members[draw(st.integers(0, len(live) - 1))])

    return class_first()


@functools.cache
def _fixed(t: Type, cells: bool = False) -> st.SearchStrategy[Any]:
    if isinstance(t, BoolT):
        return st.booleans()
    if isinstance(t, FixedIntT):
        return _int_strategy(t)
    return _class_first(_fixed_classes(t, cells))


def fixed_strategy(t: Type, within: BDDSet | None = None) -> st.SearchStrategy[Any]:
    """Values of a fixed-width scalar type, optionally inside a set (ignored if empty).

    Floats are drawn class-first over a default partition; integers uniformly
    over their bit patterns with extra weight on small values, powers of two and
    their neighbours, and the extremes.
    """
    if within is None:
        return _fixed(t)
    if isinstance(t, BoolT):
        return sets.strategy_for_set(within if within else sets.domain(t), t)
    if isinstance(t, FixedIntT):
        return _int_strategy(t, within)
    return _class_first(_narrow(_fixed_classes(t), within))


_UNBOUNDED_INTS = _unbounded_ints()
_ALPHABET = st.one_of(st.characters(codec="utf-8"), st.sampled_from(_INTERESTING_CHARS))


@functools.cache
def _text(max_size: int, min_size: int = 0) -> st.SearchStrategy[str]:
    return st.text(_ALPHABET, min_size=min_size, max_size=max_size)


def _pick(data: Any, probs: Sequence[float]) -> int:
    """An index drawn with the given (positive) probabilities, from one choice that
    shrinks toward 0."""
    if WEIGHTED_DRAWS:
        # The weights' remainder is spread evenly over every index, so take it off each.
        least = min(probs) / 2
        weights = {i: p - least for i, p in enumerate(probs)}
        return data.draw_integer(0, len(probs) - 1, weights=weights)
    point, total = data.draw_integer(0, 1023) / 1024, 0.0
    for i, p in enumerate(probs):
        total += p
        if point < total:
            return i
    return len(probs) - 1


class _SometimesLong(st.SearchStrategy[Any]):
    """Short values, or with probability ``share`` a long one from one of ``longs``.

    One leading choice picks the strategy (0 for short), and each begins with a
    plain Hypothesis collection right after that choice, so lowering it keeps
    the elements already drawn: a long value whose first elements still fail
    shrinks into a shorter strategy, and on from there.
    """

    def __init__(
        self,
        short: st.SearchStrategy[Any],
        longs: Sequence[st.SearchStrategy[Any]],
        share: float,
    ) -> None:
        super().__init__()
        self.strategies = (short, *longs)
        self.probs = (1 - share, *[share / len(longs)] * len(longs))

    def __repr__(self) -> str:
        return f"sometimes_long({', '.join(map(repr, self.strategies))})"

    def do_draw(self, data: Any) -> Any:
        return data.draw(self.strategies[_pick(data, self.probs)])


def _with_long(
    short: st.SearchStrategy[Any],
    bounds: tuple[int, int] | None,
    of_lengths: Callable[[int, int], st.SearchStrategy[Any]],
    share: float,
    min_size: int = 0,
    *,
    halves: bool = True,
) -> st.SearchStrategy[Any]:
    """``short``, sometimes long: ``of_lengths(lo, hi)`` over the long range, and with
    ``halves`` also over its upper half, so that the longest lengths are common too
    (Hypothesis's collections favour lengths near their minimum)."""
    if bounds is None or share <= 0:
        return short
    lo, hi = max(bounds[0], min_size), bounds[1]
    if lo > hi:
        return short
    longs = [of_lengths(lo, hi)]
    if halves and (mid := (lo + hi) // 2) > lo:
        longs.append(of_lengths(mid, hi))
    return _SometimesLong(short, longs, share)


def _palette_lists(
    elem: st.SearchStrategy[Any], lo: int, hi: int
) -> st.SearchStrategy[tuple[Any, ...]]:
    """Lists of lo to hi elements (the length drawn uniformly), taken from a palette of
    1 to lo fresh elements by indices drawn as one byte string.

    A long list then costs a few element draws, not a hundred, and repeats its
    values, as sorting and deduplication want. The palette is drawn first, like a
    short list, so a long list whose palette fails as a short list can shrink
    into it (spectest.shrink's pass shortens the others).
    """
    palette = st.lists(elem, min_size=1, max_size=lo)

    @st.composite
    def lists(draw: st.DrawFn) -> tuple[Any, ...]:
        values = draw(palette)
        n = draw(st.integers(lo, hi))
        indices = draw(st.binary(min_size=n, max_size=n))
        return tuple(values[i % len(values)] for i in indices)

    return lists()


def _text_between(lo: int, hi: int) -> st.SearchStrategy[str]:
    return _text(hi, lo)


def _bytes_between(lo: int, hi: int) -> st.SearchStrategy[bytes]:
    return _bytes(hi, lo)


def _utf8_prefix(text: str, limit: int) -> bytes:
    out = bytearray()
    for ch in text:
        encoded = ch.encode("utf-8")
        if len(out) + len(encoded) > limit:
            break
        out += encoded
    return bytes(out)


def _splice(parts: tuple[bytes, bytes, int], limit: int) -> bytes:
    valid, bad, at = parts
    at = min(at, len(valid))
    return (valid[:at] + bad + valid[at:])[:limit]


@functools.cache
def _bytes(max_size: int, min_size: int = 0) -> st.SearchStrategy[bytes]:
    """Arbitrary bytes, valid UTF-8 encodings of text, and UTF-8 with one bad sequence;
    text shorter than ``min_size`` is padded with "0"."""
    encoded = _text(max_size).map(lambda s: _utf8_prefix(s, max_size))
    broken = st.tuples(encoded, st.sampled_from(_BAD_UTF8), st.integers(0, max_size)).map(
        lambda parts: _splice(parts, max_size)
    )
    if min_size:
        encoded, broken = (x.map(lambda b: b.ljust(min_size, b"0")) for x in (encoded, broken))
    return st.one_of(st.binary(min_size=min_size, max_size=max_size), encoded, broken)


_QErrT = getattr(_types, "QErrT", None)
_QError = getattr(_values, "QError", None)

_REALS = st.one_of(
    st.integers().map(Fraction),
    st.fractions(),
    st.sampled_from((POS_INF, NEG_INF)),
)


_SEEN: dict[str, st.SearchStrategy[list[Any]]] = {}
_POOLED: dict[tuple[str, bool], st.SearchStrategy[Any]] = {}


def _seen(key: str) -> st.SearchStrategy[list[Any]]:
    """The values of one kind drawn fresh so far in the current test case."""
    if key not in _SEEN:
        _SEEN[key] = st.shared(st.builds(list), key=key)
    return _SEEN[key]


def _sometimes_from_seen(
    fresh: st.SearchStrategy[tuple[Any, ...]], key: str, max_size: int, unique: bool
) -> st.SearchStrategy[tuple[Any, ...]]:
    """Fresh lists, or about one in four times a list of values already drawn in this
    test case (a subset of a frame's columns, keys of an earlier map)."""
    seen_in_case = _seen(key)
    unique_by = _identity if unique else None

    @st.composite
    def lists(draw: st.DrawFn) -> tuple[Any, ...]:
        seen = draw(seen_in_case)
        if seen and draw(st.integers(0, 3)) == 3:
            pick = st.sampled_from(tuple(seen))
            return tuple(draw(st.lists(pick, max_size=max_size, unique_by=unique_by)))
        return draw(fresh)

    return lists()


def _pooled(
    base: st.SearchStrategy[Any], key: str, reuse: bool = True, seen: str | None = None
) -> st.SearchStrategy[Any]:
    """Fresh values, or about one in three times a value of the same kind already drawn
    in this test case.

    Reuse makes equal values common across parameters, fields and steps (keys
    that collide, duplicates in a list, names taken from a frame's columns), and
    shrinks toward fresh draws. Without ``reuse`` (map keys, distinct lists) the
    fresh values are only recorded. ``key`` names the base: one key, one base;
    ``seen`` names the values shared with other bases (default: ``key``).
    """
    if (key, reuse) in _POOLED:
        return _POOLED[key, reuse]
    seen_in_case = _seen(seen or key)

    @st.composite
    def leaf(draw: st.DrawFn) -> Any:
        seen = draw(seen_in_case)
        if reuse and seen and draw(st.integers(0, 2)) == 2:
            return draw(st.sampled_from(tuple(seen)))
        value = draw(base)
        seen.append(value)
        return value

    _POOLED[key, reuse] = leaf()
    return _POOLED[key, reuse]


def _identity(value: Any) -> Any:
    """A hashable key under which two runtime values are equal exactly when ``same`` holds."""
    if isinstance(value, bool):
        return ("bool", value)
    if isinstance(value, tuple):
        return tuple(_identity(v) for v in value)
    if isinstance(value, Some):
        return ("some", _identity(value.value))
    if isinstance(value, MapValue):
        return ("map", frozenset((_identity(k), _identity(v)) for k, v in value.items))
    if isinstance(value, RecordValue):
        return ("record", value.name, tuple((n, _identity(v)) for n, v in value.fields))
    if isinstance(value, GeneratedModel):
        return ("model", id(value))
    return value


def _count(t: Type) -> int | None:
    """How many values a type has, when that is small enough to matter (None: many)."""
    if isinstance(t, BoolT):
        return 2
    if isinstance(t, UnitT):
        return 1
    if isinstance(t, LiteralT):
        return len(t.values)
    if isinstance(t, EnumT):
        return len(t.members)
    if isinstance(t, FixedIntT) and t.bits <= 16:
        return 1 << t.bits
    if isinstance(t, OptionT):
        inner = _count(t.elem)
        return None if inner is None else inner + 1
    if isinstance(t, TupleT):
        total = 1
        for e in t.elems:
            n = _count(e)
            if n is None:
                return None
            total *= n
        return total
    return None


def _flat(t: Type) -> bool:
    """Is the type a scalar, or a tuple, option or record of them? Only lists of such
    elements are sometimes long, so that a long list stays well inside the choices
    Hypothesis allows one test case (8 KiB)."""
    if isinstance(t, ListT | MapT | ModelT):
        return False
    if isinstance(t, TupleT):
        return all(_flat(e) for e in t.elems)
    if isinstance(t, OptionT):
        return _flat(t.elem)
    if isinstance(t, RecordT):
        return all(_flat(ft) for _, ft in t.fields)
    return True


def _few(t: Type, n: int) -> bool:
    """Has the type fewer than n values (so a unique list of n of them cannot exist)?"""
    count = _count(t)
    return count is not None and count < n


def _length(value: Any) -> int:
    if isinstance(value, MapValue):
        return len(value.items)
    return len(value)


@st.composite
def _optional(draw: st.DrawFn, elem: st.SearchStrategy[Any]) -> Any:
    if draw(st.integers(0, 4)) == 0:
        return None
    return Some(draw(elem))


# ---------------------------------------------------------------------------
# Types


def _as_type(t: Type | str, spec: Any, what: str) -> Type:
    """A type, or type text such as "list<i64>" resolved in the spec."""
    if isinstance(t, str):
        if spec is None:
            raise GenerateError(f"cannot resolve {what} = {t!r} without a spec")
        t = spec.resolve_type(t)
    if not isinstance(t, Type):
        raise GenerateError(f"{what} is {t!r}, which is not a type")
    return t


def _bind_tenv(tenv: Tenv, spec: Any) -> dict[str, Type]:
    return {name: _as_type(t, spec, name) for name, t in (tenv or {}).items()}


def _free_var(t: Type) -> TypeVarT | None:
    if isinstance(t, TypeVarT):
        return t
    children: tuple[Type, ...] = ()
    if isinstance(t, ListT | OptionT):
        children = (t.elem,)
    elif isinstance(t, MapT):
        children = (t.key, t.value)
    elif isinstance(t, TupleT):
        children = t.elems
    elif isinstance(t, ModelT):
        children = t.args
    elif isinstance(t, RecordT):
        children = tuple(ft for _, ft in t.fields)
    for child in children:
        if (v := _free_var(child)) is not None:
            return v
    return None


def _unbound(v: TypeVarT, where: str = "") -> GenerateError:
    at = f" in {where}" if where else ""
    return GenerateError(
        f"type variable {v.name}{at} is not instantiated; pass tenv={{'{v.name}': ...}}"
    )


class _Builder:
    """Builds and memoizes strategies for one spec and one set of sizes."""

    def __init__(self, spec: Any, sizes: Sizes) -> None:
        self.spec = spec
        self.sizes = sizes
        self.memo: dict[Any, st.SearchStrategy[Any]] = {}

    def build(
        self, t: Type, *, nested: bool = False, cells: bool = False, reuse: bool = True
    ) -> st.SearchStrategy[Any]:
        """``nested``: inside a collection; ``cells``: inside a model; ``reuse``: scalars
        may repeat values drawn earlier in the test case (not for unique elements)."""
        key = (t, nested, cells, reuse)
        if key not in self.memo:
            self.memo[key] = self.make(t, nested, cells, reuse)
        return self.memo[key]

    def max_list(self, nested: bool) -> int:
        return self.sizes.max_inner if nested else self.sizes.max_list

    def pool(
        self, t: Type, cells: bool, long: bool = False
    ) -> tuple[st.SearchStrategy[Any], str, str] | None:
        """The base strategy of a scalar type whose values may be reused, its key, and the
        key of the values drawn so far (shared by a type's short and sometimes-long bases)."""
        sizes = self.sizes
        if isinstance(t, IntT):
            return _UNBOUNDED_INTS, "spectest.pool:int", "spectest.pool:int"
        if isinstance(t, FixedIntT):
            return _fixed(t), f"spectest.pool:{t}", f"spectest.pool:{t}"
        if isinstance(t, FloatT):
            key = f"spectest.pool:{t}{':cells' if cells else ''}"
            return _fixed(t, cells), key, key
        if isinstance(t, StringT | BytesT):
            kind: Literal["text", "bytes"] = "text" if isinstance(t, StringT) else "bytes"
            short = sizes.max_text if kind == "text" else sizes.max_bytes
            seen = f"spectest.pool:{t}:{short}"
            base = _text(short) if kind == "text" else _bytes(short)
            bounds = sizes.long_bounds(kind) if long else None
            if bounds is None:
                return base, seen, seen
            between = _text_between if kind == "text" else _bytes_between
            key = f"{seen}:long:{bounds[1]}:{sizes.long_share}"
            return _with_long(base, bounds, between, sizes.long_share), key, seen
        return None

    def list_of(
        self,
        elem_t: Type,
        max_size: int,
        *,
        cells: bool = False,
        reuse: bool = True,
        unique: bool = False,
        long: bool = False,
        min_size: int = 0,
    ) -> st.SearchStrategy[tuple[Any, ...]]:
        """Lists of min_size to max_size elements; with ``long``, sometimes long ones."""
        elem = self.build(elem_t, nested=True, cells=cells, reuse=reuse)
        unique_by = _identity if unique else None

        def between(lo: int, hi: int) -> st.SearchStrategy[tuple[Any, ...]]:
            return st.lists(elem, min_size=lo, max_size=hi, unique_by=unique_by).map(tuple)

        def palette(lo: int, hi: int) -> st.SearchStrategy[tuple[Any, ...]]:
            return _palette_lists(elem, lo, hi)

        fresh = between(min_size, max_size)
        bounds = self.sizes.long_bounds("list") if long else None
        share = self.sizes.long_share
        if bounds is not None and max_size < bounds[0] and _flat(elem_t):
            if not unique:
                fresh = _with_long(fresh, bounds, palette, share, min_size, halves=False)
            elif not _few(elem_t, bounds[1]):
                fresh = _with_long(fresh, bounds, between, share, min_size)
        pool = self.pool(elem_t, cells)
        if not reuse or pool is None or min_size:
            return fresh
        return _sometimes_from_seen(fresh, pool[2], max_size, unique)

    def sized(
        self, t: Type, lo: int, hi: int | None, *, unique: bool = False
    ) -> st.SearchStrategy[Any] | None:
        """Values of a list, string, bytes or map type with a length in [lo, hi]. With no
        ``hi``: up to the usual bound (at least twice lo), and sometimes long. None for
        other types."""
        sizes = self.sizes

        def top(short: int) -> int:
            return min(max(short, 2 * lo), max(MAX_LONG, lo)) if hi is None else hi

        if isinstance(t, ListT):
            return self.list_of(
                t.elem, top(sizes.max_list), min_size=lo, long=hi is None, unique=unique
            )
        if isinstance(t, StringT | BytesT):
            kind: Literal["text", "bytes"] = "text" if isinstance(t, StringT) else "bytes"
            between = _text_between if kind == "text" else _bytes_between
            base = between(lo, top(sizes.max_text if kind == "text" else sizes.max_bytes))
            if hi is not None:
                return base
            return _with_long(base, sizes.long_bounds(kind), between, sizes.long_share, lo)
        if isinstance(t, MapT):
            k = self.build(t.key, nested=True, reuse=False)
            v = self.build(t.value, nested=True)
            items = st.lists(
                st.tuples(k, v),
                min_size=lo,
                max_size=top(sizes.max_list),
                unique_by=lambda kv: _identity(kv[0]),
            )
            return items.map(lambda kvs: MapValue(tuple(kvs)))
        return None

    def make(self, t: Type, nested: bool, cells: bool, reuse: bool) -> st.SearchStrategy[Any]:
        if isinstance(t, BoolT):
            return st.booleans()
        if (pool := self.pool(t, cells, long=not nested)) is not None:
            base, key, seen = pool
            return _pooled(base, key, reuse, seen)
        if isinstance(t, ListT):
            return self.list_of(
                t.elem, self.max_list(nested), cells=cells, reuse=reuse, long=not nested
            )
        if isinstance(t, TupleT):
            elems = (self.build(e, nested=nested, cells=cells, reuse=reuse) for e in t.elems)
            return st.tuples(*elems)
        if isinstance(t, OptionT):
            return _optional(self.build(t.elem, nested=nested, cells=cells, reuse=reuse))
        if isinstance(t, MapT):
            k = self.build(t.key, nested=True, cells=cells, reuse=False)
            v = self.build(t.value, nested=True, cells=cells, reuse=reuse)
            items = st.lists(
                st.tuples(k, v),
                max_size=self.max_list(nested),
                unique_by=lambda kv: _identity(kv[0]),
            )
            return items.map(lambda kvs: MapValue(tuple(kvs)))
        if isinstance(t, LiteralT):
            return st.sampled_from(t.values)
        if isinstance(t, EnumT):
            return st.sampled_from(t.members)
        if isinstance(t, RecordT):
            names = tuple(name for name, _ in t.fields)
            values = st.tuples(
                *(self.build(ft, nested=nested, cells=cells, reuse=reuse) for _, ft in t.fields)
            )
            return values.map(lambda vs: RecordValue(t.name, tuple(zip(names, vs, strict=True))))
        if isinstance(t, ModelT):
            if t.is_interface:
                raise GenerateError(
                    f"{t} is an interface: its handles come from its constructors, not from data"
                )
            return self.model(t.name, t.args)
        if isinstance(t, TypeVarT):
            raise _unbound(t)
        if isinstance(t, UnitT):
            return st.none()
        if isinstance(t, RealT):
            return _REALS
        if _QErrT is not None and isinstance(t, _QErrT) and _QError is not None:
            return st.builds(_QError, _UNBOUNDED_INTS.map(abs), st.integers(0, 3))
        raise GenerateError(f"cannot generate values of type {t}")

    def model(self, name: str, targs: tuple[Type, ...]) -> st.SearchStrategy[GeneratedModel]:
        key = ("model", name, targs)
        if key in self.memo:
            return self.memo[key]
        holder: dict[str, st.SearchStrategy[GeneratedModel]] = {}
        self.memo[key] = st.deferred(lambda: holder["s"])
        holder["s"] = self.make_model(name, targs)
        self.memo[key] = holder["s"]
        return holder["s"]

    def make_model(self, name: str, targs: tuple[Type, ...]) -> st.SearchStrategy[GeneratedModel]:
        decl = _model_decl(self.spec, name)
        tvars = list(self.spec.tparams.get(decl, {}))
        if len(targs) != len(tvars):
            raise GenerateError(
                f"{name} takes {len(tvars)} type argument(s), got {len(targs)}: "
                f"{', '.join(map(str, targs)) or 'none'}"
            )
        env = dict(zip(tvars, targs, strict=True))
        plan = _model_plan(decl, self.spec, self.sizes)
        drawers: list[tuple[str, Callable[[st.DrawFn, dict[str, Any]], Any]]] = []
        for fp in plan.fields:
            t = substitute(fp.type, env)
            if (v := _free_var(t)) is not None:
                raise _unbound(v, f"field {fp.name} of {name}")
            drawers.append((fp.name, self.field_drawer(fp, t)))
        model_targs = tuple(targs)

        @st.composite
        def draw_model(draw: st.DrawFn) -> GeneratedModel:
            values: dict[str, Any] = {}
            for fname, drawer in drawers:
                values[fname] = drawer(draw, values)
            return GeneratedModel(name, model_targs, values)

        return draw_model()

    def field_drawer(self, fp: FieldPlan, t: Type) -> Callable[[st.DrawFn, dict[str, Any]], Any]:
        if fp.compute is not None:
            how, source = fp.compute
            if how == "copy":
                return lambda draw, values: values[source]
            if how == "len":
                return lambda draw, values: _length(values[source])
            return lambda draw, values: source
        unique_by = _identity if fp.unique else None
        if fp.length_of is not None:
            assert isinstance(t, ListT)
            g = fp.length_of
            by_length: dict[int, st.SearchStrategy[Any]] = {}

            def exact(draw: st.DrawFn, values: dict[str, Any]) -> Any:
                n = _length(values[g])
                if n not in by_length:
                    by_length[n] = st.lists(
                        self.exact_length(t.elem, n, reuse=not fp.unique),
                        max_size=self.sizes.max_list,
                        unique_by=unique_by,
                    ).map(tuple)
                return draw(by_length[n])

            return exact
        if fp.unique or fp.inner:
            assert isinstance(t, ListT)
            size = self.sizes.max_inner if fp.inner else self.sizes.max_list
            elem = self.build(t.elem, nested=True, cells=True, reuse=not fp.unique)
            s = st.lists(elem, max_size=size, unique_by=unique_by).map(tuple)
        else:
            s = self.build(t, cells=True)
        return lambda draw, values: draw(s)

    def exact_length(self, t: Type, n: int, reuse: bool = True) -> st.SearchStrategy[Any]:
        if isinstance(t, ListT):
            elem = self.build(t.elem, nested=True, cells=True, reuse=reuse)
            return st.lists(elem, min_size=n, max_size=n).map(tuple)
        if isinstance(t, StringT):
            return _text(n, n)
        if isinstance(t, BytesT):
            return st.binary(min_size=n, max_size=n)
        raise GenerateError(f"cannot draw a {t} of a given length")


def strategy(
    t: Type, spec: Any = None, tenv: Tenv = None, sizes: Sizes = DEFAULT_SIZES
) -> st.SearchStrategy[Any]:
    """Runtime values of type ``t``; type variables are looked up in ``tenv``."""
    t = substitute(t, _bind_tenv(tenv, spec))
    return _Builder(spec, sizes).build(t)


# ---------------------------------------------------------------------------
# Models


def _model_decl(spec: Any, model: str | ast.ModelDecl) -> ast.ModelDecl:
    if isinstance(model, ast.ModelDecl):
        return model
    if spec is None:
        raise GenerateError(f"cannot generate model {model} without a spec")
    decl = spec.models.get(model)
    if decl is None:
        if model in getattr(spec, "interfaces", {}):
            raise GenerateError(
                f"{model} is an interface: its handles come from its constructors, not from data"
            )
        raise GenerateError(f"unknown model {model}")
    return decl


@dataclass
class FieldPlan:
    """How one field of a model is drawn (see ``field_plans``)."""

    name: str
    type: Type
    unique: bool = False
    inner: bool = False
    length_of: str | None = None
    compute: tuple[str, Any] | None = None


@dataclass
class _ModelPlan:
    fields: list[FieldPlan]
    residual: list[ast.Clause]


def _conjuncts(e: ast.Expr) -> list[ast.Expr]:
    if isinstance(e, ast.Binary) and e.op == "and":
        return _conjuncts(e.left) + _conjuncts(e.right)
    return [e]


def _len_arg(e: ast.Expr) -> ast.Expr | None:
    if (
        isinstance(e, ast.Call)
        and isinstance(e.func, ast.Name)
        and e.func.id == "len"
        and len(e.args) == 1
        and not e.kwargs
        and not e.type_args
    ):
        return e.args[0]
    return None


def _has_length(t: Type) -> bool:
    return isinstance(t, ListT | StringT | BytesT | MapT)


def _literal(e: ast.Expr) -> tuple[bool, Any]:
    if isinstance(e, ast.Num) and isinstance(e.value, int):
        return True, e.value
    if (
        isinstance(e, ast.Unary)
        and e.op == "-"
        and isinstance(e.operand, ast.Num)
        and isinstance(e.operand.value, int)
    ):
        return True, -e.operand.value
    if isinstance(e, ast.Str):
        return True, e.value
    if isinstance(e, ast.BoolLit):
        return True, e.value
    return False, None


def _admits_literal(t: Type, value: Any) -> bool:
    if isinstance(value, bool):
        return isinstance(t, BoolT)
    if isinstance(value, int):
        return isinstance(t, IntT) or isinstance(t, FixedIntT) and t.min <= value <= t.max
    if isinstance(value, str):
        return isinstance(t, StringT) or isinstance(t, LiteralT) and value in t.values
    return False


Fact = tuple[Any, ...]


class _InvariantReader:
    """Reads one conjunct of a model invariant as a generation constraint, or None."""

    def __init__(self, spec: Any, types: dict[str, Type], sizes: Sizes) -> None:
        self.spec = spec
        self.types = types
        self.order = {name: i for i, name in enumerate(types)}
        self.sizes = sizes

    def field_ref(self, e: ast.Expr, shadowed: str | None = None) -> str | None:
        if isinstance(e, ast.Name) and e.id in self.order and e.id != shadowed:
            res = getattr(self.spec, "resolution", {}).get(e)
            if res is None or res.kind == "field":
                return e.id
        if (
            isinstance(e, ast.Attribute)
            and isinstance(e.value, ast.Name)
            and e.value.id == "self"
            and e.attr in self.order
        ):
            return e.attr
        return None

    def read(self, e: ast.Expr) -> Fact | None:
        if isinstance(e, ast.BoolLit) and e.value:
            return ("true",)
        if isinstance(e, ast.Call) and isinstance(e.func, ast.Name) and e.func.id == "distinct":
            f = self.field_ref(e.args[0]) if len(e.args) == 1 and not e.kwargs else None
            if f is not None and isinstance(self.types[f], ListT):
                return ("distinct", f)
            return None
        if isinstance(e, ast.Comprehension) and e.kind == "all":
            return self.lengths(e)
        if isinstance(e, ast.Binary) and e.op == "==":
            return self.equation(e.left, e.right) or self.equation(e.right, e.left)
        return None

    def lengths(self, e: ast.Comprehension) -> Fact | None:
        f = self.field_ref(e.iterable)
        if f is None or not isinstance(e.body, ast.Binary) or e.body.op != "==":
            return None
        t = self.types[f]
        if not isinstance(t, ListT) or not isinstance(t.elem, ListT | StringT | BytesT):
            return None
        a, b = _len_arg(e.body.left), _len_arg(e.body.right)
        for mine, other in ((a, b), (b, a)):
            if isinstance(mine, ast.Name) and mine.id == e.var and other is not None:
                g = self.field_ref(other, shadowed=e.var)
                if g is not None and self.order[g] < self.order[f] and _has_length(self.types[g]):
                    return ("length", f, g)
        return None

    def equation(self, target: ast.Expr, source: ast.Expr) -> Fact | None:
        f = self.field_ref(target)
        if f is None:
            return None
        if (g := self.field_ref(source)) is not None:
            if g != f and self.order[g] < self.order[f] and self.types[g] == self.types[f]:
                return ("eq", f, ("copy", g))
            return None
        if (arg := _len_arg(source)) is not None:
            g = self.field_ref(arg)
            if g is None or g == f or self.order[g] > self.order[f]:
                return None
            t = self.types[f]
            fits = isinstance(t, IntT) or (
                isinstance(t, FixedIntT) and t.min <= 0 and t.max >= self.sizes.max_len
            )
            if fits and _has_length(self.types[g]):
                return ("eq", f, ("len", g))
            return None
        is_literal, value = _literal(source)
        if is_literal and _admits_literal(self.types[f], value):
            return ("eq", f, ("const", value))
        return None


def _observer_type(o: ast.Observe, decl: ast.ModelDecl, spec: Any) -> Type:
    sig = spec.signature.get(o)
    if sig is not None:
        return sig.result
    return spec.resolve_type(o.type, spec.tparams.get(decl, {}))


def _model_plan(decl: ast.ModelDecl, spec: Any, sizes: Sizes) -> _ModelPlan:
    """How to draw a model's fields, and which invariants construction does not enforce.

    Equations ``f == g``, ``f == len(g)`` and ``f == literal`` (g declared
    before f) compute f; ``distinct(f)`` draws a unique list; and
    ``all(x in f: len(x) == len(g))`` fixes the length of f's elements. Top-level
    ``and`` is split; a clause is residual unless every conjunct is enforced.
    """
    types = {o.name: _observer_type(o, decl, spec) for o in decl.observers if not o.params}
    plans = {name: FieldPlan(name, t) for name, t in types.items()}
    reader = _InvariantReader(spec, types, sizes)
    invariants = [c for c in decl.clauses if c.kind == "invariant" and c.expr is not None]
    facts = {c: [reader.read(e) for e in _conjuncts(c.expr)] for c in invariants}  # type: ignore[arg-type]
    enforced: set[tuple[int, int]] = set()

    for c in invariants:
        for i, fact in enumerate(facts[c]):
            if fact is not None and fact[0] == "eq" and plans[fact[1]].compute is None:
                plans[fact[1]].compute = fact[2]
                enforced.add((id(c), i))
    for c in invariants:
        for i, fact in enumerate(facts[c]):
            if fact is None or fact[0] == "eq":
                continue
            if fact[0] == "true":
                enforced.add((id(c), i))
                continue
            fp = plans[fact[1]]
            if fp.compute is not None:
                continue
            if fact[0] == "distinct":
                fp.unique = True
                enforced.add((id(c), i))
            elif fact[0] == "length" and fp.length_of in (None, fact[2]):
                fp.length_of = fact[2]
                g = plans[fact[2]]
                if g.compute is None and isinstance(g.type, ListT):
                    g.inner = True
                enforced.add((id(c), i))
    residual = [
        c for c in invariants if not all((id(c), i) in enforced for i in range(len(facts[c])))
    ]
    return _ModelPlan(list(plans.values()), residual)


def model_strategy(
    model: str | ast.ModelDecl,
    targs: Sequence[Type] | Mapping[str, Type] = (),
    spec: Any = None,
    sizes: Sizes = DEFAULT_SIZES,
) -> st.SearchStrategy[GeneratedModel]:
    """Field values of a model, drawn in declaration order with its invariants as constraints.

    Invariants listed by ``residual_invariants`` are not enforced; filter on them.
    """
    decl = _model_decl(spec, model)
    if isinstance(targs, Mapping):
        tvars = list(spec.tparams.get(decl, {}))
        missing = [v for v in tvars if v not in targs]
        if missing:
            raise _unbound(TypeVarT(missing[0]), decl.name)
        targs = [targs[v] for v in tvars]
    resolved = tuple(_as_type(t, spec, decl.name) for t in targs)
    for t in resolved:
        if (v := _free_var(t)) is not None:
            raise _unbound(v, f"the type arguments of {decl.name}")
    return _Builder(spec, sizes).model(decl.name, resolved)


def residual_invariants(
    model: str | ast.ModelDecl, spec: Any, sizes: Sizes = DEFAULT_SIZES
) -> list[ast.Clause]:
    """The model's invariants that model_strategy does not enforce by construction."""
    decl = _model_decl(spec, model)
    return _model_plan(decl, spec, sizes).residual


def field_plans(
    model: str | ast.ModelDecl, spec: Any, sizes: Sizes = DEFAULT_SIZES
) -> list[FieldPlan]:
    """How each field of a model is drawn: computed from an earlier field, unique, or a
    list whose elements have the length of an earlier field (``length_of``)."""
    decl = _model_decl(spec, model)
    return _model_plan(decl, spec, sizes).fields


def broken_invariants(gm: GeneratedModel, spec: Any) -> list[str]:
    """The IDs of the model's invariants that a drawn model's fields break; one that
    cannot be evaluated on them counts as broken."""
    from spectest import eval as ev

    decl = _model_decl(spec, gm.model)
    h = _as_input(gm)
    tenv = dict(zip(spec.tparams.get(decl, {}), gm.targs, strict=False))
    env = ev.Env(values={"self": h}, fields=h, tenv=tenv)
    ctx = _DrawnFields(spec)
    broken: list[str] = []
    for c in decl.clauses:
        if c.kind != "invariant" or c.expr is None:
            continue
        try:
            ok = ev.holds(c, env, spec, ctx)
        except (SpecError, _values.SkipClause):
            ok = False
        if not ok:
            broken.append(c.id)
    return broken


def invariants_hold(gm: GeneratedModel, spec: Any) -> bool:
    """Do a drawn model's fields satisfy every invariant of its model?"""
    return not broken_invariants(gm, spec)


def computed_fields(
    plans: Sequence[FieldPlan], values: Mapping[str, Any], *, missing_only: bool = False
) -> dict[str, Any]:
    """The field values in declaration order, with every computed field (f == g,
    f == len(g), f == literal) recomputed from the others (with ``missing_only``,
    only those not given). KeyError names a field that is missing and not computed."""
    out: dict[str, Any] = {}
    for fp in plans:
        if fp.compute is None or (missing_only and fp.name in values):
            out[fp.name] = values[fp.name]
            continue
        how, source = fp.compute
        if how == "copy":
            out[fp.name] = out[source]
        elif how == "len":
            out[fp.name] = _length(out[source])
        else:
            out[fp.name] = source
    return out


# ---------------------------------------------------------------------------
# Callables: arguments, partitions and exhaustive domains


def _callable(decl: ast.Callable_ | str, spec: Any) -> ast.Callable_:
    if isinstance(decl, ast.Callable_):
        return decl
    name, _, member = decl.partition(".")
    if not member and name in spec.fns:
        return spec.fns[name]
    iface = spec.interfaces.get(name)
    if iface is not None:
        for d in [*iface.ctors, *iface.methods]:
            if d.name == member:
                return d
    raise GenerateError(f"unknown function, constructor or method {decl}")


def _decl_name(decl: ast.Callable_, spec: Any) -> str:
    return getattr(spec, "decl_ids", {}).get(decl, decl.name)


def _tvars(decl: ast.Callable_, spec: Any) -> dict[str, TypeVarT]:
    tvars = dict(getattr(spec, "tparams", {}).get(decl, {}))
    for tp in getattr(decl, "tparams", []):
        tvars.setdefault(tp.name, TypeVarT(tp.name, tp.bound))
    return tvars


def _param_types(decl: ast.Callable_, spec: Any, tenv: Tenv) -> list[Type]:
    """The parameter types of a callable with type variables instantiated (self excluded)."""
    tvars = _tvars(decl, spec)
    sig = getattr(spec, "signature", {}).get(decl)
    if sig is not None:
        declared = list(sig.params)
    else:
        declared = [spec.resolve_type(p.type, tvars) for p in decl.params]
    env = _bind_tenv(tenv, spec)
    where = _decl_name(decl, spec)
    for name, tv in tvars.items():
        if name not in env:
            continue
        t = env[name]
        if tv.bound == "Ord" and not has_total_order(t):
            raise GenerateError(f"{name} = {t} in {where}: {name}: Ord needs a total order")
        if tv.bound == "Eq" and not has_canonical_eq(t):
            raise GenerateError(f"{name} = {t} in {where}: {name}: Eq needs canonical equality")
    out = []
    for p, t in zip(decl.params, declared, strict=True):
        t = substitute(t, env)
        if (v := _free_var(t)) is not None:
            raise _unbound(v, f"parameter {p.name} of {where}")
        out.append(t)
    return out


def partitions(decl: ast.Callable_ | str, spec: Any, tenv: Tenv = None) -> list[PartitionInfo]:
    """Each partitioned parameter's classes: compiled sets for fixed-width parameters,
    class expressions otherwise."""
    decl = _callable(decl, spec)
    tvars = _tvars(decl, spec)
    env = _bind_tenv(tenv, spec)
    declared = dict(zip((p.name for p in decl.params), _declared_types(decl, spec), strict=True))
    out: list[PartitionInfo] = []
    for part in decl.partitions:
        t = declared.get(part.param)
        elem = substitute(t, env) if t is not None else None
        compiled = sets.partition_sets(decl, part.param, spec, tvars)
        if compiled is not None:
            out.append(PartitionInfo(part.param, "set", compiled, elem, part))
        else:
            classes = [(c.name, c.expr) for c in part.classes]
            out.append(PartitionInfo(part.param, "predicate", classes, elem, part))
    return out


def _declared_types(decl: ast.Callable_, spec: Any) -> list[Type]:
    sig = getattr(spec, "signature", {}).get(decl)
    if sig is not None:
        return list(sig.params)
    tvars = _tvars(decl, spec)
    return [spec.resolve_type(p.type, tvars) for p in decl.params]


def _requires_set(decl: ast.Callable_, param: str, t: Type, spec: Any) -> BDDSet | None:
    aliases = getattr(spec, "aliases", None) or {}
    return sets.requires_set(decl, param, t, aliases=aliases)


def admitted_set(
    decl: ast.Callable_ | str,
    param: str,
    spec: Any,
    tenv: Tenv = None,
    *,
    info: PartitionInfo | None = None,
) -> BDDSet | None:
    """The values of a fixed-width parameter worth trying: the union of its set
    partition (else the whole type) intersected with what requires admits as a set.

    None when the parameter is not fixed-width.
    """
    decl = _callable(decl, spec)
    names = [p.name for p in decl.params]
    if param not in names:
        raise GenerateError(f"{_decl_name(decl, spec)} has no parameter {param}")
    t = _param_types(decl, spec, tenv)[names.index(param)]
    if not is_fixed_width(t):
        return None
    if info is None:
        info = next((i for i in partitions(decl, spec, tenv) if i.param == param), None)
    if info is not None and info.kind == "set":
        domain = sets.codec_for(t).none
        for _, s in info.classes:
            domain = domain | s
    else:
        domain = sets.domain(t)
    req = _requires_set(decl, param, t, spec)
    return domain if req is None else domain & req


def _distinct_params(decl: ast.Callable_, spec: Any) -> set[str]:
    """Parameters p with a top-level ``requires distinct(p)``: drawn as unique lists."""
    names = {p.name for p in decl.params}
    out: set[str] = set()
    for clause in decl.clauses:
        if clause.kind != "requires" or clause.expr is None:
            continue
        for e in _conjuncts(clause.expr):
            if (
                isinstance(e, ast.Call)
                and isinstance(e.func, ast.Name)
                and e.func.id == "distinct"
                and len(e.args) == 1
                and isinstance(arg := e.args[0], ast.Name)
                and arg.id in names
            ):
                res = getattr(spec, "resolution", {}).get(arg)
                if res is None or res.kind == "param":
                    out.add(arg.id)
    return out


# ---------------------------------------------------------------------------
# Predicate partitions


PREDICATE_TRIES = 4

_FLIP_COMPARISON = {"==": "==", "!=": "!=", "<": ">", "<=": ">=", ">": "<", ">=": "<="}


def _is_param(e: ast.Expr, param: str, spec: Any) -> bool:
    if not (isinstance(e, ast.Name) and e.id == param):
        return False
    res = getattr(spec, "resolution", {}).get(e)
    return res is None or res.kind == "param"


def _length_bounds(expr: ast.Expr, param: str, spec: Any) -> tuple[int, int | None, bool]:
    """The lengths [lo, hi] that the conjuncts ``len(p) <op> n`` of a class allow, and
    whether those conjuncts are the whole class."""
    lo, hi, whole = 0, None, True
    for e in _conjuncts(expr):
        bound = None
        if isinstance(e, ast.Binary) and e.op in _FLIP_COMPARISON and e.op != "!=":
            for arg, other, op in ((e.left, e.right, e.op), (e.right, e.left, _FLIP_COMPARISON[e.op])):
                target = _len_arg(arg)
                is_literal, n = _literal(other)
                if (
                    target is not None
                    and _is_param(target, param, spec)
                    and is_literal
                    and isinstance(n, int)
                    and not isinstance(n, bool)
                ):
                    bound = op, n
                    break
        if bound is None:
            whole = False
            continue
        op, n = bound
        if op in ("==", ">="):
            lo = max(lo, n)
        elif op == ">":
            lo = max(lo, n + 1)
        if op in ("==", "<="):
            hi = n if hi is None else min(hi, n)
        elif op == "<":
            hi = n - 1 if hi is None else min(hi, n - 1)
    return max(lo, 0), hi, whole


class _DrawnFields:
    """An evaluation context over drawn values: a model is observed through its drawn
    fields, and nothing else outside the prelude is available."""

    def __init__(self, spec: Any) -> None:
        self.spec = spec

    def observe(self, handle: Any, observer: str, args: tuple) -> Any:
        fields = getattr(handle.obj, "fields", {})
        if args or observer not in fields:
            raise _values.EvalError(f"{handle.model}.{observer} is not a drawn field")
        return fields[observer]

    def fields(self, handle: Any) -> dict[str, Any]:
        return dict(handle.obj.fields)

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        raise _values.EvalError(f"calling {name} is not allowed in a partition class")

    def is_fresh(self, handle: Any) -> bool:
        raise _values.EvalError("fresh is not available in a partition class")

    def same_object(self, a: Any, b: Any) -> bool:
        return a.obj is b.obj

    def shares_memory(self, a: Any, b: Any) -> bool:
        raise _values.EvalError("shares_memory is not available in a partition class")

    def members(self, s: BDDSet, elem: Type) -> tuple[Any, bool]:
        return sets.enumerate_set(s), False


def _as_input(value: Any) -> Any:
    if isinstance(value, GeneratedModel):
        return _values.Handle(value, value.model, targs=tuple(value.targs))
    return value


class _Satisfying(st.SearchStrategy[Any]):
    """Draws of ``base`` until one satisfies a class expression; after PREDICATE_TRIES
    draws, the last one (so a class the drawn values rarely meet only gets fewer)."""

    def __init__(
        self, base: st.SearchStrategy[Any], expr: ast.Expr, param: str, spec: Any, tenv: dict
    ) -> None:
        super().__init__()
        self.base, self.expr, self.param, self.spec, self.tenv = base, expr, param, spec, tenv

    def __repr__(self) -> str:
        return f"satisfying({self.base!r})"

    def holds(self, value: Any) -> bool:
        from spectest import eval as ev

        env = ev.Env(values={self.param: _as_input(value)}, tenv=self.tenv)
        try:
            return ev.evaluate(self.expr, env, self.spec, _DrawnFields(self.spec)) is True
        except (SpecError, _values.SkipClause):
            return False

    def do_draw(self, data: Any) -> Any:
        for _ in range(PREDICATE_TRIES - 1):
            value = data.draw(self.base)
            if self.holds(value):
                return value
        return data.draw(self.base)


def _steered(
    info: PartitionInfo,
    t: Type,
    base: st.SearchStrategy[Any],
    builder: _Builder,
    spec: Any,
    tenv: dict[str, Type],
    unique: bool = False,
) -> st.SearchStrategy[Any]:
    """A parameter with a predicate partition: a class uniformly, or ``base`` as often as
    any class, then a value of the class.

    A class whose conjuncts include ``len(p) <op> n`` draws lengths in the range
    they allow; any other conjunct is met by drawing again (``_Satisfying``).
    """
    if info.partition is None:
        return base
    options: list[st.SearchStrategy[Any]] = []
    for _, expr in info.classes:
        lo, hi, whole = _length_bounds(expr, info.param, spec)
        if hi is not None and hi < lo:
            continue
        drawn = builder.sized(t, lo, hi, unique=unique) if (lo, hi) != (0, None) else None
        if drawn is None:
            drawn, whole = base, False
        options.append(drawn if whole else _Satisfying(drawn, expr, info.param, spec, tenv))
    options.append(base)

    @st.composite
    def class_first(draw: st.DrawFn) -> Any:
        return draw(options[draw(st.integers(0, len(options) - 1))])

    return class_first()


@st.composite
def _sometimes_default(draw: st.DrawFn, s: st.SearchStrategy[Any]) -> Any:
    if draw(st.integers(0, 3)) == 0:
        return DEFAULT
    return draw(s)


def args_strategy(
    decl: ast.Callable_ | str,
    spec: Any,
    tenv: Tenv = None,
    sizes: Sizes = DEFAULT_SIZES,
    *,
    defaults: bool = True,
    examples: Sequence[Mapping[str, Any]] = (),
) -> st.SearchStrategy[dict[str, Any]]:
    """Argument dicts (parameter name -> value; methods exclude self).

    A parameter with a set partition is drawn class-first, recording
    ``hypothesis.event("<param>: <class>")``; one with a predicate partition
    draws a class (or, as often as each class, no class) and then a value
    satisfying it (see ``_steered``). Fixed-width draws stay inside the
    set requires admits when it is one, and a list p with ``requires distinct(p)``
    is drawn without duplicates; requires is never used as a filter (the runtime
    checks it). A parameter with a default is DEFAULT about a quarter of the
    time when ``defaults`` is true. With ``examples`` (explicit argument dicts),
    about a quarter of the draws is one of them.
    """
    decl = _callable(decl, spec)
    types = _param_types(decl, spec, tenv)
    infos = {info.param: info for info in partitions(decl, spec, tenv)}
    distinct = _distinct_params(decl, spec)
    builder = _Builder(spec, sizes)
    fields: dict[str, st.SearchStrategy[Any]] = {}
    for p, t in zip(decl.params, types, strict=True):
        info = infos.get(p.name)
        req = _requires_set(decl, p.name, t, spec) if is_fixed_width(t) else None
        if info is not None and info.kind == "set":
            s = sets.partition_strategy(_narrow(info.classes, req), t, label=p.name)
        elif req is not None:
            s = fixed_strategy(t, req)
        elif p.name in distinct and isinstance(t, ListT):
            s = builder.list_of(t.elem, sizes.max_list, unique=True, long=True)
        else:
            s = builder.build(t)
        if info is not None and info.kind == "predicate":
            unique = p.name in distinct
            s = _steered(info, t, s, builder, spec, _bind_tenv(tenv, spec), unique)
        if defaults and p.default is not None:
            s = _sometimes_default(s)
        fields[p.name] = s
    names = list(fields)
    explicit = st.sampled_from([dict(e) for e in examples]) if examples else None

    @st.composite
    def arguments(draw: st.DrawFn) -> dict[str, Any]:
        if explicit is not None and draw(st.integers(0, 3)) == 3:
            return dict(draw(explicit))
        return {name: draw(fields[name]) for name in names}

    return arguments()


def exhaustive_inputs(
    decl: ast.Callable_ | str,
    spec: Any,
    tenv: Tenv = None,
    limit: int = 65536,
) -> tuple[int, Iterator[dict[str, Any]]] | None:
    """Every admitted argument dict, when all parameters are fixed-width and there
    are at most ``limit`` of them: (count, iterator in a deterministic order).

    Each parameter ranges over ``admitted_set``. None when the domain is too large
    or a parameter is not fixed-width.
    """
    decl = _callable(decl, spec)
    types = _param_types(decl, spec, tenv)
    if not all(is_fixed_width(t) for t in types):
        return None
    infos = {info.param: info for info in partitions(decl, spec, tenv)}
    domains: list[BDDSet] = []
    for p in decl.params:
        s = admitted_set(decl, p.name, spec, tenv, info=infos.get(p.name))
        assert s is not None
        domains.append(s)
    count = 1
    for s in domains:
        count *= s.size
    if count > limit:
        return None
    names = [p.name for p in decl.params]

    def inputs() -> Iterator[dict[str, Any]]:
        values = [list(sets.enumerate_set(s)) for s in domains]
        for combo in itertools.product(*values):
            yield dict(zip(names, combo, strict=True))

    return count, inputs()
