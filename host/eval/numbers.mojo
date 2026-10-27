"""Operators on `Value`s: exact arithmetic, bit operations, qerr, strings by code point.

Every function raises an `Error` whose message says what went wrong; the evaluator
attaches the location.
"""

from bigint import BigUInt
from numeric.bigint import BigInt
from numeric.floats import is_nan, to_real
from numeric.formats import format_by_id
from numeric.real import Real
from prelude.util import real_value
from syntax import ast
from wire.equality import canonical_eq
from wire.format import format_value
from wire.order import compare
from wire.value import Value, INT, FLOAT, STRING, BYTES, LIST, TUPLE, MAP, OPTION, ENUM, REAL, QERR


comptime MAX_SHIFT = 1 << 24
"""Shifts and powers whose result would exceed this many bits are refused."""


def show(v: Value) -> String:
    """A value as a message shows it."""
    try:
        return format_value(v)
    except:
        return String(v)


def kind_text(v: Value) -> String:
    if v.kind == LIST or v.kind == TUPLE:
        return String("a list of length ", v.count())
    if v.kind == STRING:
        return String("a string of length ", v.text().byte_length())
    if v.kind == BYTES:
        return String("bytes of length ", len(v.data()))
    return show(v)


# Numbers


def is_number(v: Value) -> Bool:
    return v.kind == INT or v.kind == REAL or v.kind == FLOAT


def real_of(v: Value) raises -> Real:
    """An INT, REAL or FLOAT as an extended real. Promoting a NaN is an error."""
    if v.kind == INT:
        return Real(v.as_bigint())
    if v.kind == REAL:
        return Real(
            lowest_numerator=v.item(0).as_bigint(),
            lowest_denominator=v.item(1).as_bigint(),
        )
    if v.kind == FLOAT:
        var f = format_by_id(v.float_format_id())
        if is_nan(f, v.float_bits()):
            raise Error("promoting a NaN to a real is an error")
        return to_real(f, v.float_bits())
    raise Error(t"expected a number, but got {show(v)}")


def promote(v: Value) raises -> Value:
    """A FLOAT as the REAL it denotes; INT and REAL unchanged."""
    if v.kind == FLOAT:
        return real_value(real_of(v))
    return v.copy()


def to_real_kind(v: Value) -> Value:
    """An INT as the REAL of the same value; every other value unchanged."""
    if v.kind == INT:
        return Value.real(v.as_bigint(), BigInt(1))
    return v.copy()


def big_of(v: Value, what: String) raises -> BigInt:
    """An integer: an INT, or a REAL that is a whole number."""
    if v.kind == INT:
        return v.as_bigint()
    if v.kind == REAL and v.item(1).as_bigint() == BigInt(1):
        return v.item(0).as_bigint()
    raise Error(t"{what} must be an integer, but it is {show(v)}")


def index_of_value(v: Value, what: String) raises -> BigInt:
    if v.kind != INT:
        raise Error(t"{what} must be an integer, but it is {show(v)}")
    return v.as_bigint()


# Arithmetic


def negate(v: Value) raises -> Value:
    if v.kind == FLOAT:
        var f = format_by_id(v.float_format_id())
        return Value.float(f, v.float_bits() ^ f.sign_mask())
    if v.kind == INT:
        return Value.int(-v.as_bigint())
    if v.kind == REAL:
        return real_value(-real_of(v))
    raise Error(t"unary - needs a number, but the operand is {show(v)}")


def _pow(base: BigInt, exponent: BigInt) raises -> BigInt:
    if exponent.negative:
        raise Error(t"** needs a non-negative exponent, but it is {exponent}")
    if base.is_zero():
        return BigInt(0) if not exponent.is_zero() else BigInt(1)
    if base == BigInt(1):
        return BigInt(1)
    if base == BigInt(-1):
        return BigInt(-1) if exponent.magnitude.bit(0) else BigInt(1)
    var n = exponent.int64_or_none()
    if n is None or Int(n.value()) * base.bit_length() > MAX_SHIFT:
        raise Error("the result of ** is too large to compute")
    var k = Int(n.value())
    var result = BigInt(1)
    var square = base.copy()
    while k > 0:
        if k & 1 == 1:
            result = result * square
        k >>= 1
        if k > 0:
            square = square * square
    return result^


