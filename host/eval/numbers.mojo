"""Operators on `Value`s: exact arithmetic, bit operations, qerr, strings by code point.

Every function raises an `Error` whose message says what went wrong; the evaluator
attaches the location.
"""

from value.bigint import BigInt
from value.fixed import wrapped
from value.floats import is_nan, to_real
from value.real import Real
from prelude.util import real_value
from syntax.ast import Op
from value.equality import canonical_eq
from value.text import format_value
from value.order import compare
from value.value import Kind, Value


comptime MAX_SHIFT = 1 << 24
"""Shifts and powers whose result would exceed this many bits are refused."""


def show(v: Value) -> String:
    """A value as a message shows it."""
    try:
        return format_value(v)
    except:
        return String(v)


def kind_text(v: Value) -> String:
    match v.kind:
        case .LIST | .TUPLE:
            return String(t"a list of length {v.count()}")
        case .STRING:
            return String(t"a string of length {v.text().byte_length()}")
        case .BYTES:
            return String(t"bytes of length {len(v.data())}")
        case _:
            return show(v)


# Numbers


def is_number(v: Value) -> Bool:
    return v.kind in [Kind.INT, Kind.REAL, Kind.FLOAT]


def real_of(v: Value) raises -> Real:
    """An INT, REAL or FLOAT as an extended real. Promoting a NaN is an error."""
    match v.kind:
        case .INT | .REAL:
            return v.as_real()
        case .FLOAT:
            var f = v.float_format()
            if is_nan(f, v.float_bits()):
                raise Error("promoting a NaN to a real is an error")
            return to_real(f, v.float_bits())
        case _:
            raise Error(t"expected a number, but got {show(v)}")


def promote(v: Value) raises -> Value:
    """A FLOAT as the REAL it denotes; INT and REAL unchanged."""
    return real_value(real_of(v)) if v.kind == .FLOAT else v.copy()


def to_real_kind(v: Value) -> Value:
    """An INT as the REAL of the same value; every other value unchanged."""
    return Value.real(v.as_bigint(), BigInt(1)) if v.kind == .INT else v.copy()


def integer_of(v: Value) -> Optional[BigInt]:
    """An INT, or a REAL that is a whole number, as an integer."""
    if v.kind == .INT:
        return v.as_bigint()
    if v.kind == .REAL and v.item(1).as_bigint() == 1:
        return v.item(0).as_bigint()
    return None


def _integer(v: Value, what: String) raises -> BigInt:
    var n = integer_of(v)
    if n is None:
        raise Error(t"{what} must be an integer, but it is {show(v)}")
    return n.take()


def _index(v: Value, what: String) raises -> Int:
    """An INT index, or -1 for one too large for an Int, which no sequence has."""
    if v.kind != .INT:
        raise Error(t"{what} must be an integer, but it is {show(v)}")
    return v.small_int().or_else(-1)


# Arithmetic


def negate(v: Value) raises -> Value:
    match v.kind:
        case .FLOAT:
            var f = v.float_format()
            return Value.float(f, v.float_bits() ^ f.sign_mask())
        case .INT:
            return Value.int(-v.as_bigint())
        case .REAL:
            return real_value(-real_of(v))
        case _:
            raise Error(t"unary - needs a number, but the operand is {show(v)}")


def _pow(base: BigInt, exponent: BigInt) raises -> BigInt:
    if exponent.negative:
        raise Error(t"** needs a non-negative exponent, but it is {exponent}")
    if base.is_zero():
        return BigInt(1) if exponent.is_zero() else BigInt(0)
    if base == 1:
        return BigInt(1)
    if base == -1:
        return BigInt(-1) if exponent.magnitude.bit(0) else BigInt(1)
    var n = exponent.int64_or_none()
    if n is None or Int(n.value()) * base.bit_length() > MAX_SHIFT:
        raise Error("the result of ** is too large to compute")
    return base ** Int(n.value())


def _shift_amount(shift: BigInt, op: Op) raises -> Int:
    if shift.negative:
        raise Error(t"{op} needs a non-negative shift, but it is {shift}")
    var n = shift.int64_or_none()
    if n is None or Int(n.value()) > MAX_SHIFT:
        raise Error(t"the shift {shift} is too large")
    return Int(n.value())


def _bitwise(a: BigInt, b: BigInt, op: Op) -> BigInt:
    """`a | b` or `a & b` on two's complement, as Python's."""
    if case (.Some(x), .Some(y)) = (a.int64_or_none(), b.int64_or_none()):
        return BigInt(Int(x | y if op == .BITOR else x & y))
    var width = max(a.bit_length(), b.bit_length()) + 2
    var ua = wrapped(a, width, signed=False).magnitude.copy()
    var ub = wrapped(b, width, signed=False).magnitude.copy()
    # BigUInt has no &, and a & b = a + b - (a | b) for non-negative a and b.
    var combined = ua | ub if op == .BITOR else (ua + ub) - (ua | ub)
    return wrapped(BigInt(negative=False, magnitude=combined^), width, signed=True)


