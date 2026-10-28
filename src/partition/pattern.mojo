"""Pattern text, like `?111.11??.*.*`, expanded to one character per bit."""


def _is_bit_symbol(b: UInt8) -> Bool:
    return Int(b) in [ord("0"), ord("1"), ord("?")]


def expand_pattern(text: StringSlice) raises -> String:
    """The bits of `text`, most significant first, one `0`, `1` or `?` per bit.

    Quartets of 4 bits are separated by `.`; `*` fills out its quartet with `?`; only the
    leading quartet may be shorter than 4 bits.
    """
    var stripped = text.strip()
    if "|" in stripped:
        raise Error("patterns can't contain '|'")
    var bits = String()
    for at, quartet in enumerate(stripped.split(".")):
        var star = quartet.find("*")
        var expanded = (
            String(quartet[byte=0:star], "?" * (5 - quartet.byte_length()), quartet[byte = star + 1 :])
            if star >= 0
            else String(quartet)
        )
        var n = expanded.byte_length()
        var length_ok = 1 <= n <= 4 if at == 0 else n == 4
        if not length_ok or not all([_is_bit_symbol(b) for b in expanded.as_bytes()]):
            raise Error(
                t"bad quartet '{quartet}' in pattern '{stripped}': quartets are 4 bits"
                t" of 0, 1 or ?, and * fills out the rest; only the leading quartet"
                t" can be shorter"
            )
        bits += expanded
    return bits
