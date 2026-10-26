"""Text of values, as reports show them.

Strings and bytes are quoted with escapes, lists are `[a, b]`, tuples `(a, b)` and
`(a,)`, maps `{k: v}`, options `none` and `some(x)`, records `Name { f: v }`, enum
members by their name, handles `<Class #id>`, errors `Class: message`. Reals print
as exact decimals when short and terminating, else as a ratio with an approximation.
A qerr prints as `3`, `2nan` or `3 + 2nan`.
"""

from numeric.bigint import BigInt
from numeric.text import float_text
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


def _hex(value: Int, width: Int) -> String:
    var digits = String()
    var v = value
    while v > 0:
        digits = String("0123456789abcdef"[byte = v % 16 : v % 16 + 1], digits)
        v //= 16
    while digits.byte_length() < width:
        digits = String("0", digits)
    return digits


def _escape_ascii(c: Int) -> String:
    if c == ord('"'):
        return '\\"'
    if c == ord("\\"):
        return "\\\\"
    if c == 10:
        return "\\n"
    if c == 9:
        return "\\t"
    if c == 13:
        return "\\r"
    if c < 0x20 or c == 0x7F:
        return String("\\x", _hex(c, 2))
    return chr(c)


def _is_printable(c: Int) -> Bool:
    """An approximation of Python's `str.isprintable` for non-ASCII code points:
    controls, separators, format characters, private use and U+FFFD are not."""
    if c <= 0xA0 or c == 0xAD or c == 0x1680 or c == 0x180E or c == 0xFFFD:
        return False
    if 0x2000 <= c <= 0x200F or 0x2028 <= c <= 0x202F or 0x205F <= c <= 0x206F:
        return False
    if c == 0x3000 or c == 0xFEFF or 0xD800 <= c <= 0xF8FF:
        return False
    if c >= 0xF0000:
        return False
    return True


def _quote(text: String) -> String:
    var out = String('"')
    for cp in text.codepoints():
        var c = Int(cp.to_u32())
        if c < 0x80:
            out += _escape_ascii(c)
        elif not _is_printable(c):
            out += String("\\u{", _hex(c, 1), "}")
        else:
            out += String(cp)
    out += '"'
    return out


def _quote_bytes(data: List[UInt8]) -> String:
    var out = String('b"')
    for b in data:
        var c = Int(b)
        if c < 0x80:
            out += _escape_ascii(c)
        else:
            out += String("\\x", _hex(c, 2))
    out += '"'
    return out


def _pow10(n: Int) -> BigInt:
    var r = BigInt(1)
    var ten = BigInt(10)
    for _ in range(n):
        r = r * ten
    return r^


def _strip_factor(mut d: BigInt, factor: Int) raises -> Int:
    """Divide `factor` out of `d` as often as it divides; how often that was."""
    var count = 0
    var f = BigInt(factor)
    while True:
        var qr = d.divmod(f)
        if not qr[1].is_zero():
            return count
        d = qr[0].copy()
        count += 1


def _exact_decimal(n: BigInt, d: BigInt) raises -> Optional[String]:
    """`n/d` (both positive) as a terminating decimal of at most 25 digits."""
    var rest = d.copy()
    var twos = _strip_factor(rest, 2)
    var fives = _strip_factor(rest, 5)
    var places = max(twos, fives)
    if rest != BigInt(1) or places > 25:
        return None
    var scaled = (n * _pow10(places)) // d
    if not (scaled < _pow10(25)):
        return None
    var text = String(scaled)
    while text.byte_length() < places + 1:
        text = String("0", text)
    var split = text.byte_length() - places
    var fraction = String(text[byte=split:])
    var end = fraction.byte_length()
    while end > 0 and fraction.as_bytes()[end - 1] == UInt8(ord("0")):
        end -= 1
    if end == 0:
        return String(text[byte=:split])
    return String(text[byte=:split], ".", fraction[byte=:end])


def _floor_log10(n: BigInt, d: BigInt) -> Int:
    """floor(log10(n/d)) for positive n and d."""
    var k = String(n).byte_length() - String(d).byte_length()
    while True:
        var lo = n.copy() if k >= 0 else n * _pow10(-k)
        var hi = d * _pow10(k) if k >= 0 else d.copy()
        if lo < hi:
            k -= 1
        else:
            break
    while True:
        var k1 = k + 1
        var lo = n.copy() if k1 >= 0 else n * _pow10(-k1)
        var hi = d * _pow10(k1) if k1 >= 0 else d.copy()
        if lo < hi:
            break
        k += 1
    return k


