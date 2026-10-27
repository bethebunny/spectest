from std.testing import assert_equal, assert_true, TestSuite

from eval_testkit import *
from wire.value import Value


def v(params: String, expr: String, var args: List[Value]) raises -> Value:
    return value_of(params, expr, args^)


def bad(params: String, expr: String, var args: List[Value], fragment: String) raises:
    var message = error_of(params, expr, args^)
    assert_true(fragment in message, "'" + fragment + "' not in '" + message + "'")


def is_(got: Value, want: Value) raises:
    assert_true(got == want, "got " + format_value(got) + ", wanted " + format_value(want))


def test_integer_add_sub_mul() raises:
    is_(v("a: int, b: int", "a + b", two(Value.int(3), Value.int(4))), Value.int(7))
    is_(v("a: int, b: int", "a - b", two(Value.int(3), Value.int(4))), Value.int(-1))
    is_(v("a: int, b: int", "a * b", two(Value.int(-3), Value.int(4))), Value.int(-12))
    is_(v("a: i8, b: u8", "a + b", two(Value.int(127), Value.int(255))), Value.int(382))
    is_(v("a: i64, b: i64", "a * b", two(Value.int(9223372036854775807), Value.int(9223372036854775807))), v("", "9223372036854775807 * 9223372036854775807", none_args()))
    is_(v("a: u64", "a + a", one(big("18446744073709551615"))), big("36893488147419103230"))


def test_fixed_width_arithmetic_never_overflows() raises:
    is_(v("a: i32", "a + 1", one(Value.int(2147483647))), Value.int(2147483648))
    is_(v("a: u8", "a - 1", one(Value.int(0))), Value.int(-1))
    is_(v("a: i64", "a * a", one(Value.int(-9223372036854775807 - 1))), big("85070591730234615865843651857942052864"))


def test_real_arithmetic_is_exact() raises:
    is_(v("", "1 / 3 + 1 / 6", none_args()), real_v(1, 2))
    is_(v("", "1 / 3 - 1 / 3", none_args()), real_v(0))
    is_(v("", "(2 / 3) * (3 / 4)", none_args()), real_v(1, 2))
    is_(v("b: int", "(1 / 3) * b", one(Value.int(3))), real_v(1))
    is_(v("a: int, b: int", "a / b", two(Value.int(1), Value.int(3))), real_v(1, 3))
    is_(v("a: int, b: int", "a / b", two(Value.int(-6), Value.int(4))), real_v(-3, 2))
    is_(v("", "(1 / 2) / (1 / 4)", none_args()), real_v(2))


def test_a_real_typed_whole_number_is_a_real() raises:
    is_(v("a: int", "a / 1", one(Value.int(4))), real_v(4))
    is_(v("", "[1, 0.5]", none_args()), Value.list(two(real_v(1), real_v(1, 2))))
    is_(v("", "if true then 1 else 0.5", none_args()), real_v(1))
    is_(v("", "sum(x in [1.5, 2.5]: x)", none_args()), real_v(4))
    is_(v("", "1 + 0.5", none_args()), real_v(3, 2))
    is_(v("", "max(x in [1, 2]: x / 2)", none_args()), real_v(1))


def test_float_arithmetic_promotes() raises:
    is_(v("x: f64, y: f64", "x + y", two(f64v(0.1), f64v(0.2))), v("", "0x1.999999999999ap-4 + 0x1.999999999999ap-3", none_args()))
    is_(v("x: f64", "x + 1", one(f64v(0.5))), real_v(3, 2))
    is_(v("x: f32, y: f64", "x * y", two(f32v(0.5), f64v(4.0))), real_v(2))
    is_(v("x: f64", "x / 2", one(f64v(1.0))), real_v(1, 2))
    is_(v("x: f64, y: f64", "x - y", two(f64v(1.0), f64v(1.0))), real_v(0))
    # The sum is exact, with no rounding to f64.
    is_(v("x: f64, y: f64", "(x + y) - x", two(f64v(1.0), f64v(1e-30))) ,
        v("y: f64", "y + 0", one(f64v(1e-30))))


def test_infinities_in_arithmetic() raises:
    is_(v("x: f64", "x + 1", one(inf64())), real_v(1, 0))
    is_(v("x: f64", "x * 2", one(inf64(True))), real_v(-1, 0))
    is_(v("x: f64", "1 / x", one(inf64())), real_v(0))
    bad("x: f64, y: f64", "x - y", two(inf64(), inf64()), "inf - inf")
    bad("x: f64", "x * 0", one(inf64()), "0 * inf")
    bad("x: f64, y: f64", "x / y", two(inf64(), inf64()), "inf / inf")


