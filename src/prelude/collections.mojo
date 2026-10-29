"""Collections, options and `eq`.

Element equality in `is_permutation`, `is_subsequence`, `distinct` and `index_of` is
`same`: floats by bits, maps without regard to order.
"""

from std.collections import Counter, Set
from std.hash import Hasher

from value.bigint import BigInt
from value.equality import hash_same, same
from value.floats import is_nan
from value.order import compare, is_ord
from value.value import Kind, Value

from prelude.floatfns import ieee_equal
from prelude.util import fail, int_of, list_items

comptime RANGE_LIMIT = 10_000_000


@fieldwise_init
struct _Same(Copyable, Equatable, Hashable):
    """A value as a key that compares with `same`."""

    var value: Value

    def __eq__(self, other: Self) -> Bool:
        return same(self.value, other.value)

    def __hash__(self, mut hasher: Some[Hasher]):
        hash_same(self.value, hasher)


def _keys(items: List[Value]) -> List[_Same]:
    return [_Same(item.copy()) for item in items]


def length(x: Value) raises -> Value:
    """Elements of a list, Unicode scalars of a string, bytes, or pairs of a map."""
    match x.kind:
        case .List | .Tuple | .Map:
            return Value.int(x.count())
        case .Bytes:
            return Value.int(len(x.data()))
        case .String:
            return Value.int(x.text().count_codepoints())
        case _:
            raise fail("len", t"expected a collection, got {x}")


def _check_ordered(items: List[Value], who: String) raises:
    for item in items:
        if not is_ord(item):
            raise fail(who, t"{item} is not ordered (floats compare after real())")


def _compare(a: Value, b: Value, who: String) raises -> Int:
    try:
        return compare(a, b)
    except e:
        raise fail(who, String(e))


def _before(a: Value, b: Value) -> Bool:
    # A sort comparator can't raise, so `sorted` compares the sorted neighbours again.
    try:
        return compare(a, b) < 0
    except:
        return False


def sorted(xs: Value) raises -> Value:
    var items = list_items(xs, "sorted")
    _check_ordered(items, "sorted")
    sort[stable=True](items, _before)
    for i in range(1, len(items)):
        _ = _compare(items[i - 1], items[i], "sorted")
    return Value.list(items^)


def is_sorted(xs: Value) raises -> Value:
    var items = list_items(xs, "is_sorted")
    _check_ordered(items, "is_sorted")
    for i in range(1, len(items)):
        if _compare(items[i - 1], items[i], "is_sorted") > 0:
            return Value.bool(False)
    return Value.bool(True)


def is_permutation(a: Value, b: Value) raises -> Value:
    var xs = list_items(a, "is_permutation")
    var ys = list_items(b, "is_permutation")
    return Value.bool(Counter[_Same](_keys(xs)) == Counter[_Same](_keys(ys)))


def is_subsequence(a: Value, b: Value) raises -> Value:
    var xs = list_items(a, "is_subsequence")
    var ys = list_items(b, "is_subsequence")
    var matched = 0
    for y in ys:
        if matched == len(xs):
            break
        if same(xs[matched], y):
            matched += 1
    return Value.bool(matched == len(xs))


def distinct(xs: Value) raises -> Value:
    var items = list_items(xs, "distinct")
    return Value.bool(len(Set[_Same](_keys(items))) == len(items))


def index_of(xs: Value, x: Value) raises -> Value:
    if case .Some(at) = _keys(list_items(xs, "index_of")).try_index(_Same(x.copy())):
        return Value.int(at)
    raise fail("index_of", t"{x} is not in the list")


def keys(m: Value) raises -> Value:
    if m.kind != .Map:
        raise fail("keys", t"expected a map, got {m}")
    return Value.list(m.keys())


def values(m: Value) raises -> Value:
    if m.kind != .Map:
        raise fail("values", t"expected a map, got {m}")
    return Value.list(m.values())


def range_(a: Value, b: Value) raises -> Value:
    """The integers a, a+1, ..., b-1 (empty when b <= a)."""
    var lo = int_of(a, "range")
    var hi = int_of(b, "range")
    if hi - lo > BigInt(RANGE_LIMIT):
        raise fail("range", t"range({lo}, {hi}) has more than {RANGE_LIMIT} elements")
    if case (.Some(start), .Some(end)) = (a.small_int(), b.small_int()):
        return Value.list([Value.int(k) for k in range(start, end)])
    var out: List[Value] = []
    var k = lo^
    while k < hi:
        out.append(Value.int(k.copy()))
        k = k + 1
    return Value.list(out^)


def some(x: Value) -> Value:
    return Value.some(x.copy())


def _check_option(o: Value, who: String) raises:
    if o.kind != .Option:
        raise fail(who, t"expected an option, got {o}")


