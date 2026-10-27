"""ASCII character classes, on a byte widened to `Int`."""


def is_digit(c: Int) -> Bool:
    return ord("0") <= c <= ord("9")


def is_hex(c: Int) -> Bool:
    return is_digit(c) or ord("a") <= c <= ord("f") or ord("A") <= c <= ord("F")


def is_alpha(c: Int) -> Bool:
    return ord("a") <= c <= ord("z") or ord("A") <= c <= ord("Z") or c == ord("_")


def is_alnum(c: Int) -> Bool:
    return is_alpha(c) or is_digit(c)


def is_space(c: Int) -> Bool:
    return c == ord(" ") or c == ord("\t") or c == 11 or c == 12


def hex_value(c: Int) -> Int:
    return c - (ord("0") if is_digit(c) else (ord("a") - 10 if c >= ord("a") else ord("A") - 10))
