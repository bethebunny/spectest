from std.testing import assert_equal, assert_true, TestSuite

from numeric.floats import is_inf, is_nan, is_zero, round_to, signbit, to_real
from numeric.formats import BF16, F16, F32, F64, FloatFormat
from numeric.literal import parse_number
from numeric.real import Real
from numeric.text import float_text, shortest_digits


def pow10_real(k: Int) raises -> Real:
    return parse_number("1e" + String(k))


def check_pattern(format: FloatFormat, bits: UInt64) raises:
    """The pattern converts to a real and back, its text reads back to it, and no
    decimal with fewer digits than the text does."""
    if is_nan(format, bits):
        return
    var r = to_real(format, bits)
    var expected = bits
    if is_zero(format, bits):
        expected = 0  # a real zero is unsigned
    assert_equal(round_to(format, r), expected, "round trip of " + String(bits))
    var text = float_text(format.id, bits)
    if is_inf(format, bits) or is_zero(format, bits):
        return
    var negative = signbit(format, bits)
    var body = String(text[byte=1:]) if negative else text
    var back = parse_number(body)
    if negative:
        back = -back
    assert_equal(round_to(format, back), bits, "text " + text + " reads back")
    # No shorter decimal reads back: the two neighbours of |r| on the grid of one
    # digit fewer round to some other pattern.
    var shortest = shortest_digits(format, bits)
    var n = shortest[0].byte_length()
    if n == 1:
        return
    var a = abs(r)
    var k = shortest[1]
    if a < pow10_real(k):
        k -= 1
    var scale = pow10_real(k - (n - 1) + 1)
    var lo = (a / scale).floor()
    var hi = lo + 1
    var target = bits & ~format.sign_mask()
    assert_true(
        round_to(format, Real(lo.copy()) * scale) != target,
        "shorter decimal below " + text,
    )
    assert_true(
        round_to(format, Real(hi.copy()) * scale) != target,
        "shorter decimal above " + text,
    )


struct Rng:
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        var x = self.state
        x ^= x >> 29
        return x * 0xBF58476D1CE4E5B9 ^ (self.state >> 17)


def sweep(format: FloatFormat) raises:
    for b in range(1 << format.width()):
        check_pattern(format, UInt64(b))


def test_f16() raises:
    sweep(F16)


def test_bf16() raises:
    sweep(BF16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