def is_some(o: Value) raises -> Value:
    _check_option(o, "is_some")
    return Value.bool(o.count() == 1)


def is_none(o: Value) raises -> Value:
    _check_option(o, "is_none")
    return Value.bool(o.count() == 0)


def unwrap(o: Value) raises -> Value:
    _check_option(o, "unwrap")
    if o.count() == 0:
        raise fail("unwrap", "the option is none")
    return o.item(0)


# eq


__enum FloatEq(Equatable, ImplicitlyCopyable):
    """How `eq` compares floats: `float="bits"`, `"ieee"` or `"nan_any"` (bits, with
    every NaN equal)."""

    case Bits
    case Ieee
    case NanAny

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()


@fieldwise_init
struct EqMode(ImplicitlyCopyable):
    """What the keyword arguments of `eq` ask for."""

    var floats: FloatEq
    var ignore_order: Bool
    """`order="ignore"`: lists and tuples compare as multisets, at every depth."""


def _keyword_text(value: Value) -> String:
    return value.text().copy() if value.kind == .String else ""


def float_eq(name: Optional[Value]) raises -> FloatEq:
    """The comparison `float=` names; bits when there is no `float=`."""
    if name is None:
        return .Bits
    match _keyword_text(name.value()):
        case "bits":
            return .Bits
        case "ieee":
            return .Ieee
        case "nan_any":
            return .NanAny
        case _:
            raise fail("eq", t"float= must be one of bits, ieee, nan_any, got {name.value()}")


def ignores_order(name: Optional[Value]) raises -> Bool:
    """Whether `order=` is `ignore`; `exact` when there is no `order=`."""
    if name is None:
        return False
    match _keyword_text(name.value()):
        case "ignore":
            return True
        case "exact":
            return False
        case _:
            raise fail("eq", t"order= must be one of exact, ignore, got {name.value()}")


def equal(a: Value, b: Value, mode: EqMode) raises -> Bool:
    """`eq(a, b)` with the given keyword arguments."""
    for kind in [a.kind, b.kind]:
        if kind in [Kind.Handle, Kind.Error]:
            raise fail("eq", t"cannot compare {kind} values")
    if a.kind in [Kind.Int, Kind.Real] and b.kind in [Kind.Int, Kind.Real]:
        return compare(a, b) == 0
    if a.kind != b.kind:
        return False
    match a.kind:
        case .Float:
            return _equal_floats(a, b, mode.floats)
        case .List | .Tuple:
            if a.count() != b.count():
                return False
            if mode.ignore_order:
                return _equal_unordered(a.items(), b.items(), mode)
            return _all_equal(a.items(), b.items(), mode)
        case .Option:
            return a.count() == b.count() and _all_equal(a.items(), b.items(), mode)
        case .Map:
            return a.count() == b.count() and _equal_maps(a, b, mode)
        case .Record:
            return a.name() == b.name() and a.count() == b.count() and _equal_fields(a, b, mode)
        case _:
            return a == b


def _equal_floats(a: Value, b: Value, floats: FloatEq) raises -> Bool:
    var f = a.float_format()
    if f != b.float_format():
        return False
    match floats:
        case .Bits:
            return a.float_bits() == b.float_bits()
        case .Ieee:
            return ieee_equal(a, b)
        case .NanAny:
            var a_nan = is_nan(f, a.float_bits())
            var b_nan = is_nan(f, b.float_bits())
            if a_nan or b_nan:
                return a_nan and b_nan
            return a.float_bits() == b.float_bits()


def _all_equal(xs: List[Value], ys: List[Value], mode: EqMode) raises -> Bool:
    for x, y in zip(xs, ys):
        if not equal(x, y, mode):
            return False
    return True


def _first_equal(x: Value, ys: List[Value], mode: EqMode) raises -> Optional[Int]:
    for i, y in enumerate(ys):
        if equal(x, y, mode):
            return i
    return None


def _equal_unordered(xs: List[Value], var ys: List[Value], mode: EqMode) raises -> Bool:
    """Each of `xs` pairs off with the first element of `ys` it equals that is still free."""
    for x in xs:
        var at = _first_equal(x, ys, mode)
        if at is None:
            return False
        _ = ys.pop(at.value())
    return True


def _equal_maps(a: Value, b: Value, mode: EqMode) raises -> Bool:
    """Each key of `a` has an equal key in `b` (the first, in `b`'s order) with an equal value."""
    var b_keys = b.keys()
    var b_values = b.values()
    for key, value in a.pairs():
        var at = _first_equal(key, b_keys, mode)
        if at is None or not equal(value, b_values[at.value()], mode):
            return False
    return True


def _equal_fields(a: Value, b: Value, mode: EqMode) raises -> Bool:
    for x, y in zip(a.pairs(), b.pairs()):
        if x[0] != y[0] or not equal(x[1], y[1], mode):
            return False
    return True
