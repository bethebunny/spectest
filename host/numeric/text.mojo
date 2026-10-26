"""Text of numbers, as reports print them.

`float_text` is a placeholder until the numeric work lands: it writes the format and
the bit pattern in hex, which is exact but not readable. Its signature is the
contract; the final version writes the shortest decimal that reads back to the same
value in its format.
"""

from numeric.formats import format_by_id


def float_text(format_id: UInt8, bits: UInt64) raises -> String:
    var format = format_by_id(format_id)
    return String(format.name(), "(", hex(bits), ")")