def test_nan_promotion_is_an_error() raises:
    bad("x: f64", "x + 1", one(nan64()), "NaN")
    bad("x: f64", "x < 1", one(nan64()), "NaN")
    bad("x: f64", "1 >= x", one(nan64()), "NaN")
    bad("x: f64", "real(x)", one(nan64()), "NaN")
    bad("x: f64", "-x + 1", one(nan64()), "NaN")
    bad("xs: list<f64>", "sum(x in xs: x)", one(Value.list(one(nan64()))), "NaN")


def test_floored_division_and_remainder() raises:
    is_(v("a: int, b: int", "a // b", two(Value.int(7), Value.int(2))), Value.int(3))
    is_(v("a: int, b: int", "a // b", two(Value.int(-7), Value.int(2))), Value.int(-4))
    is_(v("a: int, b: int", "a // b", two(Value.int(7), Value.int(-2))), Value.int(-4))
    is_(v("a: int, b: int", "a // b", two(Value.int(-7), Value.int(-2))), Value.int(3))
    is_(v("a: int, b: int", "a % b", two(Value.int(7), Value.int(2))), Value.int(1))
    is_(v("a: int, b: int", "a % b", two(Value.int(-7), Value.int(2))), Value.int(1))
    is_(v("a: int, b: int", "a % b", two(Value.int(7), Value.int(-2))), Value.int(-1))
    is_(v("a: int, b: int", "a % b", two(Value.int(-7), Value.int(-2))), Value.int(-1))
    is_(v("a: i32, b: u8", "a % b", two(Value.int(-1), Value.int(7))), Value.int(6))
    is_(v("a: int, b: int", "a // b", two(big("100000000000000000000"), Value.int(7))), big("14285714285714285714"))


def test_division_by_zero() raises:
    bad("a: int, b: int", "a // b", two(Value.int(1), Value.int(0)), "division by zero")
    bad("a: int, b: int", "a % b", two(Value.int(1), Value.int(0)), "division by zero")
    bad("a: int, b: int", "a / b", two(Value.int(1), Value.int(0)), "division by zero")
    bad("", "(1 / 2) / (1 - 1)", none_args(), "division by zero")
    bad("x: f64", "1 / x", one(Value.float(F64, UInt64(0))), "division by zero")
    bad("x: f64", "1 / x", one(Value.float(F64, UInt64(0x8000000000000000))), "division by zero")


def test_power() raises:
    is_(v("a: int, b: int", "a ** b", two(Value.int(2), Value.int(10))), Value.int(1024))
    is_(v("a: int, b: int", "a ** b", two(Value.int(-2), Value.int(3))), Value.int(-8))
    is_(v("a: int, b: int", "a ** b", two(Value.int(-2), Value.int(2))), Value.int(4))
    is_(v("a: int, b: int", "a ** b", two(Value.int(0), Value.int(0))), Value.int(1))
    is_(v("a: int, b: int", "a ** b", two(Value.int(0), Value.int(5))), Value.int(0))
    is_(v("a: int, b: int", "a ** b", two(Value.int(2), Value.int(100))), big("1267650600228229401496703205376"))
    is_(v("a: int, b: int", "a ** b", two(Value.int(-1), Value.int(1000001))), Value.int(-1))
    is_(v("a: int, b: int", "a ** b", two(Value.int(1), big("100000000000000000000"))), Value.int(1))
    is_(v("", "2 ** 3 ** 2", none_args()), Value.int(512))
    is_(v("", "-2 ** 2", none_args()), Value.int(-4))
    bad("a: int, b: int", "a ** b", two(Value.int(2), Value.int(-1)), "non-negative exponent")
    bad("a: int, b: int", "a ** b", two(Value.int(2), Value.int(100000000)), "too large")


def test_shifts() raises:
    is_(v("a: int, b: int", "a << b", two(Value.int(1), Value.int(70))), big("1180591620717411303424"))
    is_(v("a: int, b: int", "a << b", two(Value.int(-3), Value.int(2))), Value.int(-12))
    is_(v("a: int, b: int", "a >> b", two(Value.int(20), Value.int(2))), Value.int(5))
    is_(v("a: int, b: int", "a >> b", two(Value.int(-5), Value.int(1))), Value.int(-3))
    is_(v("a: int, b: int", "a >> b", two(Value.int(5), Value.int(100))), Value.int(0))
    is_(v("a: int, b: int", "a >> b", two(Value.int(-5), Value.int(100))), Value.int(-1))
    is_(v("a: u8, b: u8", "a << b", two(Value.int(255), Value.int(8))), Value.int(65280))
    bad("a: int, b: int", "a << b", two(Value.int(1), Value.int(-1)), "non-negative shift")
    bad("a: int, b: int", "a >> b", two(Value.int(1), Value.int(-1)), "non-negative shift")
    bad("a: int, b: int", "a << b", two(Value.int(1), big("100000000000000000000")), "too large")