def _shift_amount(v: Value, op: String) raises -> Int:
    var b = v.as_bigint()
    if b.negative:
        raise Error(t"{op} needs a non-negative shift, but it is {b}")
    var n = b.int64_or_none()
    if n is None or Int(n.value()) > MAX_SHIFT:
        raise Error(t"the shift {b} is too large")
    return Int(n.value())


def _twos(x: BigInt, modulus: BigUInt) -> BigUInt:
    """x modulo 2**W as a non-negative number."""
    if x.negative:
        return modulus - x.magnitude
    return x.magnitude.copy()


def _bitwise(a: BigInt, b: BigInt, is_or: Bool) -> BigInt:
    var sa = a.int64_or_none()
    var sb = b.int64_or_none()
    if sa is not None and sb is not None:
        return BigInt(Int(sa.value() | sb.value() if is_or else sa.value() & sb.value()))
    var width = max(a.bit_length(), b.bit_length()) + 2
    var modulus = BigUInt(1) << width
    var ua = _twos(a, modulus)
    var ub = _twos(b, modulus)
    var combined = ua | ub
    if not is_or:
        # a & b = a + b - (a | b) for non-negative a and b.
        combined = (ua + ub) - combined
    if combined.bit(width - 1):
        return BigInt(negative=True, magnitude=modulus - combined)
    return BigInt(negative=False, magnitude=combined^)


