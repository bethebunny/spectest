"""Collections, options, text, identity, and structural equality.

Lists are tuples, maps are MapValues, options are None or Some (see
spectest.values). Element equality in ``is_permutation``, ``is_subsequence``,
``distinct`` and ``index_of`` is ``same``: floats by bits, handles by
identity. Orderings cover ints, reals, bools (false < true), strings (by code point),
bytes (by byte) and tuples and lists (lexicographic); floats have none.
"""

from __future__ import annotations

import builtins
import itertools
import operator
from collections import Counter
from collections.abc import Callable, Hashable, Sequence
from fractions import Fraction
from typing import Any

from spectest.prelude import floats, reals
from spectest.values import (
    EvalError,
    FloatValue,
    Handle,
    MapValue,
    QError,
    RecordValue,
    Some,
    is_infinity,
)

FLOAT_MODES = ("bits", "ieee", "nan_any")
ORDER_MODES = ("exact", "ignore")
RANGE_LIMIT = 10_000_000


class _Distinct:
    """A key equal only to itself: an IEEE NaN under ``float="ieee"``."""

    __slots__ = ()


class _Keyer:
    """Builds hashable keys whose equality is the requested structural equality."""

    def __init__(
        self,
        fn: str,
        float_mode: str = "bits",
        order: str = "exact",
        ctx: Any = None,
        observe_handles: bool = False,
    ) -> None:
        self.fn = fn
        self.float_mode = float_mode
        self.order = order
        self.ctx = ctx
        self.observe_handles = observe_handles
        self.active: set[int] = set()

    def key(self, v: Any) -> Hashable:
        if isinstance(v, FloatValue):
            return self._float_key(v)
        if isinstance(v, (tuple, list)):
            keys = [self.key(x) for x in v]
            if self.order == "ignore":
                return ("bag", frozenset(Counter(keys).items()))
            return ("seq", tuple(keys))
        if v is None:
            return ("none",)
        if isinstance(v, Some):
            return ("some", self.key(v.value))
        if isinstance(v, MapValue):
            return ("map", frozenset((self.key(k), self.key(x)) for k, x in v.items))
        if isinstance(v, RecordValue):
            return ("rec", v.name, tuple((n, self.key(x)) for n, x in v.fields))
        if isinstance(v, Handle):
            return self._handle_key(v) if self.observe_handles else ("handle", v)
        if isinstance(v, QError):
            return ("qerr", v.steps, v.nans)
        if isinstance(v, bool):
            return ("bool", v)
        if isinstance(v, (int, Fraction)):
            return ("num", v)
        if is_infinity(v):
            return ("inf", v.sign)
        if isinstance(v, str):
            return ("str", v)
        if isinstance(v, bytes):
            return ("bytes", v)
        raise EvalError(f"{self.fn}: cannot compare {v!r}")

    def _float_key(self, v: FloatValue) -> Hashable:
        if self.float_mode == "bits":
            return ("float", v.fmt, v.bits)
        if floats.is_nan(v):
            return ("nan", v.fmt) if self.float_mode == "nan_any" else _Distinct()
        if self.float_mode == "ieee" and floats.is_zero(v):
            return ("float", v.fmt, 0)
        return ("float", v.fmt, v.bits)

    def _handle_key(self, h: Handle) -> Hashable:
        observe = getattr(self.ctx, "fields", None)
        if observe is None:
            raise EvalError(f"{self.fn}: cannot compare model handles without observing them")
        if h.id in self.active:
            raise EvalError(f"{self.fn}: {h!r} contains itself")
        self.active.add(h.id)
        try:
            fields = observe(h)
            items = tuple((name, self.key(fields[name])) for name in builtins.sorted(fields))
        finally:
            self.active.discard(h.id)
        return ("model", h.model, items)


def _seq(xs: Any, fn: str) -> Sequence[Any]:
    if not isinstance(xs, (tuple, list)):
        raise EvalError(f"{fn}: expected a list, got {xs!r}")
    return xs


def _map(m: Any, fn: str) -> MapValue:
    if not isinstance(m, MapValue):
        raise EvalError(f"{fn}: expected a map, got {m!r}")
    return m


def len(x: Any) -> int:
    """Length of a list, string (Unicode scalars), byte string or map."""
    if isinstance(x, (tuple, list, str, bytes)):
        return builtins.len(x)
    if isinstance(x, MapValue):
        return builtins.len(x.items)
    raise EvalError(f"len: expected a collection, got {x!r}")


def _is_number(x: Any) -> bool:
    return (isinstance(x, (int, Fraction)) and not isinstance(x, bool)) or is_infinity(x)


