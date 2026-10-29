"""The language's `Ord` on `Value`.

Integers of every width and reals compare by value, an Int against a Real
mathematically with -inf and +inf at the ends. `false < true`. Strings compare by code
point, which is the byte order of their UTF-8; bytes by unsigned byte. Tuples and
lists compare lexicographically, a proper prefix first. Every other kind raises.
"""

from value.value import Kind, Value


def is_ord(value: Value) -> Bool:
    match value.kind:
        case .Bool | .Int | .Real | .String | .Bytes:
            return True
        case .List | .Tuple:
            return all([is_ord(item) for item in value.items()])
        case _:
            return False


def _compare[T: Comparable](a: T, b: T) -> Int:
    return -1 if a < b else (1 if b < a else 0)


def _compare_bytes(a: Span[UInt8, _], b: Span[UInt8, _]) -> Int:
    for x, y in zip(a, b):
        if x != y:
            return _compare(x, y)
    return _compare(len(a), len(b))


def compare(a: Value, b: Value) raises -> Int:
    if a.kind in [Kind.Int, Kind.Real] and b.kind in [Kind.Int, Kind.Real]:
        return _compare(a.as_real(), b.as_real())
    if a.kind != b.kind:
        raise Error(t"cannot order a {a.kind} against a {b.kind}")
    match a.kind:
        case .Bool:
            return _compare(Int(a.as_bool()), Int(b.as_bool()))
        case .String:
            return _compare(a.text(), b.text())
        case .Bytes:
            return _compare_bytes(a.data(), b.data())
        case .List | .Tuple:
            for x, y in zip(a.items(), b.items()):
                var c = compare(x, y)
                if c != 0:
                    return c
            return _compare(a.count(), b.count())
        case _:
            raise Error(t"a {a.kind} has no order")