def test_bit_operations() raises:
    is_(v("a: int, b: int", "a & b", two(Value.int(12), Value.int(10))), Value.int(8))
    is_(v("a: int, b: int", "a | b", two(Value.int(12), Value.int(10))), Value.int(14))
    is_(v("a: int, b: int", "a & b", two(Value.int(-1), Value.int(255))), Value.int(255))
    is_(v("a: int, b: int", "a & b", two(Value.int(-8), Value.int(-3))), Value.int(-8))
    is_(v("a: int, b: int", "a | b", two(Value.int(-8), Value.int(3))), Value.int(-5))
    is_(v("a: int, b: int", "a | b", two(Value.int(-8), Value.int(-3))), Value.int(-3))
    is_(v("a: u8, b: u8", "a & b", two(Value.int(0xF0), Value.int(0x3C))), Value.int(0x30))
    # Beyond 64 bits.
    var x = big("340282366920938463463374607431768211455")
    is_(v("a: int, b: int", "a & b", two(x.copy(), Value.int(255))), Value.int(255))
    is_(v("a: int, b: int", "a & b", two(x.copy(), Value.int(-1))), x.copy())
    is_(v("a: int, b: int", "a | b", two(x.copy(), Value.int(-256))), Value.int(-1))
    is_(v("a: int, b: int", "a | b", two(Value.int(1), big("340282366920938463463374607431768211456"))), big("340282366920938463463374607431768211457"))
    is_(v("a: int, b: int", "a & b", two(big("-340282366920938463463374607431768211456"), big("-1"))), big("-340282366920938463463374607431768211456"))


def test_unary_minus() raises:
    is_(v("a: int", "-a", one(Value.int(5))), Value.int(-5))
    is_(v("a: i8", "-a", one(Value.int(-128))), Value.int(128))
    is_(v("", "-(1 / 2)", none_args()), real_v(-1, 2))
    is_(v("x: f64", "-real(x)", one(inf64())), real_v(-1, 0))
    is_(v("", "- -3", none_args()), Value.int(3))


def test_unary_minus_on_floats_flips_the_sign_bit() raises:
    is_(v("x: f64", "-x", one(f64v(1.5))), f64v(-1.5))
    is_(v("x: f64", "-x", one(f64v(0.0))), f64v(-0.0))
    is_(v("x: f64", "-x", one(f64v(-0.0))), f64v(0.0))
    is_(v("x: f32", "-x", one(f32v(2.0))), f32v(-2.0))
    is_(v("x: f64", "-x", one(nan64())), Value.float(F64, UInt64(0xFFF8000000000000)))
    is_(v("x: f64", "-x", one(inf64())), inf64(True))
    is_(v("x: f64", "- -x", one(f64v(3.0))), f64v(3.0))


def test_comparisons_across_types() raises:
    is_(v("a: i8, b: u64", "a < b", two(Value.int(-1), Value.int(0))), Value.bool(True))
    is_(v("a: int", "a < 3 / 2", one(Value.int(1))), Value.bool(True))
    is_(v("", "1 / 3 <= 1 / 3", none_args()), Value.bool(True))
    is_(v("x: f64, y: f32", "x < y", two(f64v(1.0), f32v(1.5))), Value.bool(True))
    is_(v("x: f64", "x < 1", one(inf64())), Value.bool(False))
    is_(v("x: f64", "x > 1000000000000000000000", one(inf64())), Value.bool(True))
    is_(v("x: f64", "x < 0", one(inf64(True))), Value.bool(True))
    is_(v("x: f64, y: f64", "x < y", two(inf64(), inf64())), Value.bool(False))
    is_(v("x: f64, y: f64", "x <= y", two(inf64(), inf64())), Value.bool(True))
    is_(v("x: f64, y: f64", "x >= y", two(f64v(0.0), f64v(-0.0))), Value.bool(True))
    is_(v("x: f64, y: f64", "x <= y", two(f64v(0.0), f64v(-0.0))), Value.bool(True))
    is_(v("x: f64, y: f64", "real(x) == real(y)", two(f64v(0.0), f64v(-0.0))), Value.bool(True))
    is_(v("x: f64", "same(x, x)", one(nan64())), Value.bool(True))


def test_huge_literals_and_exact_decimals() raises:
    is_(v("", "123456789012345678901234567890 + 1", none_args()), big("123456789012345678901234567891"))
    is_(v("", "0.1 + 0.2 == 0.3", none_args()), Value.bool(True))
    is_(v("", "1e3", none_args()), real_v(1000))
    is_(v("", "1e-3", none_args()), real_v(1, 1000))
    is_(v("", "0x1.8p3", none_args()), real_v(12))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
