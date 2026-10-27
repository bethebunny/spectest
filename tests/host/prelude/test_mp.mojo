from std.testing import assert_equal, assert_true, assert_false, TestSuite

from numeric.bigint import BigInt
from numeric.formats import F16, F32, F64
from numeric.literal import parse_number
from numeric.real import Real
from prelude.mpfr import bundled_library
from prelude.testkit import Lcg, error_of, fl, rat, run, samples
from prelude.util import real_of, real_value
from wire.value import Value


def mp(name: String, x: Value) raises -> Real:
    return real_of(run("mp." + name, [x.copy()]), "test")


def dec(text: String) raises -> Real:
    return parse_number(text)


def close(got: Real, want: Real, bits: Int) raises -> Bool:
    """|got - want| <= 2**-bits * max(|want|, 1)."""
    var scale = abs(want.copy())
    if scale < Real(1):
        scale = Real(1)
    var tol = Real(BigInt(1), BigInt(1) << bits) * scale
    return abs(got - want) <= tol


def test_known_digits() raises:
    var tol = dec("1e-59")
    assert_true(abs(mp("cos", Value.int(1)) - dec("0.540302305868139717400936607442976603732310420617922227670097")) < tol)
    assert_true(abs(mp("sin", Value.int(1)) - dec("0.841470984807896506652502321630298999622563060798371065672751")) < tol)
    assert_true(abs(mp("sqrt", Value.int(2)) - dec("1.414213562373095048801688724209698078569671875376948073176679")) < tol)
    assert_true(abs(mp("exp", Value.int(1)) - dec("2.718281828459045235360287471352662497757247093699959574966967")) < tol)
    var half_pi = dec("1.570796326794896619231321691639751442098584699687552910487472")
    assert_true(abs(mp("atan", Value.real(BigInt(1), BigInt(0))) - half_pi) < tol)
    assert_true(abs(mp("atan", Value.real(BigInt(-1), BigInt(0))) + half_pi) < tol)
    assert_true(abs(mp("log", Value.int(2)) - dec("0.693147180559945309417232121458176568075500134360255254120680")) < tol)
    assert_true(abs(mp("atan", Value.int(1)) * Real(4) - dec("3.141592653589793238462643383279502884197169399375105820974944")) < tol)
    assert_true(abs(mp("tan", Value.int(1)) - dec("1.557407724654902230506974807458360173087250772381520038383946")) < tol)


def test_exact_cases() raises:
    assert_true(mp("sqrt", Value.int(4)) == Real(2))
    assert_true(mp("sqrt", rat(1, 4)) == Real(BigInt(1), BigInt(2)))
    assert_true(mp("sqrt", Value.int(0)) == Real(0))
    assert_true(mp("exp", Value.int(0)) == Real(1))
    assert_true(mp("log", Value.int(1)) == Real(0))
    assert_true(mp("sin", Value.int(0)) == Real(0))
    assert_true(mp("cos", Value.int(0)) == Real(1))
    assert_true(mp("tan", Value.int(0)) == Real(0))
    assert_true(mp("atan", Value.int(0)) == Real(0))
    assert_true(mp("sqrt", fl(F16, 0x4400)) == Real(2))
    assert_true(mp("exp", fl(F16, 0x8000)) == Real(1))


def test_infinite_inputs() raises:
    var inf = Real.infinity()
    assert_true(mp("exp", Value.real(BigInt(1), BigInt(0))) == inf)
    assert_true(mp("exp", Value.real(BigInt(-1), BigInt(0))) == Real(0))
    assert_true(mp("log", Value.real(BigInt(1), BigInt(0))) == inf)
    assert_true(mp("sqrt", Value.real(BigInt(1), BigInt(0))) == inf)
    assert_true(mp("exp", fl(F32, 0x7F800000)) == inf)
    assert_true(mp("atan", fl(F32, 0xFF800000)) < Real(0))


