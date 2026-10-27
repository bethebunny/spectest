"""The language's equalities on `Value`: canonical `==` and `same`, with a hash.

`canonical_eq` is the `==` of the language. It raises when a float, handle or error
sits anywhere inside either operand, because the checker keeps such `==` out of specs.
`same` is bit-identical equality on every kind. Maps and records compare without
regard to the order of their pairs in both.

An INT and a REAL are equal under `canonical_eq` when the real is a whole number of
the int's value, so promotion never changes the answer.
"""

from std.hash import Hasher, default_hasher

from wire import value as wv
from wire.value import Value


def _check_canonical(value: Value) raises:
    if value.kind in [wv.FLOAT, wv.HANDLE, wv.ERROR]:
        raise Error(t"a {value.kind} has no canonical equality")
    if value.kind in [wv.LIST, wv.TUPLE, wv.MAP, wv.OPTION, wv.RECORD]:
        for item in value.items():
            _check_canonical(item)


def _is_whole_real(real: Value, whole: Value) -> Bool:
    var as_real = real.as_real()
    return as_real.is_integer() and as_real.numerator == whole.as_bigint()


def _eq(a: Value, b: Value, *, canonical: Bool) -> Bool:
    if a.kind != b.kind:
        return canonical and (
            (a.kind == wv.INT and b.kind == wv.REAL and _is_whole_real(b, a))
            or (a.kind == wv.REAL and b.kind == wv.INT and _is_whole_real(a, b))
        )
    if not a.has_equal_parts(b):
        return False
    if a.kind in [wv.MAP, wv.RECORD]:
        return _pairs_match(a, b, canonical=canonical)
    for x, y in zip(a.items(), b.items()):
        if not _eq(x, y, canonical=canonical):
            return False
    return True


def _pairs_match(a: Value, b: Value, *, canonical: Bool) -> Bool:
    """Every (key, value) pair of `a` has a partner in `b`, and the counts agree.
    Keys are distinct within each side, so this is a bijection."""
    var b_pairs = b.pairs()
    for key, value in a.pairs():
        var found = False
        for other_key, other_value in b_pairs:
            if _eq(key, other_key, canonical=canonical):
                if not _eq(value, other_value, canonical=canonical):
                    return False
                found = True
                break
        if not found:
            return False
    return True


def canonical_eq(a: Value, b: Value) raises -> Bool:
    _check_canonical(a)
    _check_canonical(b)
    return _eq(a, b, canonical=True)


def same(a: Value, b: Value) -> Bool:
    return _eq(a, b, canonical=False)


def hash_same(value: Value, mut hasher: Some[Hasher]):
    value.hash_parts(hasher)
    if value.kind not in [wv.MAP, wv.RECORD]:
        for item in value.items():
            hash_same(item, hasher)
        return
    # Summed, so that the order of pairs doesn't matter.
    var total = UInt64(0)
    for key, item in value.pairs():
        var pair_hasher = default_hasher()
        hash_same(key, pair_hasher)
        hash_same(item, pair_hasher)
        total += UInt64(pair_hasher^.finish())
    total.__hash__(hasher)
