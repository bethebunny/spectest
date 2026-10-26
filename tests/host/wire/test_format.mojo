from std.testing import assert_equal, TestSuite

from numeric.bigint import BigInt
from numeric.formats import F32, F64
from numeric.text import float_text
from wire.format import format_value
from wire.value import Value


def real(n: Int, d: Int) -> Value:
    return Value.real(BigInt(n), BigInt(d))


def check(value: Value, expected: String) raises:
    assert_equal(format_value(value), expected)


def test_scalars() raises:
    check(Value.bool(True), "true")
    check(Value.bool(False), "false")
    check(Value.int(-12), "-12")
    check(Value.int(BigInt.parse("100000000000000000000")), "100000000000000000000")
    check(Value.float(F64, 0x3FF0000000000000), float_text(4, 0x3FF0000000000000))
    check(Value.float(F32, 5), float_text(3, 5))


def test_strings() raises:
    check(Value.string(""), '""')
    check(Value.string("hi"), '"hi"')
    check(Value.string('a"b\\c'), '"a\\"b\\\\c"')
    check(Value.string("a\nb\tc\r"), '"a\\nb\\tc\\r"')
    check(Value.string("\u0001\u007f"), '"\\x01\\x7f"')
    check(Value.string("é中\U0001F600"), '"é中\U0001F600"')
    check(Value.string("�"), '"\\u{fffd}"')
    check(Value.string("\u0085"), '"\\u{85}"')
    check(Value.string("​"), '"\\u{200b}"')


def test_bytes() raises:
    check(Value.bytes([]), 'b""')
    check(Value.bytes([65, 10, 0, 127, 128, 255, 34, 92]), 'b"A\\n\\x00\\x7f\\x80\\xff\\"\\\\"')


def test_compound() raises:
    check(Value.list([]), "[]")
    check(Value.list([Value.int(1), Value.string("a")]), '[1, "a"]')
    check(Value.tuple([]), "()")
    check(Value.tuple([Value.int(1)]), "(1,)")
    check(Value.tuple([Value.int(1), Value.bool(True)]), "(1, true)")
    check(Value.map([], []), "{}")
    check(Value.map([Value.string("a"), Value.int(2)], [Value.int(1), Value.list([])]), '{"a": 1, 2: []}')
    check(Value.none(), "none")
    check(Value.some(Value.int(3)), "some(3)")
    check(Value.some(Value.some(Value.none())), "some(some(none))")
    check(Value.list([Value.tuple([Value.int(1)]), Value.none()]), "[(1,), none]")


def test_named() raises:
    check(Value.record("p.R", ["x", "y"], [Value.int(1), Value.string("s")]), 'p.R { x: 1, y: "s" }')
    check(Value.record("p.R", [], []), "p.R {}")
    check(Value.enum("p.E", "Red"), "Red")
    check(Value.enum("", "all"), "all")
    check(Value.handle(7, "p.Stack"), "<p.Stack #7>")
    check(Value.error("p.Oops", ["p.Base"], "bad thing"), "p.Oops: bad thing")


def test_real() raises:
    check(real(3, 1), "3")
    check(real(-3, 1), "-3")
    check(real(0, 1), "0")
    check(real(1, 0), "+inf")
    check(real(-1, 0), "-inf")
    check(real(1, 2), "0.5")
    check(real(-7, 2), "-3.5")
    check(real(1, 8), "0.125")
    check(real(1, 1000), "0.001")
    check(real(12345, 100), "123.45")
    check(real(1, 3), "1/3 (~0.33333333333333333333)")
    check(real(-2, 3), "-2/3 (~-0.66666666666666666667)")
    check(real(10, 3), "10/3 (~3.3333333333333333333)")
    check(real(1, 7), "1/7 (~0.14285714285714285714)")
    check(real(2000000, 3), "2000000/3 (~666666.66666666666667)")


def test_real_large() raises:
    var huge = Value.real(BigInt.parse("100000000000000000000000000000000001"), BigInt(3))
    check(huge, "~3.3333333333333333333e+34")
    var tiny = Value.real(BigInt(1), BigInt.parse("300000000000000000000000000000"))
    check(tiny, "~3.3333333333333333333e-30")
    var wide = Value.real(BigInt(1), BigInt.parse("1" + String("0") * 30))
    check(wide, "~1.0e-30")
    var exact_big = Value.real(BigInt(1), BigInt.parse("1" + String("0") * 20))
    check(exact_big, "0.00000000000000000001")


def test_qerr() raises:
    check(Value.qerr(BigInt(3), BigInt(0)), "3")
    check(Value.qerr(BigInt(0), BigInt(0)), "0")
    check(Value.qerr(BigInt(0), BigInt(2)), "2nan")
    check(Value.qerr(BigInt(3), BigInt(2)), "3 + 2nan")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
