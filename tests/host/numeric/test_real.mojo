from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from numeric.bigint import BigInt
from numeric.real import Real


def frac(n: Int, d: Int) raises -> Real:
    return Real(BigInt(n), BigInt(d))


def test_lowest_terms() raises:
    var r = frac(6, -4)
    assert_equal(r.numerator, BigInt(-3))
    assert_equal(r.denominator, BigInt(2))
    assert_equal(frac(0, -7), Real())
    assert_equal(frac(0, -7).denominator, BigInt(1))
    assert_equal(String(frac(10, 5)), "2")
    assert_equal(String(frac(1, 3)), "1/3")
    with assert_raises():
        _ = frac(1, 0)


def test_arithmetic() raises:
    assert_equal(frac(1, 2) + frac(1, 3), frac(5, 6))
    assert_equal(frac(1, 2) - frac(1, 3), frac(1, 6))
    assert_equal(frac(2, 3) * frac(3, 4), frac(1, 2))
    assert_equal(frac(2, 3) / frac(4, 9), frac(3, 2))
    assert_equal(frac(2, 3) / frac(-4, 9), frac(-3, 2))
    assert_equal(-frac(2, 3), frac(-2, 3))
    assert_equal(abs(frac(-2, 3)), frac(2, 3))
    assert_equal(frac(1, 2) + frac(-1, 2), Real())
    assert_equal((frac(1, 2) + frac(-1, 2)).denominator, BigInt(1))
    with assert_raises():
        _ = frac(1, 2) / Real()


def test_infinities() raises:
    var inf = Real.infinity()
    var ninf = Real.infinity(True)
    assert_true(inf.is_inf() and ninf.is_inf())
    assert_equal(inf.numerator, BigInt(1))
    assert_equal(ninf.numerator, BigInt(-1))
    assert_equal(inf.denominator, BigInt(0))
    assert_equal(-inf, ninf)
    assert_equal(inf + frac(1, 2), inf)
    assert_equal(frac(1, 2) - inf, ninf)
    assert_equal(inf + inf, inf)
    assert_equal(inf - ninf, inf)
    assert_equal(inf * frac(-1, 2), ninf)
    assert_equal(ninf * ninf, inf)
    assert_equal(inf / frac(-1, 2), ninf)
    assert_equal(frac(5, 2) / inf, Real())
    assert_equal(abs(ninf), inf)
    assert_equal(String(inf), "inf")
    assert_equal(String(ninf), "-inf")
    with assert_raises():
        _ = inf - inf
    with assert_raises():
        _ = inf + ninf
    with assert_raises():
        _ = Real() * inf
    with assert_raises():
        _ = inf / inf
    with assert_raises():
        _ = inf.floor()
    with assert_raises():
        _ = ninf.ceil()


def test_order() raises:
    var inf = Real.infinity()
    var ninf = Real.infinity(True)
    assert_true(ninf < frac(-10, 1))
    assert_true(frac(10, 1) < inf)
    assert_true(ninf < inf)
    assert_false(inf < inf)
    assert_false(inf < ninf)
    assert_true(frac(1, 3) < frac(1, 2))
    assert_true(frac(-1, 2) < frac(-1, 3))
    assert_true(frac(1, 2) >= frac(1, 2))
    assert_true(inf > frac(1, 2))
    assert_true(ninf <= ninf)
    assert_true(frac(1, 2) != frac(1, 3))


def test_integer_rounding() raises:
    assert_equal(frac(7, 2).floor(), BigInt(3))
    assert_equal(frac(7, 2).ceil(), BigInt(4))
    assert_equal(frac(-7, 2).floor(), BigInt(-4))
    assert_equal(frac(-7, 2).ceil(), BigInt(-3))
    assert_equal(frac(4, 1).floor(), BigInt(4))
    assert_equal(frac(-4, 1).ceil(), BigInt(-4))
    assert_true(frac(4, 1).is_integer())
    assert_false(frac(4, 3).is_integer())
    assert_false(Real.infinity().is_integer())
    assert_equal(frac(-4, 3).sign(), -1)
    assert_equal(Real().sign(), 0)
    assert_equal(Real.infinity().sign(), 1)


def test_big() raises:
    var big = Real(BigInt.parse("123456789012345678901234567890"))
    assert_equal((big * big) / big, big)
    assert_equal(String(big + Real(1)), "123456789012345678901234567891")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
