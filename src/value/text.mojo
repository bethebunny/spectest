"""Text of values, as reports show them.

Strings and bytes are quoted with escapes, lists are `[a, b]`, tuples `(a, b)` and
`(a,)`, maps `{k: v}`, options `none` and `some(x)`, records `Name { f: v }`, enum
members by their name, handles `<Class #id>`, errors `Class: message`. Reals print
as exact decimals when short and terminating, else as a ratio with an approximation.
A qerr prints as `3`, `2nan` or `3 + 2nan`.
"""

from value.digits import hex_digits
from value.number_text import approximate_decimal, exact_decimal, float_text
from value.value import Value


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
        case control if control < 0x20 or control == 0x7F:
            return String("\\x", hex_digits(UInt64(control), width=2))
        case _:
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


def _format_real(value: Value) -> String:
    var real = value.as_real()
    if real.is_inf():
        return "+inf" if real.numerator.sign() > 0 else "-inf"
    if real.is_integer():
        return String(real.numerator)
    var sign = "-" if real.numerator.negative else ""
    var magnitude = abs(real)
    if case .Some(exact) = exact_decimal(magnitude, limit=25):
        return String(sign, exact)
    var approximation = String("~", sign, approximate_decimal(magnitude, digits=20))
    var ratio = String(real.numerator, "/", real.denominator)
    # A long ratio tells a reader no more than the approximation does.
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
    match value.kind:
        case .BOOL:
            return "true" if value.as_bool() else "false"
        case .INT:
            return String(value.as_bigint())
        case .FLOAT:
            return float_text(value.float_format_id(), value.float_bits())
        case .STRING:
            return _quote(value.text())
        case .BYTES:
            return _quote_bytes(value.data())
        case .LIST:
            return String("[", ", ".join([format_value(item) for item in value.items()]), "]")
        case .TUPLE:
            var items = ", ".join([format_value(item) for item in value.items()])
            return String("(", items, "," if value.count() == 1 else "", ")")
        case .MAP:
            var pairs = [String(format_value(k), ": ", format_value(v)) for k, v in value.pairs()]
            return String("{", ", ".join(pairs), "}")
        case .OPTION:
            return String("some(", format_value(value.item(0)), ")") if value.count() > 0 else "none"
        case .RECORD:
            if value.count() == 0:
                return String(value.name(), " {}")
            var fields = [String(k.text(), ": ", format_value(v)) for k, v in value.pairs()]
            return String(value.name(), " { ", ", ".join(fields), " }")
        case .ENUM:
            return value.text().copy()
        case .HANDLE:
            return String("<", value.name(), " #", value.handle_id(), ">")
        case .ERROR:
            return value.error_text()
        case .REAL:
            return _format_real(value)
        case .QERR:
            return _format_qerr(value)
        case .INVALID:
            raise Error("cannot format an invalid value")