def compare_values(a: Any, b: Any, fn: str = "compare", *, promote: bool = False) -> int:
    """The total order on ordered values: -1, 0 or 1.

    With ``promote``, top-level float operands are promoted to reals first, as
    ``<`` in clauses does (NaN raises EvalError); floats nested in tuples
    never compare.
    """
    if promote and (isinstance(a, FloatValue) or isinstance(b, FloatValue)):
        return reals.compare(a, b, fn)
    if isinstance(a, FloatValue) or isinstance(b, FloatValue):
        raise EvalError(f"{fn}: floats have no total order; compare real(x) instead")
    if isinstance(a, bool) and isinstance(b, bool):
        return (a > b) - (a < b)
    if _is_number(a) and _is_number(b):
        return reals.compare(a, b, fn)
    if (isinstance(a, str) and isinstance(b, str)) or (
        isinstance(a, bytes) and isinstance(b, bytes)
    ):
        return (a > b) - (a < b)
    if isinstance(a, (tuple, list)) and isinstance(b, (tuple, list)):
        for x, y in zip(a, b):
            c = compare_values(x, y, fn)
            if c:
                return c
        return (builtins.len(a) > builtins.len(b)) - (builtins.len(a) < builtins.len(b))
    raise EvalError(f"{fn}: {a!r} and {b!r} are not ordered")


def _builtin_orderable(xs: Sequence[Any]) -> bool:
    if all(isinstance(x, int) and not isinstance(x, bool) for x in xs):
        return True
    return all(isinstance(x, str) for x in xs) or all(isinstance(x, bytes) for x in xs)


def _check_ordered(x: Any, fn: str) -> None:
    if isinstance(x, FloatValue):
        raise EvalError(f"{fn}: floats have no total order; compare real(x) instead")
    if isinstance(x, (tuple, list)):
        for y in x:
            _check_ordered(y, fn)
    elif not (isinstance(x, (int, Fraction, str, bytes)) or is_infinity(x)):
        raise EvalError(f"{fn}: {x!r} is not ordered")


def _merge_sort(xs: Sequence[Any], le: Callable[[Any, Any], bool]) -> list[Any]:
    """A stable bottom-up merge sort.

    ``sorted`` uses it instead of Python's own sort, which may be the very
    implementation a spec judges.
    """
    out = list(xs)
    n, width = builtins.len(out), 1
    while width < n:
        merged: list[Any] = []
        for lo in builtins.range(0, n, 2 * width):
            a, b = out[lo : lo + width], out[lo + width : lo + 2 * width]
            i = j = 0
            while i < builtins.len(a) and j < builtins.len(b):
                if le(a[i], b[j]):
                    merged.append(a[i])
                    i += 1
                else:
                    merged.append(b[j])
                    j += 1
            merged += a[i:]
            merged += b[j:]
        out = merged
        width *= 2
    return out


def sorted(xs: Any) -> tuple[Any, ...]:
    """The list in non-decreasing order (stable)."""
    xs = _seq(xs, "sorted")
    if _builtin_orderable(xs):
        return tuple(_merge_sort(xs, operator.le))
    _check_ordered(xs, "sorted")
    return tuple(_merge_sort(xs, lambda a, b: compare_values(a, b, "sorted") <= 0))


def is_sorted(xs: Any) -> bool:
    """Is the list non-decreasing?"""
    xs = _seq(xs, "is_sorted")
    if _builtin_orderable(xs):
        return all(a <= b for a, b in itertools.pairwise(xs))
    _check_ordered(xs, "is_sorted")
    return all(compare_values(a, b, "is_sorted") <= 0 for a, b in itertools.pairwise(xs))


def is_permutation(a: Any, b: Any) -> bool:
    """Multiset equality of two lists (elements compared with ``same``)."""
    a, b = _seq(a, "is_permutation"), _seq(b, "is_permutation")
    if builtins.len(a) != builtins.len(b):
        return False
    k = _Keyer("is_permutation")
    return Counter(map(k.key, a)) == Counter(map(k.key, b))


def is_subsequence(a: Any, b: Any) -> bool:
    """Do a's elements occur in b in order (not necessarily contiguously)?"""
    a, b = _seq(a, "is_subsequence"), _seq(b, "is_subsequence")
    k = _Keyer("is_subsequence")
    want = [k.key(x) for x in a]
    i = 0
    for y in b:
        if i == builtins.len(want):
            break
        if k.key(y) == want[i]:
            i += 1
    return i == builtins.len(want)


def distinct(xs: Any) -> bool:
    """Are the list's elements pairwise different?"""
    xs = _seq(xs, "distinct")
    k = _Keyer("distinct")
    return builtins.len(set(map(k.key, xs))) == builtins.len(xs)


def index_of(xs: Any, x: Any) -> int:
    """The first index of x in xs; EvalError when absent."""
    xs = _seq(xs, "index_of")
    k = _Keyer("index_of")
    want = k.key(x)
    for i, y in enumerate(xs):
        if k.key(y) == want:
            return i
    raise EvalError(f"index_of: {x!r} is not in the list")


def keys(m: Any) -> tuple[Any, ...]:
    """The map's keys, in insertion order."""
    return tuple(k for k, _ in _map(m, "keys").items)


def values(m: Any) -> tuple[Any, ...]:
    """The map's values, in insertion order."""
    return tuple(v for _, v in _map(m, "values").items)