def arith(op: Op, a: Value, b: Value) raises -> Value:
    """`+ - * / // % ** << >> & |` on numbers. INT with INT stays INT; any REAL or
    FLOAT operand gives a REAL."""
    match op:
        case .FLOORDIV | .MOD:
            var x = _integer(a, String(t"the left operand of {op}"))
            var y = _integer(b, String(t"the right operand of {op}"))
            if y.is_zero():
                raise Error("division by zero")
            return Value.int(x // y if op == .FLOORDIV else x % y)
        case .POW:
            return Value.int(_pow(_integer(a, "the base of **"), _integer(b, "the exponent of **")))
        case .SHL | .SHR:
            var x = _integer(a, String(t"the left operand of {op}"))
            var n = _shift_amount(_integer(b, "the shift amount"), op)
            return Value.int(x << n if op == .SHL else x >> n)
        case .BITAND | .BITOR:
            var x = _integer(a, String(t"the left operand of {op}"))
            var y = _integer(b, String(t"the right operand of {op}"))
            return Value.int(_bitwise(x, y, op))
        case _:
            pass
    if a.kind == .INT and b.kind == .INT:
        var x = a.as_bigint()
        var y = b.as_bigint()
        match op:
            case .ADD:
                return Value.int(x + y)
            case .SUB:
                return Value.int(x - y)
            case .MUL:
                return Value.int(x * y)
            case _:
                pass
    var x = real_of(a)
    var y = real_of(b)
    match op:
        case .ADD:
            return real_value(x + y)
        case .SUB:
            return real_value(x - y)
        case .MUL:
            return real_value(x * y)
        case .DIV:
            return real_value(x / y)
        case _:
            raise Error(t"unknown operator {op}")


# Strings, bytes and lists


def is_stringish(v: Value) -> Bool:
    """A string, or a member of a literal union, which reads as one."""
    return v.kind == .STRING or (v.kind == .ENUM and v.name() == "")


def sequence_length(v: Value) -> Int:
    match v.kind:
        case .STRING:
            return v.text().count_codepoints()
        case .BYTES:
            return len(v.data())
        case _:
            return v.count()


def index_value(v: Value, i: Value) raises -> Value:
    """`v[i]` for a list, string or bytes."""
    var k = _index(i, "an index")
    if not 0 <= k < sequence_length(v):
        raise Error(t"index {i.as_bigint()} is out of range for {kind_text(v)}")
    match v.kind:
        case .BYTES:
            return Value.int(Int(v.data()[k]))
        case .LIST | .TUPLE:
            return v.item(k)
        case _:
            return Value.string(String(v.text()[codepoint=k]))


def slice_value(v: Value, a: Value, b: Value) raises -> Value:
    var lo = _index(a, "a slice bound")
    var hi = _index(b, "a slice bound")
    if not 0 <= lo <= hi <= sequence_length(v):
        raise Error(
            t"slice [{a.as_bigint()}:{b.as_bigint()}] is out of range for {kind_text(v)} (need 0 <= a <= b <= len)"
        )
    match v.kind:
        case .BYTES:
            return Value.bytes(List(v.data()[lo:hi]))
        case .LIST:
            return Value.list([v.item(i) for i in range(lo, hi)])
        case _:
            return Value.string(String(v.text()[codepoint=lo:hi]))


def concat(a: Value, b: Value) -> Optional[Value]:
    """`a + b` on lists, strings and bytes; None for other operands."""
    if a.kind == .LIST and b.kind == .LIST:
        return Value.list(a.items() + b.items())
    if is_stringish(a) and is_stringish(b):
        return Value.string(a.text() + b.text())
    if a.kind == .BYTES and b.kind == .BYTES:
        return Value.bytes(a.data() + b.data().copy())
    return None


def elements(v: Value, what: String) raises -> List[Value]:
    """What a comprehension ranges over."""
    if is_stringish(v):
        return [Value.string(String(cp)) for cp in v.text().codepoints()]
    match v.kind:
        case .LIST | .TUPLE:
            return v.items()
        case .BYTES:
            return [Value.int(Int(b)) for b in v.data()]
        case .MAP:
            return v.keys()
        case _:
            raise Error(t"{what} ranges over a list, string, bytes or map, but got {show(v)}")


# Equality and membership


def _has_literal(v: Value) -> Bool:
    match v.kind:
        case .ENUM:
            return v.name() == ""
        case .LIST | .TUPLE | .OPTION | .MAP:
            return any([_has_literal(item) for item in v.items()])
        case _:
            return False


def norm(v: Value) raises -> Value:
    """Members of a literal union read as the strings they are."""
    if not _has_literal(v):
        return v.copy()
    match v.kind:
        case .ENUM:
            return Value.string(v.text().copy())
        case .LIST:
            return Value.list([norm(item) for item in v.items()])
        case .TUPLE:
            return Value.tuple([norm(item) for item in v.items()])
        case .OPTION:
            return Value.some(norm(v.item(0)))
        case _:
            return Value.map([norm(key) for key in v.keys()], [norm(value) for value in v.values()])


def values_equal(a: Value, b: Value) raises -> Bool:
    """The language's `==`."""
    return canonical_eq(norm(a), norm(b))


def _has_equal(items: List[Value], x: Value) raises -> Bool:
    for item in items:
        if values_equal(x, item):
            return True
    return False


def contains(container: Value, x: Value) raises -> Bool:
    """The language's `x in container`."""
    if is_stringish(container):
        if not is_stringish(x):
            raise Error(t"in on a string looks for a substring, not {show(x)}")
        return x.text() in container.text()
    match container.kind:
        case .LIST | .TUPLE:
            return _has_equal(container.items(), x)
        case .MAP:
            return _has_equal(container.keys(), x)
        case .BYTES:
            if x.kind == .INT:
                if case .Some(byte) = x.small_int():
                    return 0 <= byte <= 255 and UInt8(byte) in container.data()
                return False
            if x.kind == .BYTES:
                return StringSlice(unsafe_from_utf8=Span(x.data())) in StringSlice(
                    unsafe_from_utf8=Span(container.data())
                )
            raise Error(t"in on bytes looks for a byte or a byte string, not {show(x)}")
        case _:
            raise Error(t"in needs a list, map or string on the right, not {show(container)}")


# Order


def compare_values(a: Value, b: Value) raises -> Int:
    """-1, 0 or 1 by the language's order; floats compare after promotion."""
    if is_number(a) and is_number(b):
        return compare(promote(a), promote(b))
    return compare(norm(a), norm(b))


def holds_order(op: Op, c: Int) -> Bool:
    """Whether `op`, one of `< <= > >=`, holds of two values that compare as `c`."""
    match op:
        case .LT:
            return c < 0
        case .LE:
            return c <= 0
        case .GT:
            return c > 0
        case _:
            return c >= 0


# Quantized errors


def qerr_zero() -> Value:
    return Value.qerr(BigInt(0), BigInt(0))


@fieldwise_init
struct QerrParts(Movable):
    var steps: Real
    var nans: BigInt


def qerr_parts(v: Value) raises -> QerrParts:
    """The steps and nans of a qerr; a number c reads as c + 0*nan."""
    if v.kind == .QERR:
        return QerrParts(Real(v.item(0).as_bigint()), v.item(1).as_bigint())
    if is_number(v):
        return QerrParts(real_of(v), BigInt(0))
    raise Error(t"a qerr compares with a qerr or a number, not {show(v)}")


def qerr_add(a: Value, b: Value) -> Value:
    return Value.qerr(
        a.item(0).as_bigint() + b.item(0).as_bigint(),
        a.item(1).as_bigint() + b.item(1).as_bigint(),
    )


def qerr_compare(op: Op, a: Value, b: Value) raises -> Bool:
    """Componentwise comparison of a qerr with a qerr or a number."""
    var pa = qerr_parts(a)
    var pb = qerr_parts(b)
    var c = -1 if pa.steps < pb.steps else (1 if pb.steps < pa.steps else 0)
    var equal = c == 0 and pa.nans == pb.nans
    var below = c <= 0 and pa.nans <= pb.nans
    var above = c >= 0 and pa.nans >= pb.nans
    match op:
        case .EQ:
            return equal
        case .NE:
            return not equal
        case .LE:
            return below
        case .GE:
            return above
        case .LT:
            return below and not equal
        case _:
            return above and not equal


def term_of(v: Value) raises -> Value:
    """A sum or max term: a qerr or a number (a float promotes; NaN is an error)."""
    match v.kind:
        case .QERR | .INT | .REAL:
            return v.copy()
        case .FLOAT:
            return promote(v)
        case _:
            raise Error(t"a term must be a number or a qerr, but it is {show(v)}")


def add_term(total: Value, v: Value) raises -> Value:
    var t = term_of(v)
    if total.kind == .QERR or t.kind == .QERR:
        if not (total.kind == .QERR and t.kind == .QERR):
            raise Error(t"cannot add {show(t)} to the qerr {show(total)}")
        return qerr_add(total, t)
    return arith(Op.ADD, total, t)


def larger(a: Value, b: Value) raises -> Value:
    """The larger term; of two qerrs, the larger steps and the larger nans."""
    if a.kind == .QERR and b.kind == .QERR:
        var steps = max(a.item(0).as_bigint(), b.item(0).as_bigint())
        var nans = max(a.item(1).as_bigint(), b.item(1).as_bigint())
        return Value.qerr(steps^, nans^)
    if a.kind == .QERR or b.kind == .QERR:
        raise Error(t"cannot compare {show(a)} with {show(b)}")
    return b.copy() if compare(a, b) < 0 else a.copy()