def test_domain_errors() raises:
    var inf = Value.real(BigInt(1), BigInt(0))
    var ninf = Value.real(BigInt(-1), BigInt(0))
    assert_true(error_of("mp.sqrt", [Value.int(-1)]).startswith("mp.sqrt: "))
    assert_true(error_of("mp.sqrt", [ninf.copy()]).startswith("mp.sqrt: "))
    assert_true(error_of("mp.log", [Value.int(0)]).startswith("mp.log: "))
    assert_true(error_of("mp.log", [Value.int(-3)]).startswith("mp.log: "))
    assert_true(error_of("mp.sin", [inf.copy()]).startswith("mp.sin: "))
    assert_true(error_of("mp.cos", [ninf.copy()]).startswith("mp.cos: "))
    assert_true(error_of("mp.tan", [inf.copy()]).startswith("mp.tan: "))
    assert_true("NaN" in error_of("mp.exp", [fl(F32, 0x7FC00000)]))
    assert_true(error_of("mp.exp", [Value.string("x")]).startswith("mp.exp: "))
    assert_true(error_of("mp.exp", []).startswith("mp.exp: "))


def test_results_outside_the_reference_range() raises:
    # Past 2**(2**18) the reference range ends: a finite input with such a result is an error.
    assert_true(error_of("mp.exp", [Value.int(1_000_000)]).startswith("mp.exp: "))
    assert_true(error_of("mp.exp", [Value.int(-1_000_000)]).startswith("mp.exp: "))
    # An input too large to represent at all.
    var huge = Value.int(BigInt(1) << 300000)
    assert_true(error_of("mp.sin", [huge.copy()]).startswith("mp.sin: "))
    # Large but representable.
    assert_true(mp("exp", Value.int(1000)) > Real(BigInt(1) << 1400))
    assert_true(mp("exp", Value.int(-1000)) < Real(BigInt(1), BigInt(1) << 1400))
    var tiny = mp("exp", Value.int(-100000))
    assert_true(tiny > Real(0))


def test_results_are_256_bit_dyadics() raises:
    for x in [1, 2, 3, 10, 12345]:
        for name in ["sqrt", "exp", "log", "sin", "cos", "tan", "atan"]:
            var r = mp(name, Value.int(x))
            if r.is_zero():
                continue
            var d = r.denominator.copy()
            # The denominator is a power of two (its bits less one are all zero below the top).
            assert_true(d == BigInt(1) << (d.bit_length() - 1))
            # The odd part of the numerator has at most 256 bits.
            var n = r.numerator.__abs__()
            var tz = 0
            while not n.magnitude.bit(tz):
                tz += 1
            assert_true(n.bit_length() - tz <= 256)


def test_identities() raises:
    var rng = Lcg()
    for _ in range(samples(20, 200)):
        var x = rat(rng.below(2000) - 1000, 1 + rng.below(997))
        var s = mp("sin", x)
        var c = mp("cos", x)
        assert_true(close(s * s + c * c, Real(1), 250))
        assert_true(close(mp("tan", x), s / c, 250))
        var pos = rat(1 + rng.below(5000), 1 + rng.below(97))
        var p = real_of(pos, "t")
        assert_true(close(mp("exp", real_value(mp("log", pos))), p.copy(), 249))
        var root = mp("sqrt", pos)
        assert_true(close(root * root, p.copy(), 249))
        var small = rat(rng.below(2001) - 1000, 1000 + rng.below(1000))
        assert_true(close(mp("atan", real_value(mp("tan", small))), real_of(small, "t"), 247))


def test_exp_adds() raises:
    var a = rat(1, 3)
    var b = rat(5, 7)
    var ab = real_value(real_of(a, "t") + real_of(b, "t"))
    assert_true(close(mp("exp", ab), mp("exp", a) * mp("exp", b), 250))


def test_the_bundled_library_is_found() raises:
    var path = bundled_library()
    assert_true(Bool(path))
    assert_true("libmpfr" in path.value())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
