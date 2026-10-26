"""Pattern text, like `?111.11??.*.*`, expanded to one character per bit."""


def _is_bit_symbol(b: UInt8) -> Bool:
    return Int(b) == ord("0") or Int(b) == ord("1") or Int(b) == ord("?")


def expand_pattern(text: StringSlice) raises -> String:
    """The bits of `text`, most significant first, one `0`, `1` or `?` per bit.

    Quartets of 4 bits are separated by `.`; `*` fills out its quartet with `?`; only the
    leading quartet may be shorter than 4 bits.
    """
    var stripped = text.strip()
    if stripped.find("|") >= 0:
        raise Error("patterns can't contain '|'")
    var bits = String()
    var at = 0
    for quartet in stripped.split("."):
        var star = quartet.find("*")
        var expanded: String
        if star >= 0:
            var head = quartet[byte=0:star]
            var tail = quartet[byte = star + 1 :]
            var fill = 4 - head.byte_length() - tail.byte_length()
            expanded = String(head)
            for _ in range(fill):
                expanded += "?"
            expanded += tail
        else:
            expanded = String(quartet)
        var n = expanded.byte_length()
        var ok = (n >= 1 and n <= 4) if at == 0 else n == 4
        if ok:
            for b in expanded.as_bytes():
                if not _is_bit_symbol(b):
                    ok = False
        if not ok:
            raise Error(
                "bad quartet '"
                + String(quartet)
                + "' in pattern '"
                + String(stripped)
                + "': quartets are 4 bits of 0, 1 or ?, and * fills out the"
                " rest; only the leading quartet can be shorter"
            )
        bits += expanded
        at += 1
    return bits
