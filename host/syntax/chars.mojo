"""ASCII character classes, on a byte widened to `Int`."""


def is_digit(c: Int, *, hex: Bool = False) -> Bool:
    """A decimal digit, or a hexadecimal one when `hex`."""
    if ord("0") <= c <= ord("9"):
        return True
    return hex and (ord("a") <= c <= ord("f") or ord("A") <= c <= ord("F"))


def is_word_start(c: Int) -> Bool:
    """A letter or `_`, which may start a name."""
    return ord("a") <= c <= ord("z") or ord("A") <= c <= ord("Z") or c == ord("_")


def is_word_char(c: Int) -> Bool:
    return is_word_start(c) or is_digit(c)
