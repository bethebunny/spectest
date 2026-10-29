"""The language's equalities on `Value`: canonical `==` and `same`, with a hash.

`canonical_eq` is the `==` of the language. It raises when a float, handle or error
sits anywhere inside either operand, because the checker keeps such `==` out of specs.
`same` is bit-identical equality on every kind. Maps and records compare without
regard to the order of their pairs in both.

An Int and a Real are equal under `canonical_eq` when the real is a whole number of
the int's value, so promotion never changes the answer.
"""

from std.hash import Hasher, default_hasher

from value.value import Kind, Value


def _check_canonical(value: Value) raises:
    if value.kind in [Kind.Float, Kind.Handle, Kind.Error]:
        raise Error(t"a {value.kind} has no canonical equality")
    if value.kind in [Kind.List, Kind.Tuple, Kind.Map, Kind.Option, Kind.Record]:
        for item in value.items():
            _check_canonical(item)


def _eq(a: Value, b: Value, *, canonical: Bool) -> Bool:
    if a.kind != b.kind:
        var numbers = a.kind in [Kind.Int, Kind.Real] and b.kind in [Kind.Int, Kind.Real]
        return canonical and numbers and a.as_real() == b.as_real()
    if not a.has_equal_parts(b):
        return False
    if a.kind.holds_pairs():
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
        var partners = [v.copy() for k, v in b_pairs if _eq(key, k, canonical=canonical)]
        if not partners or not _eq(value, partners[0], canonical=canonical):
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
    if not value.kind.holds_pairs():
        for item in value.items():
            hash_same(item, hasher)
        return
    # Summed, so that the order of pairs doesn't matter.
    var total = UInt64(0)
    for key, item in value.pairs():
        var pair_hasher = default_hasher()
        hash_same(key, pair_hasher)
        hash_same(item, pair_hasher)
        total += UInt64(pair_hasher.finish())
    total.__hash__(hasher)


def same_hash(value: Value) -> UInt64:
    """A hash that agrees with `same`."""
    var hasher = default_hasher()
    hash_same(value, hasher)
    return UInt64(hasher.finish())
