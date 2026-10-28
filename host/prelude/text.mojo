"""Bytes and text: `valid_utf8`, `codepoints`, `from_codepoints`."""

from prelude.util import fail, list_items
from value.value import Value


def valid_utf8(b: Value) raises -> Value:
    if b.kind != .BYTES:
        raise fail("valid_utf8", t"expected bytes, got {b}")
    try:
        _ = StringSlice(from_utf8=Span(b.data()))
    except:
        return Value.bool(False)
    return Value.bool(True)


def codepoints(s: Value) raises -> Value:
    if s.kind != .STRING:
        raise fail("codepoints", t"expected a string, got {s}")
    return Value.list([Value.int(Int(cp.to_u32())) for cp in s.text().codepoints()])


def from_codepoints(cps: Value) raises -> Value:
    """The string of Unicode scalar values (a surrogate or a value past 0x10FFFF is an error)."""
    var text = String()
    for item in list_items(cps, "from_codepoints"):
        if item.kind != .INT:
            raise fail("from_codepoints", t"expected an integer, got {item}")
        var small = item.small_int()
        if small is None:
            raise fail("from_codepoints", t"{item} is not a code point")
        var c = small.value()
        # from_u32 refuses surrogates and values past 0x10FFFF, but a UInt32 would wrap.
        var cp = Codepoint.from_u32(UInt32(c)) if 0 <= c <= 0x10FFFF else None
        if cp is None:
            raise fail("from_codepoints", t"{c} is not a Unicode scalar value")
        text += String(cp.value())
    return Value.string(text^)
