"""The language's equalities on `Value`: canonical `==` and `same`, with hashes.

`canonical_eq` is the `==` of the language. It raises when a float, handle or error
sits anywhere inside either operand, because the checker keeps such `==` out of specs.
`same` is bit-identical equality on every kind. Maps and records compare without
regard to the order of their pairs in both.

An INT and a REAL are equal under `canonical_eq` when the real is a whole number of
the int's value, so promotion never changes the answer.
"""

from std.hash import Hasher, hash

from wire.value import (
    Value,
    BOOL,
    INT,
    FLOAT,
    STRING,
    BYTES,
    LIST,
    TUPLE,
    MAP,
    OPTION,
    RECORD,
    ENUM,
    HANDLE,
    ERROR,
    REAL,
    QERR,
)


def _check_canonical(value: Value) raises:
    if value.kind == FLOAT or value.kind == HANDLE or value.kind == ERROR:
        raise Error(
            "a " + String(value.kind) + " has no canonical equality"
        )
    if value.kind == LIST or value.kind == TUPLE or value.kind == MAP or (
        value.kind == OPTION or value.kind == RECORD
    ):
        for i in range(value.item_count()):
            _check_canonical(value.item(i))


def _is_whole_real(real: Value, whole: Value) -> Bool:
    """`real` is a REAL with denominator 1 and numerator equal to the INT `whole`."""
    return real.item(1) == Value.int(1) and real.item(0) == whole


def _eq(a: Value, b: Value, canonical: Bool) -> Bool:
    if a.kind != b.kind:
        if canonical:
            if a.kind == INT and b.kind == REAL:
                return _is_whole_real(b, a)
            if a.kind == REAL and b.kind == INT:
                return _is_whole_real(a, b)
        return False
    if a.sub != b.sub or a.word != b.word:
        return False
    if Bool(a.heap) != Bool(b.heap):
        return False
    if not a.heap:
        return True
    ref pa = a.heap.value()[]
    ref pb = b.heap.value()[]
    if (
        pa.name != pb.name
        or pa.text != pb.text
        or pa.data != pb.data
        or pa.big != pb.big
        or len(pa.items) != len(pb.items)
    ):
        return False
    var n = len(pa.items)
    if a.kind == MAP or a.kind == RECORD:
        return _pairs_match(a, b, canonical)
    for i in range(n):
        if not _eq(pa.items[i][], pb.items[i][], canonical):
            return False
    return True


def _pairs_match(a: Value, b: Value, canonical: Bool) -> Bool:
    """Every (key, value) pair of `a` has a partner in `b`, and the counts agree.
    Keys are distinct within each side, so this is a bijection."""
    var n = a.count()
    for i in range(n):
        var key = a.item(2 * i)
        var found = False
        for j in range(n):
            if _eq(key, b.item(2 * j), canonical):
                if not _eq(a.item(2 * i + 1), b.item(2 * j + 1), canonical):
                    return False
                found = True
                break
        if not found:
            return False
    return True


def canonical_eq(a: Value, b: Value) raises -> Bool:
    _check_canonical(a)
    _check_canonical(b)
    return _eq(a, b, True)


def same(a: Value, b: Value) -> Bool:
    return _eq(a, b, False)


@fieldwise_init
struct _Pair(Hashable):
    """A map pair or record field, hashed as a unit so that pairs can be combined
    without regard to their order."""

    var key: Value
    var value: Value
    var canonical: Bool

    def __hash__(self, mut hasher: Some[Hasher]):
        _hash(self.key, self.canonical, hasher)
        _hash(self.value, self.canonical, hasher)


def _hash(value: Value, canonical: Bool, mut hasher: Some[Hasher]):
    var kind = value.kind
    if canonical and kind == REAL and value.item(1) == Value.int(1):
        # A whole real equals the int; hash it as one.
        _hash(value.item(0), canonical, hasher)
        return
    kind.__hash__(hasher)
    value.sub.__hash__(hasher)
    value.word.__hash__(hasher)
    if not value.heap:
        return
    ref p = value.heap.value()[]
    p.name.__hash__(hasher)
    p.text.__hash__(hasher)
    for b in p.data:
        b.__hash__(hasher)
    p.big.__hash__(hasher)
    if kind == MAP or kind == RECORD:
        var total = UInt64(0)
        for i in range(value.count()):
            total += UInt64(
                hash(_Pair(value.item(2 * i), value.item(2 * i + 1), canonical))
            )
        total.__hash__(hasher)
        return
    for item in p.items:
        _hash(item[], canonical, hasher)


def hash_canonical(value: Value, mut hasher: Some[Hasher]) raises:
    _check_canonical(value)
    _hash(value, True, hasher)


def hash_same(value: Value, mut hasher: Some[Hasher]):
    _hash(value, False, hasher)
