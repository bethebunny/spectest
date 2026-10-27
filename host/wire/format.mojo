"""Text of values, as reports show them.

Strings and bytes are quoted with escapes, lists are `[a, b]`, tuples `(a, b)` and
`(a,)`, maps `{k: v}`, options `none` and `some(x)`, records `Name { f: v }`, enum
members by their name, handles `<Class #id>`, errors `Class: message`. Reals print
as exact decimals when short and terminating, else as a ratio with an approximation.
A qerr prints as `3`, `2nan` or `3 + 2nan`.
"""

from numeric.digits import hex_digits
from numeric.text import approximate_decimal, exact_decimal, float_text
from wire import value as wv
from wire.value import Value


def _escape_ascii(c: Int) -> String:
    match c:
        case 34:  # "
            return '\\"'
        case 92:  # \\
            return "\\\\"
        case 10:
            return "\\n"
        case 9:
            return "\\t"
        case 13:
            return "\\r"
        case _:
            if c < 0x20 or c == 0x7F:
                return String("\\x", hex_digits(UInt64(c), width=2))
            return chr(c)


def _is_printable(c: Int) -> Bool:
    """An approximation of Python's `str.isprintable` for non-ASCII code points:
    controls, separators, format characters, private use and U+FFFD are not."""
    return not (
        c <= 0xA0
        or c in [0xAD, 0x1680, 0x180E, 0xFFFD, 0x3000, 0xFEFF]
        or 0x2000 <= c <= 0x200F
        or 0x2028 <= c <= 0x202F
        or 0x205F <= c <= 0x206F
        or 0xD800 <= c <= 0xF8FF
        or c >= 0xF0000
    )


def _quote(text: String) -> String:
    var out = String('"')
    for cp in text.codepoints():
        var c = Int(cp.to_u32())
        if c < 0x80:
            out += _escape_ascii(c)
        elif _is_printable(c):
            out += String(cp)
        else:
            out += String("\\u{", hex_digits(UInt64(c)), "}")
    return out + '"'


def _quote_bytes(data: List[UInt8]) -> String:
    var out = String('b"')
    for b in data:
        out += _escape_ascii(Int(b)) if b < 0x80 else String("\\x", hex_digits(UInt64(b), width=2))
    return out + '"'


def _format_real(value: Value) raises -> String:
    var real = value.as_real()
    if real.is_inf():
        return "+inf" if real.numerator.sign() > 0 else "-inf"
    if real.is_zero() or real.is_integer():
        return String(real.numerator)
    var sign = "-" if real.numerator.negative else ""
    var magnitude = abs(real)
    var exact = exact_decimal(magnitude, limit=25)
    if exact is not None:
        return String(sign, exact.value())
    var approximation = String("~", sign, approximate_decimal(magnitude, digits=20))
    var ratio = String(real.numerator, "/", real.denominator)
    return String(ratio, " (", approximation, ")") if ratio.byte_length() <= 24 else approximation


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
    if kind == wv.BOOL:
        return "true" if value.as_bool() else "false"
    if kind == wv.INT:
        return String(value.as_bigint())
    if kind == wv.FLOAT:
        return float_text(value.float_format_id(), value.float_bits())
    if kind == wv.STRING:
        return _quote(value.text())
    if kind == wv.BYTES:
        return _quote_bytes(value.data())
    if kind == wv.LIST:
        return String("[", ", ".join([format_value(item) for item in value.items()]), "]")
    if kind == wv.TUPLE:
        var items = ", ".join([format_value(item) for item in value.items()])
        return String("(", items, "," if value.count() == 1 else "", ")")
    if kind == wv.MAP:
        var pairs = [String(format_value(k), ": ", format_value(v)) for k, v in value.pairs()]
        return String("{", ", ".join(pairs), "}")
    if kind == wv.OPTION:
        return String("some(", format_value(value.item(0)), ")") if value.count() > 0 else "none"
    if kind == wv.RECORD:
        if value.count() == 0:
            return String(value.name(), " {}")
        var fields = [String(k.text(), ": ", format_value(v)) for k, v in value.pairs()]
        return String(value.name(), " { ", ", ".join(fields), " }")
    if kind == wv.ENUM:
        return value.text().copy()
    if kind == wv.HANDLE:
        return String("<", value.name(), " #", value.handle_id(), ">")
    if kind == wv.ERROR:
        return String(value.name(), ": ", value.text())
    if kind == wv.REAL:
        return _format_real(value)
    if kind == wv.QERR:
        return _format_qerr(value)
    raise Error("cannot format an invalid value")
