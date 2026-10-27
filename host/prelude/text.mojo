"""Bytes and text: `valid_utf8` (Table 3-7 of the Unicode Standard), `codepoints`, `from_codepoints`.

No codec is involved, so a spec can judge one.
"""

from gen.scalars import append_utf8
from prelude.util import fail, list_items
from wire.value import Value, BYTES, STRING, INT


def _lead_form(lead: Int) -> Optional[Tuple[Int, Int, Int]]:
    """The range of the second byte and the number of trailing bytes after a lead byte."""
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
        raise fail("valid_utf8", t"expected bytes, got {b}")
    ref data = b.data()
    var n = len(data)
    var i = 0
    while i < n:
        var lead = Int(data[i])
        if lead < 0x80:
            i += 1
            continue
        var form = _lead_form(lead)
        if form is None:
            return Value.bool(False)
        var lo, hi, trail = form.value()
        if i + trail >= n or not (lo <= Int(data[i + 1]) <= hi):
            return Value.bool(False)
        for k in range(2, trail + 1):
            if not (0x80 <= Int(data[i + k]) <= 0xBF):
                return Value.bool(False)
        i += 1 + trail
    return Value.bool(True)


def codepoints(s: Value) raises -> Value:
    """The scalar values of a string, decoded by hand."""
    if s.kind != STRING:
        raise fail("codepoints", t"expected a string, got {s}")
    var bytes = s.text().as_bytes()
    var out: List[Value] = []
    var i = 0
    while i < len(bytes):
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
    """The string of Unicode scalar values (a surrogate or a value past 0x10FFFF is an error)."""
    var items = list_items(cps, "from_codepoints")
    var data = List[UInt8](capacity=len(items))
    for item in items:
        if item.kind != INT:
            raise fail("from_codepoints", t"expected an integer, got {item}")
        var small = item.small_int()
        if small is None:
            raise fail("from_codepoints", t"{item} is not a code point")
        var c = small.value()
        if c < 0 or c > 0x10FFFF or (0xD800 <= c <= 0xDFFF):
            raise fail("from_codepoints", t"{c} is not a Unicode scalar value")
        append_utf8(data, c)
    return Value.string(String(unsafe_from_utf8=Span(data)))
