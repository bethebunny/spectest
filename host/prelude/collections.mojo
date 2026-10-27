"""Collections, options and `eq`.

`sorted` is a stable bottom-up merge sort of our own, not a library sort: specs use it
to judge sorting code. Element equality in `is_permutation`, `is_subsequence`,
`distinct` and `index_of` is `same`: floats by bits, maps without regard to order.
"""

from std.hash import default_hasher

from numeric.bigint import BigInt
from numeric.floats import is_nan as fl_is_nan, to_real
from prelude.util import codepoint_count, fail, int_of, list_items
from wire.equality import hash_same, same
from wire.order import compare, is_ord
from wire.value import Value

comptime RANGE_LIMIT = 10_000_000


def length(x: Value) raises -> Value:
    """Elements of a list, Unicode scalars of a string, bytes, or pairs of a map."""
    if x.kind == .LIST or x.kind == .TUPLE or x.kind == .MAP:
        return Value.int(x.count())
    if x.kind == .BYTES:
        return Value.int(len(x.data()))
    if x.kind == .STRING:
        return Value.int(codepoint_count(x.text()))
    raise fail("len", t"expected a collection, got {x}")


def _check_ordered(items: List[Value], who: String) raises:
    for item in items:
        if not is_ord(item):
            raise fail(who, t"{item} is not ordered (floats compare after real())")


def _cmp(a: Value, b: Value, who: String) raises -> Int:
    try:
        return compare(a, b)
    except e:
        raise fail(who, String(e))


def _merge_sort(items: List[Value]) raises -> List[Value]:
    var out = items.copy()
    var n = len(out)
    var width = 1
    while width < n:
        var merged = List[Value](capacity=n)
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            while i < mid and j < hi:
                if _cmp(out[i], out[j], "sorted") <= 0:
                    merged.append(out[i].copy())
                    i += 1
                else:
                    merged.append(out[j].copy())
                    j += 1
            while i < mid:
                merged.append(out[i].copy())
                i += 1
            while j < hi:
                merged.append(out[j].copy())
                j += 1
            lo += 2 * width
        out = merged^
        width *= 2
    return out^


def sorted(xs: Value) raises -> Value:
    var items = list_items(xs, "sorted")
    _check_ordered(items, "sorted")
    return Value.list(_merge_sort(items))


def is_sorted(xs: Value) raises -> Value:
    var items = list_items(xs, "is_sorted")
    _check_ordered(items, "is_sorted")
    for i in range(1, len(items)):
        if _cmp(items[i - 1], items[i], "is_sorted") > 0:
            return Value.bool(False)
    return Value.bool(True)


def _hash(v: Value) -> UInt64:
    var h = default_hasher()
    hash_same(v, h)
    return UInt64(h^.finish())


def is_permutation(a: Value, b: Value) raises -> Value:
    var xs = list_items(a, "is_permutation")
    var ys = list_items(b, "is_permutation")
    if len(xs) != len(ys):
        return Value.bool(False)
    var buckets = Dict[UInt64, List[Int]]()
    for j, y in enumerate(ys):
        var key = _hash(y)
        if key in buckets:
            buckets[key].append(j)
        else:
            buckets[key] = [j]
    var used = List[Bool](length=len(ys), fill=False)
    for x in xs:
        var key = _hash(x)
        if key not in buckets:
            return Value.bool(False)
        var found = False
        for j in buckets[key]:
            if not used[j] and same(x, ys[j]):
                used[j] = True
                found = True
                break
        if not found:
            return Value.bool(False)
    return Value.bool(True)


def is_subsequence(a: Value, b: Value) raises -> Value:
    var xs = list_items(a, "is_subsequence")
    var ys = list_items(b, "is_subsequence")
    var i = 0
    for y in ys:
        if i == len(xs):
            break
        if same(xs[i], y):
            i += 1
    return Value.bool(i == len(xs))


def distinct(xs: Value) raises -> Value:
    var items = list_items(xs, "distinct")
    var seen = Dict[UInt64, List[Int]]()
    for i, item in enumerate(items):
        var key = _hash(item)
        if key in seen:
            for j in seen[key]:
                if same(item, items[j]):
                    return Value.bool(False)
            seen[key].append(i)
        else:
            seen[key] = [i]
    return Value.bool(True)


def index_of(xs: Value, x: Value) raises -> Value:
    var items = list_items(xs, "index_of")
    for i, item in enumerate(items):
        if same(item, x):
            return Value.int(i)
    raise fail("index_of", t"{x} is not in the list")


def keys(m: Value) raises -> Value:
    if m.kind != .MAP:
        raise fail("keys", t"expected a map, got {m}")
    return Value.list([m.item(2 * i) for i in range(m.count())])


def values(m: Value) raises -> Value:
    if m.kind != .MAP:
        raise fail("values", t"expected a map, got {m}")
    return Value.list([m.item(2 * i + 1) for i in range(m.count())])


