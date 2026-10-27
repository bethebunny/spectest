"""The language's `Ord` on `Value`.

Integers of every width and reals compare by value, an INT against a REAL
mathematically with -inf and +inf at the ends. `false < true`. Strings compare by code
point, which is the byte order of their UTF-8; bytes by unsigned byte. Tuples and
lists compare lexicographically, a proper prefix first. Every other kind raises.
"""

from wire import value as wv
from wire.value import Value


def is_ord(value: Value) -> Bool:
    if value.kind in [wv.BOOL, wv.INT, wv.REAL, wv.STRING, wv.BYTES]:
        return True
    return value.kind in [wv.LIST, wv.TUPLE] and all([is_ord(item) for item in value.items()])


def _compare[T: Comparable](a: T, b: T) -> Int:
    return -1 if a < b else (1 if b < a else 0)


def _compare_bytes(a: Span[UInt8, _], b: Span[UInt8, _]) -> Int:
    for x, y in zip(a, b):
        if x != y:
            return _compare(x, y)
    return _compare(len(a), len(b))


def compare(a: Value, b: Value) raises -> Int:
    if a.kind in [wv.INT, wv.REAL] and b.kind in [wv.INT, wv.REAL]:
        return _compare(a.as_real(), b.as_real())
    if a.kind != b.kind:
        raise Error(t"cannot order a {a.kind} against a {b.kind}")
    if a.kind == wv.BOOL:
        return _compare(Int(a.as_bool()), Int(b.as_bool()))
    if a.kind == wv.STRING:
        return _compare_bytes(a.text().as_bytes(), b.text().as_bytes())
    if a.kind == wv.BYTES:
        return _compare_bytes(Span(a.data()), Span(b.data()))
    if a.kind in [wv.LIST, wv.TUPLE]:
        for x, y in zip(a.items(), b.items()):
            var c = compare(x, y)
            if c != 0:
                return c
        return _compare(a.count(), b.count())
    raise Error(t"a {a.kind} has no order")