def arith(op: ast.Op, a: Value, b: Value) raises -> Value:
    """`+ - * / // % ** << >> & |` on numbers. INT with INT stays INT; any REAL or
    FLOAT operand gives a REAL."""
    if op == .FLOORDIV or op == .MOD:
        var x = big_of(a, String(t"the left operand of {op}"))
        var y = big_of(b, String(t"the right operand of {op}"))
        if y.is_zero():
            raise Error("division by zero")
        var qr = x.divmod(y)
        return Value.int(qr[0].copy() if op == .FLOORDIV else qr[1].copy())
    if op == .POW:
        return Value.int(
            _pow(big_of(a, "the base of **"), big_of(b, "the exponent of **"))
        )
    if op == .SHL or op == .SHR:
        var x = big_of(a, String(t"the left operand of {op}"))
        var n = _shift_amount(
            Value.int(big_of(b, "the shift amount")), String(op)
        )
        if op == .SHL:
            return Value.int(x << n)
        return Value.int(x // (BigInt(1) << n))
    if op == .BITAND or op == .BITOR:
        var x = big_of(a, String(t"the left operand of {op}"))
        var y = big_of(b, String(t"the right operand of {op}"))
        return Value.int(_bitwise(x, y, op == .BITOR))
    if a.kind == INT and b.kind == INT and op != .DIV:
        var x = a.as_bigint()
        var y = b.as_bigint()
        if op == .ADD:
            return Value.int(x + y)
        if op == .SUB:
            return Value.int(x - y)
        if op == .MUL:
            return Value.int(x * y)
    var x = real_of(a)
    var y = real_of(b)
    if op == .ADD:
        return real_value(x + y)
    if op == .SUB:
        return real_value(x - y)
    if op == .MUL:
        return real_value(x * y)
    if op == .DIV:
        return real_value(x / y)
    raise Error(t"unknown operator {op}")


# Strings, bytes and lists


def codepoint_count(s: String) -> Int:
    var n = 0
    for b in s.as_bytes():
        if (Int(b) & 0xC0) != 0x80:
            n += 1
    return n


def _byte_offset(s: String, k: Int) -> Int:
    """The byte offset of code point k (k may equal the count)."""
    var seen = -1
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        if (Int(bytes[i]) & 0xC0) != 0x80:
            seen += 1
            if seen == k:
                return i
    return len(bytes)


def codepoint_slice(s: String, a: Int, b: Int) -> String:
    var lo = _byte_offset(s, a)
    var hi = _byte_offset(s, b)
    return String(s[byte=lo:hi])


def is_stringish(v: Value) -> Bool:
    return v.kind == STRING or (v.kind == ENUM and v.name() == "")


def sequence_length(v: Value) -> Int:
    if v.kind == STRING:
        return codepoint_count(v.text())
    if v.kind == BYTES:
        return len(v.data())
    return v.count()


def index_value(v: Value, i: Value) raises -> Value:
    """`v[i]` for a list, string or bytes."""
    var idx = index_of_value(i, "an index")
    var n = sequence_length(v)
    var small = idx.int64_or_none()
    if small is None or Int(small.value()) < 0 or Int(small.value()) >= n:
        raise Error(t"index {idx} is out of range for {kind_text(v)}")
    var k = Int(small.value())
    if v.kind == BYTES:
        return Value.int(Int(v.data()[k]))
    if v.kind == LIST or v.kind == TUPLE:
        return v.item(k)
    return Value.string(codepoint_slice(v.text(), k, k + 1))


def _bound(v: Value) raises -> Int:
    var b = index_of_value(v, "a slice bound")
    var small = b.int64_or_none()
    return -1 if small is None else Int(small.value())


def slice_value(v: Value, a: Value, b: Value) raises -> Value:
    var lo = _bound(a)
    var hi = _bound(b)
    var n = sequence_length(v)
    if not (0 <= lo and lo <= hi and hi <= n):
        raise Error(
            t"slice [{a.as_bigint()}:{b.as_bigint()}] is out of range for {kind_text(v)} (need 0 <= a <= b <= len)"
        )
    if v.kind == BYTES:
        return Value.bytes(List(v.data()[lo:hi]))
    if v.kind == LIST:
        return Value.list([v.item(i) for i in range(lo, hi)])
    return Value.string(codepoint_slice(v.text(), lo, hi))


def concat(a: Value, b: Value) raises -> Optional[Value]:
    """`a + b` on lists, strings and bytes; None for other operands."""
    if a.kind == LIST and b.kind == LIST:
        return Value.list([a.item(i) for i in range(a.count())] + [b.item(i) for i in range(b.count())])
    if is_stringish(a) and is_stringish(b):
        return Value.string(String(a.text(), b.text()))
    if a.kind == BYTES and b.kind == BYTES:
        return Value.bytes(List(a.data()) + List(b.data()))
    return None


def elements(v: Value, what: String) raises -> List[Value]:
    """What a comprehension ranges over."""
    if v.kind == LIST or v.kind == TUPLE:
        return [v.item(i) for i in range(v.count())]
    if v.kind == BYTES:
        return [Value.int(Int(b)) for b in v.data()]
    if is_stringish(v):
        return [Value.string(String(cp)) for cp in v.text().codepoints()]
    if v.kind == MAP:
        return [v.item(2 * i) for i in range(v.count())]
    raise Error(t"{what} ranges over a list, string, bytes or map, but got {show(v)}")


# Equality and membership


def _has_literal(v: Value) -> Bool:
    if v.kind == ENUM:
        return v.name() == ""
    if v.kind == LIST or v.kind == TUPLE or v.kind == OPTION or v.kind == MAP:
        return any([_has_literal(v.item(i)) for i in range(v.item_count())])
    return False


def norm(v: Value) raises -> Value:
    """Members of a literal union read as the strings they are."""
    if not _has_literal(v):
        return v.copy()
    if v.kind == ENUM:
        return Value.string(v.text().copy())
    var items = [norm(v.item(i)) for i in range(v.item_count())]
    if v.kind == LIST:
        return Value.list(items^)
    if v.kind == TUPLE:
        return Value.tuple(items^)
    if v.kind == OPTION:
        return Value.some(items[0].copy()) if len(items) == 1 else Value.none()
    return Value.map(
        [items[i].copy() for i in range(0, len(items), 2)],
        [items[i].copy() for i in range(1, len(items), 2)],
    )


def values_equal(a: Value, b: Value) raises -> Bool:
    """The language's `==`."""
    return canonical_eq(norm(a), norm(b))


def contains_bytes(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    var n = len(needle)
    if n == 0:
        return True
    for i in range(len(hay) - n + 1):
        if hay[i : i + n] == needle:
            return True
    return False


def contains(container: Value, x: Value) raises -> Bool:
    """The language's `x in container`."""
    if container.kind == LIST or container.kind == TUPLE:
        for i in range(container.count()):
            if values_equal(x, container.item(i)):
                return True
        return False
    if container.kind == MAP:
        for i in range(container.count()):
            if values_equal(x, container.item(2 * i)):
                return True
        return False
    if is_stringish(container):
        if not is_stringish(x):
            raise Error(t"in on a string looks for a substring, not {show(x)}")
        return x.text() in container.text()
    if container.kind == BYTES:
        if x.kind == INT:
            var small = x.as_bigint().int64_or_none()
            return small is not None and Int(small.value()) in [Int(b) for b in container.data()]
        if x.kind == BYTES:
            return contains_bytes(container.data(), x.data())
        raise Error(t"in on bytes looks for a byte or a byte string, not {show(x)}")
    raise Error(t"in needs a list, map or string on the right, not {show(container)}")


# Order


def compare_values(a: Value, b: Value) raises -> Int:
    """-1, 0 or 1 by the language's order; floats compare after promotion."""
    if is_number(a) and is_number(b):
        return compare(promote(a), promote(b))
    return compare(norm(a), norm(b))


def holds_order(op: ast.Op, c: Int) -> Bool:
    if op == .LT:
        return c < 0
    if op == .LE:
        return c <= 0
    if op == .GT:
        return c > 0
    return c >= 0


# Quantized errors


def qerr_zero() -> Value:
    return Value.qerr(BigInt(0), BigInt(0))


@fieldwise_init
struct QParts(Movable):
    var steps: Real
    var nans: BigInt


def qerr_parts(v: Value) raises -> QParts:
    """(steps, nans) of a qerr; a number c reads as c + 0*nan."""
    if v.kind == QERR:
        return QParts(Real(v.item(0).as_bigint()), v.item(1).as_bigint())
    if is_number(v):
        return QParts(real_of(v), BigInt(0))
    raise Error(t"a qerr compares with a qerr or a number, not {show(v)}")


def qerr_add(a: Value, b: Value) -> Value:
    return Value.qerr(
        a.item(0).as_bigint() + b.item(0).as_bigint(),
        a.item(1).as_bigint() + b.item(1).as_bigint(),
    )


def qerr_compare(op: ast.Op, a: Value, b: Value) raises -> Bool:
    """Componentwise comparison of a qerr with a qerr or a number."""
    var pa = qerr_parts(a)
    var pb = qerr_parts(b)
    var c = 0
    if pa.steps < pb.steps:
        c = -1
    elif pb.steps < pa.steps:
        c = 1
    var equal = c == 0 and pa.nans == pb.nans
    if op == .EQ:
        return equal
    if op == .NE:
        return not equal
    var below = c <= 0 and pa.nans <= pb.nans
    var above = c >= 0 and pa.nans >= pb.nans
    if op == .LE:
        return below
    if op == .GE:
        return above
    return (below if op == .LT else above) and not equal


def term_of(v: Value) raises -> Value:
    """A sum or max term: a qerr or a number (a float promotes; NaN is an error)."""
    if v.kind == QERR or v.kind == INT or v.kind == REAL:
        return v.copy()
    if v.kind == FLOAT:
        return promote(v)
    raise Error(t"a term must be a number or a qerr, but it is {show(v)}")


def add_term(total: Value, v: Value) raises -> Value:
    var t = term_of(v)
    if total.kind == QERR or t.kind == QERR:
        if not (total.kind == QERR and t.kind == QERR):
            raise Error(t"cannot add {show(t)} to the qerr {show(total)}")
        return qerr_add(total, t)
    return arith(ast.Op.ADD, total, t)


def larger(a: Value, b: Value) raises -> Value:
    if a.kind == QERR and b.kind == QERR:
        var sa = a.item(0).as_bigint()
        var sb = b.item(0).as_bigint()
        var na = a.item(1).as_bigint()
        var nb = b.item(1).as_bigint()
        return Value.qerr(sb.copy() if sa < sb else sa.copy(), nb.copy() if na < nb else na.copy())
    if a.kind == QERR or b.kind == QERR:
        raise Error(t"cannot compare {show(a)} with {show(b)}")
    return b.copy() if compare(a, b) < 0 else a.copy()
