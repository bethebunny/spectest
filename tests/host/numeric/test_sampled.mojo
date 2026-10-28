from std.os import getenv
from std.testing import assert_equal, assert_true, TestSuite

from value.floats import is_inf, is_nan, is_zero, round_to, signbit, to_real
from value.float_formats import BF16, F16, F32, F64, FloatFormat
from value.literal import parse_number
from value.real import Real
from value.number_text import float_text, shortest_digits


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


def samples() -> Int:
    """100,000 patterns per format at full strength, 5,000 in the dev loop."""
    return 100_000 if getenv("SPECTEST_STRENGTH") == "full" else 5_000


def sample(format: FloatFormat, seed: UInt64) raises:
    var rng = Rng(seed)
    var mask = (UInt64(1) << UInt64(format.width())) - 1 if format.width() < 64 else UInt64.MAX
    for _ in range(samples()):
        check_pattern(format, rng.next() & mask)
    # Patterns near the extremes, which random bits rarely reach.
    for k in range(64):
        var bits = UInt64(k)
        check_pattern(format, bits)
        check_pattern(format, bits | format.sign_mask())
        check_pattern(format, format.exponent_mask() - bits)
        check_pattern(format, (format.exponent_mask() - bits) | format.sign_mask())
        check_pattern(format, (UInt64(1) << UInt64(format.fraction_bits)) + bits)


def test_f32() raises:
    sample(F32, 1)


def test_f64() raises:
    sample(F64, 2)


def parse_decimal(text: StringSlice) -> UInt64:
    var value = UInt64(0)
    for b in text.as_bytes():
        value = value * 10 + UInt64(Int(b) - ord("0"))
    return value


def test_f64_matches_python_repr() raises:
    """tests/host/numeric/data/f64_repr.txt is written by gen_f64_repr.py."""
    var lines = open("tests/host/numeric/data/f64_repr.txt", "r").read().split("\n")
    var count = 0
    for line in lines:
        if line.byte_length() == 0:
            continue
        var parts = line.split(" ")
        var bits = parse_decimal(parts[0])
        assert_equal(float_text(4, bits), String(parts[1]))
        count += 1
    assert_true(count > 5000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