def range_(a: Value, b: Value) raises -> Value:
    """The integers a, a+1, ..., b-1 (empty when b <= a)."""
    var lo = int_of(a, "range")
    var hi = int_of(b, "range")
    if hi - lo > BigInt(RANGE_LIMIT):
        raise fail("range", t"range({lo}, {hi}) has more than {RANGE_LIMIT} elements")
    var out: List[Value] = []
    var small_lo = a.small_int()
    var small_hi = b.small_int()
    if small_lo is not None and small_hi is not None:
        for k in range(small_lo.value(), small_hi.value()):
            out.append(Value.int(k))
    else:
        var k = lo.copy()
        while k < hi:
            out.append(Value.int(k.copy()))
            k = k + BigInt(1)
    return Value.list(out^)


def some(x: Value) -> Value:
    return Value.some(x.copy())


def _option(o: Value, who: String) raises:
    if o.kind != .OPTION:
        raise fail(who, t"expected an option, got {o}")


def is_some(o: Value) raises -> Value:
    _option(o, "is_some")
    return Value.bool(o.count() == 1)


def is_none(o: Value) raises -> Value:
    _option(o, "is_none")
    return Value.bool(o.count() == 0)


def unwrap(o: Value) raises -> Value:
    _option(o, "unwrap")
    if o.count() == 0:
        raise fail("unwrap", "the option is none")
    return o.item(0)


comptime FLOAT_BITS = 0
comptime FLOAT_IEEE = 1
comptime FLOAT_NAN_ANY = 2


def _eq_floats(a: Value, b: Value, mode: Int) raises -> Bool:
    if a.float_format() != b.float_format():
        return False
    if mode == FLOAT_BITS:
        return a.float_bits() == b.float_bits()
    var f = a.float_format()
    var a_nan = fl_is_nan(f, a.float_bits())
    var b_nan = fl_is_nan(f, b.float_bits())
    if a_nan or b_nan:
        return mode == FLOAT_NAN_ANY and a_nan and b_nan
    if mode == FLOAT_IEEE:
        return to_real(f, a.float_bits()) == to_real(f, b.float_bits())
    return a.float_bits() == b.float_bits()


def _eq_unordered(a: Value, b: Value, mode: Int) raises -> Bool:
    var n = a.count()
    var used = List[Bool](length=n, fill=False)
    for i in range(n):
        var found = False
        for j in range(n):
            if not used[j] and _eq(a.item(i), b.item(j), mode, True):
                used[j] = True
                found = True
                break
        if not found:
            return False
    return True


def _eq(a: Value, b: Value, mode: Int, ignore_order: Bool) raises -> Bool:
    var k = a.kind
    if k == .HANDLE or k == .ERROR or b.kind == .HANDLE or b.kind == .ERROR:
        raise fail("eq", t"cannot compare {k if (k == .HANDLE or k == .ERROR) else b.kind} values")
    if (k == .INT or k == .REAL) and (b.kind == .INT or b.kind == .REAL):
        return compare(a, b) == 0
    if k != b.kind:
        return False
    if k == .FLOAT:
        return _eq_floats(a, b, mode)
    if k == .LIST or k == .TUPLE:
        if a.count() != b.count():
            return False
        if ignore_order:
            return _eq_unordered(a, b, mode)
        for i in range(a.count()):
            if not _eq(a.item(i), b.item(i), mode, ignore_order):
                return False
        return True
    if k == .OPTION:
        if a.count() != b.count():
            return False
        return a.count() == 0 or _eq(a.item(0), b.item(0), mode, ignore_order)
    if k == .MAP:
        if a.count() != b.count():
            return False
        for i in range(a.count()):
            var found = False
            for j in range(b.count()):
                if _eq(a.item(2 * i), b.item(2 * j), mode, ignore_order):
                    if not _eq(a.item(2 * i + 1), b.item(2 * j + 1), mode, ignore_order):
                        return False
                    found = True
                    break
            if not found:
                return False
        return True
    if k == .RECORD:
        if a.name() != b.name() or a.count() != b.count():
            return False
        for i in range(a.item_count()):
            if i % 2 == 0:
                if a.item(i) != b.item(i):
                    return False
            elif not _eq(a.item(i), b.item(i), mode, ignore_order):
                return False
        return True
    return a == b


def eq(a: Value, b: Value, float_mode: Optional[Value], order: Optional[Value]) raises -> Value:
    var mode = FLOAT_BITS
    if float_mode is not None:
        var m = float_mode.value().copy()
        var text = m.text() if m.kind == .STRING else ""
        if text == "bits":
            mode = FLOAT_BITS
        elif text == "ieee":
            mode = FLOAT_IEEE
        elif text == "nan_any":
            mode = FLOAT_NAN_ANY
        else:
            raise fail("eq", t"float= must be one of bits, ieee, nan_any, got {m}")
    var ignore = False
    if order is not None:
        var o = order.value().copy()
        var text = o.text() if o.kind == .STRING else ""
        if text == "ignore":
            ignore = True
        elif text != "exact":
            raise fail("eq", t"order= must be one of exact, ignore, got {o}")
    return Value.bool(_eq(a, b, mode, ignore))