def _approximate(n: BigInt, d: BigInt, digits: Int) raises -> String:
    var k = _floor_log10(n, d)
    var shift = k - digits + 1
    var num = n.copy()
    var den = d.copy()
    if shift >= 0:
        den = den * _pow10(shift)
    else:
        num = num * _pow10(-shift)
    var qr = num.divmod(den)
    var q = qr[0].copy()
    var twice = qr[1] * BigInt(2)
    if den < twice or (twice == den and not (qr[0] % BigInt(2)).is_zero()):
        q = q + BigInt(1)
    if not (q < _pow10(digits)):
        q = q // BigInt(10)
        k += 1
    var text = String(q)
    var end = text.byte_length()
    if -5 <= k < digits:
        if k >= 0:
            var whole = String(text[byte=: k + 1])
            var frac = String(text[byte = k + 1 :])
            var e = frac.byte_length()
            while e > 0 and frac.as_bytes()[e - 1] == UInt8(ord("0")):
                e -= 1
            if e == 0:
                return whole
            return String(whole, ".", frac[byte=:e])
        while end > 0 and text.as_bytes()[end - 1] == UInt8(ord("0")):
            end -= 1
        var zeros = String()
        for _ in range(-k - 1):
            zeros += "0"
        return String("0.", zeros, text[byte=:end])
    var rest = String(text[byte=1:])
    var e = rest.byte_length()
    while e > 0 and rest.as_bytes()[e - 1] == UInt8(ord("0")):
        e -= 1
    var mantissa = String(rest[byte=:e]) if e > 0 else String("0")
    var sign = "+" if k >= 0 else "-"
    return String(text[byte=:1], ".", mantissa, "e", sign, abs(k))


def _format_real(value: Value) raises -> String:
    var n = value.item(0).as_bigint()
    var d = value.item(1).as_bigint()
    if d.is_zero():
        return "+inf" if n.sign() > 0 else "-inf"
    if d == BigInt(1):
        return String(n)
    if n.is_zero():
        return "0"
    var sign = "-" if n.sign() < 0 else ""
    var a = n.__abs__()
    var exact = _exact_decimal(a, d)
    if exact:
        return String(sign, exact.value())
    var approx = String("~", sign, _approximate(a, d, 20))
    var ratio = String(n, "/", d)
    if ratio.byte_length() <= 24:
        return String(ratio, " (", approx, ")")
    return approx


def _format_qerr(value: Value) -> String:
    var steps = value.item(0).as_bigint()
    var nans = value.item(1).as_bigint()
    if nans.is_zero():
        return String(steps)
    if steps.is_zero():
        return String(nans, "nan")
    return String(steps, " + ", nans, "nan")


def format_value(value: Value) raises -> String:
    var kind = value.kind
    if kind == BOOL:
        return "true" if value.as_bool() else "false"
    if kind == INT:
        return String(value.as_bigint())
    if kind == FLOAT:
        return float_text(value.float_format_id(), value.float_bits())
    if kind == STRING:
        return _quote(value.text())
    if kind == BYTES:
        return _quote_bytes(value.data())
    if kind == LIST or kind == TUPLE:
        var out = String("[" if kind == LIST else "(")
        for i in range(value.count()):
            if i:
                out += ", "
            out += format_value(value.item(i))
        if kind == TUPLE and value.count() == 1:
            out += ","
        out += "]" if kind == LIST else ")"
        return out
    if kind == MAP:
        var out = String("{")
        for i in range(value.count()):
            if i:
                out += ", "
            out += String(
                format_value(value.item(2 * i)),
                ": ",
                format_value(value.item(2 * i + 1)),
            )
        return out + "}"
    if kind == OPTION:
        if value.count() == 0:
            return "none"
        return String("some(", format_value(value.item(0)), ")")
    if kind == RECORD:
        if value.count() == 0:
            return String(value.name(), " {}")
        var out = String(value.name(), " { ")
        for i in range(value.count()):
            if i:
                out += ", "
            out += String(
                value.item(2 * i).text(), ": ", format_value(value.item(2 * i + 1))
            )
        return out + " }"
    if kind == ENUM:
        return value.text().copy()
    if kind == HANDLE:
        return String("<", value.name(), " #", value.handle_id(), ">")
    if kind == ERROR:
        return String(value.name(), ": ", value.text())
    if kind == REAL:
        return _format_real(value)
    if kind == QERR:
        return _format_qerr(value)
    raise Error("cannot format an invalid value")
