"""The language's `Ord` on `Value`.

Integers of every width and reals compare by value, an INT against a REAL
mathematically with -inf and +inf at the ends. `false < true`. Strings compare by code
point, which is the byte order of their UTF-8; bytes by unsigned byte. Tuples and
lists compare lexicographically, a proper prefix first. Every other kind raises.
"""

from numeric.bigint import BigInt
from wire.value import (
    Value,
    BOOL,
    INT,
    STRING,
    BYTES,
    LIST,
    TUPLE,
    REAL,
)


def is_ord(value: Value) -> Bool:
    var kind = value.kind
    if kind == BOOL or kind == INT or kind == REAL or kind == STRING or kind == BYTES:
        return True
    if kind == LIST or kind == TUPLE:
        for i in range(value.item_count()):
            if not is_ord(value.item(i)):
                return False
        return True
    return False


def _sign(x: Int, y: Int) -> Int:
    if x < y:
        return -1
    if x > y:
        return 1
    return 0


def _compare_big(a: BigInt, b: BigInt) -> Int:
    if a < b:
        return -1
    if b < a:
        return 1
    return 0


def _is_number(value: Value) -> Bool:
    return value.kind == INT or value.kind == REAL


def _numerator(value: Value) -> BigInt:
    return value.as_bigint() if value.kind == INT else value.item(0).as_bigint()


def _denominator(value: Value) -> BigInt:
    return BigInt(1) if value.kind == INT else value.item(1).as_bigint()


def _compare_numbers(a: Value, b: Value) -> Int:
    var na = _numerator(a)
    var da = _denominator(a)
    var nb = _numerator(b)
    var db = _denominator(b)
    # An infinity has denominator 0. Rank -inf, finite, +inf as -1, 0, 1.
    var ra = na.sign() if da.is_zero() else 0
    var rb = nb.sign() if db.is_zero() else 0
    if ra != rb:
        return _sign(ra, rb)
    if ra != 0:
        return 0
    return _compare_big(na * db, nb * da)


def _compare_bytes(a: Span[UInt8, _], b: Span[UInt8, _]) -> Int:
    var n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    return _sign(len(a), len(b))


def compare(a: Value, b: Value) raises -> Int:
    if _is_number(a) and _is_number(b):
        return _compare_numbers(a, b)
    if a.kind != b.kind:
        raise Error(
            "cannot order a " + String(a.kind) + " against a " + String(b.kind)
        )
    var kind = a.kind
    if kind == BOOL:
        return _sign(Int(a.as_bool()), Int(b.as_bool()))
    if kind == STRING:
        return _compare_bytes(a.text().as_bytes(), b.text().as_bytes())
    if kind == BYTES:
        return _compare_bytes(Span(a.data()), Span(b.data()))
    if kind == LIST or kind == TUPLE:
        var n = min(a.count(), b.count())
        for i in range(n):
            var c = compare(a.item(i), b.item(i))
            if c != 0:
                return c
        return _sign(a.count(), b.count())
    raise Error("a " + String(kind) + " has no order")
