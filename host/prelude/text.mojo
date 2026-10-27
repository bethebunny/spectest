"""Bytes and text: `valid_utf8` (Table 3-7 of the Unicode Standard), `codepoints`,
`from_codepoints`. No codec is involved, so a spec can judge one."""

from numeric.bigint import BigInt
from prelude.util import describe, fail, list_items
from wire.value import Value, BYTES, STRING, INT


def _lead_form(lead: Int) -> Optional[Tuple[Int, Int, Int]]:
    """For a lead byte of 0x80 or more: the range of the second byte and the number of
    trailing bytes, or None when no well-formed sequence starts with it."""
    if 0xC2 <= lead <= 0xDF:
        return (0x80, 0xBF, 1)
    if lead == 0xE0:
        return (0xA0, 0xBF, 2)
    if (0xE1 <= lead <= 0xEC) or lead == 0xEE or lead == 0xEF:
        return (0x80, 0xBF, 2)
    if lead == 0xED:
        return (0x80, 0x9F, 2)
    if lead == 0xF0:
        return (0x90, 0xBF, 3)
    if 0xF1 <= lead <= 0xF3:
        return (0x80, 0xBF, 3)
    if lead == 0xF4:
        return (0x80, 0x8F, 3)
    return None


def valid_utf8(b: Value) raises -> Value:
    if b.kind != BYTES:
        raise fail("valid_utf8", "expected bytes, got " + describe(b))
    ref data = b.data()
    var n = len(data)
    var i = 0
    while i < n:
        var lead = Int(data[i])
        if lead < 0x80:
            i += 1
            continue
        var form = _lead_form(lead)
        if not form:
            return Value.bool(False)
        var lo = form.value()[0]
        var hi = form.value()[1]
        var trail = form.value()[2]
        if i + trail >= n:
            return Value.bool(False)
        var second = Int(data[i + 1])
        if second < lo or second > hi:
            return Value.bool(False)
        for k in range(2, trail + 1):
            var c = Int(data[i + k])
            if c < 0x80 or c > 0xBF:
                return Value.bool(False)
        i += 1 + trail
    return Value.bool(True)


def codepoints(s: Value) raises -> Value:
    """Decodes by hand: the scalar values of a string, in order."""
    if s.kind != STRING:
        raise fail("codepoints", "expected a string, got " + describe(s))
    var bytes = s.text().as_bytes()
    var out = List[Value]()
    var i = 0
    var n = len(bytes)
    while i < n:
        var c = Int(bytes[i])
        var extra = 0
        var value = c
        if c >= 0xF0:
            extra = 3
            value = c & 0x07
        elif c >= 0xE0:
            extra = 2
            value = c & 0x0F
        elif c >= 0xC0:
            extra = 1
            value = c & 0x1F
        for k in range(1, extra + 1):
            value = (value << 6) | (Int(bytes[i + k]) & 0x3F)
        out.append(Value.int(value))
        i += 1 + extra
    return Value.list(out^)


def from_codepoints(cps: Value) raises -> Value:
    """The string of the given Unicode scalar values. A surrogate or a value outside
    0 to 0x10FFFF is an error."""
    var items = list_items(cps, "from_codepoints")
    var data = List[UInt8](capacity=len(items))
    for i in range(len(items)):
        if items[i].kind != INT:
            raise fail("from_codepoints", "expected an integer, got " + describe(items[i]))
        var small = items[i].small_int()
        if not small:
            raise fail("from_codepoints", describe(items[i]) + " is not a code point")
        var c = small.value()
        if c < 0 or c > 0x10FFFF or (0xD800 <= c <= 0xDFFF):
            raise fail("from_codepoints", String(c) + " is not a Unicode scalar value")
        if c < 0x80:
            data.append(UInt8(c))
        elif c < 0x800:
            data.append(UInt8(0xC0 | (c >> 6)))
            data.append(UInt8(0x80 | (c & 0x3F)))
        elif c < 0x10000:
            data.append(UInt8(0xE0 | (c >> 12)))
            data.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
            data.append(UInt8(0x80 | (c & 0x3F)))
        else:
            data.append(UInt8(0xF0 | (c >> 18)))
            data.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
            data.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
            data.append(UInt8(0x80 | (c & 0x3F)))
    return Value.string(String(unsafe_from_utf8=Span(data)))