def range(a: Any, b: Any) -> tuple[int, ...]:
    """The integers a, a+1, ..., b-1 (empty when b <= a)."""
    for x in (a, b):
        if isinstance(x, bool) or not isinstance(x, int):
            raise EvalError(f"range: expected integers, got {x!r}")
    if b - a > RANGE_LIMIT:
        raise EvalError(f"range: range({a}, {b}) has more than {RANGE_LIMIT} elements")
    return tuple(builtins.range(a, b))


def some(x: Any) -> Some:
    return Some(x)


def _option(o: Any, fn: str) -> Any:
    if o is not None and not isinstance(o, Some):
        raise EvalError(f"{fn}: expected an option, got {o!r}")
    return o


def is_some(o: Any) -> bool:
    return _option(o, "is_some") is not None


def is_none(o: Any) -> bool:
    return _option(o, "is_none") is None


def unwrap(o: Any) -> Any:
    """The value of some(x); EvalError on none."""
    if _option(o, "unwrap") is None:
        raise EvalError("unwrap: the option is none")
    return o.value


_TRAIL = (0x80, 0xBF)


def _utf8_lead(lead: int) -> tuple[tuple[int, int], int] | None:
    """Table 3-7 of the Unicode Standard for a lead byte of 0x80 or more: the range of the
    second byte and the number of trailing bytes, or None when no sequence starts with it."""
    if 0xC2 <= lead <= 0xDF:
        return _TRAIL, 1
    if lead == 0xE0:
        return (0xA0, 0xBF), 2
    if 0xE1 <= lead <= 0xEC or lead in (0xEE, 0xEF):
        return _TRAIL, 2
    if lead == 0xED:
        return (0x80, 0x9F), 2
    if lead == 0xF0:
        return (0x90, 0xBF), 3
    if 0xF1 <= lead <= 0xF3:
        return _TRAIL, 3
    if lead == 0xF4:
        return (0x80, 0x8F), 3
    return None


def valid_utf8(b: Any) -> bool:
    """Is the byte string well-formed UTF-8 (no surrogates, overlongs or values past U+10FFFF)?

    It follows the Unicode Standard's Table 3-7 (well-formed UTF-8 byte
    sequences) byte by byte, without any codec, so it can judge a UTF-8 codec.
    """
    if not isinstance(b, (bytes, bytearray)):
        raise EvalError(f"valid_utf8: expected bytes, got {b!r}")
    if b.isascii():
        return True
    i, n = 0, builtins.len(b)
    while i < n:
        lead = b[i]
        if lead < 0x80:
            i += 1
            continue
        form = _utf8_lead(lead)
        if form is None:
            return False
        (lo, hi), trail = form
        if i + trail >= n or not lo <= b[i + 1] <= hi:
            return False
        if any(not 0x80 <= b[i + k] <= 0xBF for k in builtins.range(2, trail + 1)):
            return False
        i += 1 + trail
    return True


def codepoints(s: Any) -> tuple[int, ...]:
    """The Unicode scalar values of a string, in order."""
    if not isinstance(s, str):
        raise EvalError(f"codepoints: expected a string, got {s!r}")
    return tuple(map(ord, s))


def same(a: Any, b: Any) -> bool:
    """Bit-identical structural equality (see floats.same)."""
    return floats.same(a, b)


def eq(a: Any, b: Any, *, float: str = "bits", order: str = "exact", ctx: Any = None) -> bool:
    """Structural equality with explicit knobs.

    ``float``: "bits" (same bit pattern), "ieee" (IEEE equality: NaN equals
    nothing, +0 equals -0) or "nan_any" (any two NaNs of a format are equal,
    other floats by bits). ``order``: "exact", or "ignore" to compare every
    list, at every depth, as a multiset. Maps never depend on order. Handles
    are compared through ``ctx.fields(handle) -> dict`` when ctx provides it.
    """
    if float not in FLOAT_MODES:
        raise EvalError(f"eq: float= must be one of {', '.join(FLOAT_MODES)}, got {float!r}")
    if order not in ORDER_MODES:
        raise EvalError(f"eq: order= must be one of {', '.join(ORDER_MODES)}, got {order!r}")
    k = _Keyer("eq", float, order, ctx, observe_handles=True)
    return k.key(a) == k.key(b)


def _handle(h: Any, fn: str) -> Handle:
    if not isinstance(h, Handle):
        raise EvalError(f"{fn}: expected a model handle, got {h!r}")
    return h


def _ctx(ctx: Any, fn: str) -> Any:
    if ctx is None:
        raise EvalError(f"{fn}: needs an evaluation context")
    return ctx


def fresh(h: Any, *, ctx: Any = None) -> bool:
    """Was the handle's object created by the call under test?"""
    return bool(_ctx(ctx, "fresh").is_fresh(_handle(h, "fresh")))


def same_object(a: Any, b: Any, *, ctx: Any = None) -> bool:
    c = _ctx(ctx, "same_object")
    return bool(c.same_object(_handle(a, "same_object"), _handle(b, "same_object")))


def shares_memory(a: Any, b: Any, *, ctx: Any = None) -> bool:
    c = _ctx(ctx, "shares_memory")
    return bool(c.shares_memory(_handle(a, "shares_memory"), _handle(b, "shares_memory")))
