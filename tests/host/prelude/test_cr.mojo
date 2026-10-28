from std.math import atan, cos, log, sin, sqrt, tan
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from spec.types import Types
from value.bigint import BigInt
from value.float_formats import FloatFormat, F16, BF16, F32, F64, format_by_id
from prelude_testkit import Lcg, bitcast_f64, error_of, f64v, fl, formats, rat, run, run_typed, samples
from value.value import Value

def names() -> List[String]:
    return ["sqrt", "exp", "log", "sin", "cos", "tan", "atan"]


def cr(name: String, x: Value) raises -> Value:
    return run("cr." + name, [x.copy()])


def nan_of(f: FloatFormat) -> Value:
    return fl(f, f.exponent_mask() | (UInt64(1) << UInt64(f.fraction_bits - 1)))


def inf_of(f: FloatFormat, negative: Bool = False) -> Value:
    return fl(f, f.exponent_mask() | (f.sign_mask() if negative else UInt64(0)))


def zero_of(f: FloatFormat, negative: Bool = False) -> Value:
    return fl(f, f.sign_mask() if negative else UInt64(0))


def one_of(f: FloatFormat, negative: Bool = False) -> Value:
    var bits = UInt64(f.bias()) << UInt64(f.fraction_bits)
    return fl(f, bits | (f.sign_mask() if negative else UInt64(0)))


def test_special_cases() raises:
    for f in formats():
        var nan = nan_of(f)
        var inf = inf_of(f)
        var ninf = inf_of(f, True)
        var zero = zero_of(f)
        var nzero = zero_of(f, True)
        var one = one_of(f)
        var minus_one = one_of(f, True)
        var odd_nan = fl(f, f.exponent_mask() | f.sign_mask() | 1)
        for name in names():
            assert_true(cr(name, odd_nan.copy()) == nan)
            assert_true(cr(name, nan.copy()) == nan)
        for name in ["sin", "cos", "tan"]:
            assert_true(cr(name, inf.copy()) == nan and cr(name, ninf.copy()) == nan)
        assert_true(cr("sqrt", minus_one.copy()) == nan and cr("sqrt", ninf.copy()) == nan)
        assert_true(cr("sqrt", nzero.copy()) == nzero and cr("sqrt", zero.copy()) == zero)
        assert_true(cr("sqrt", inf.copy()) == inf)
        assert_true(cr("log", zero.copy()) == ninf and cr("log", nzero.copy()) == ninf)
        assert_true(cr("log", minus_one.copy()) == nan and cr("log", ninf.copy()) == nan)
        assert_true(cr("log", inf.copy()) == inf and cr("log", one.copy()) == zero)
        assert_true(cr("exp", inf.copy()) == inf and cr("exp", ninf.copy()) == zero)
        assert_true(cr("exp", zero.copy()) == one and cr("exp", nzero.copy()) == one)
        assert_true(cr("exp", fl(f, f.exponent_mask() - 1)) == inf)
        assert_true(cr("exp", fl(f, (f.exponent_mask() - 1) | f.sign_mask())) == zero)
        for name in ["sin", "tan", "atan"]:
            assert_true(cr(name, nzero.copy()) == nzero and cr(name, zero.copy()) == zero)
        assert_true(cr("cos", zero.copy()) == one and cr("cos", nzero.copy()) == one)


def test_atan_of_infinity_is_half_pi() raises:
    var types = Types()
    for f in formats():
        var t = types.float_(f.id)
        var half_pi = run_typed("round", [run("mp.atan", [inf_of(f)])], t, types)
        assert_true(cr("atan", inf_of(f)) == half_pi)
        assert_true(cr("atan", inf_of(f, True)) == fl(f, half_pi.float_bits() | f.sign_mask()))


def test_subnormal_results() raises:
    var tiny = fl(F16, 1)
    assert_true(cr("sin", tiny.copy()) == tiny and cr("tan", tiny.copy()) == tiny and cr("atan", tiny.copy()) == tiny)
    var neg_tiny = fl(F16, 0x8001)
    assert_true(cr("sin", neg_tiny.copy()) == neg_tiny)
    # exp(-17) is just over half the smallest f16 subnormal; exp(-18) is under.
    assert_true(cr("exp", fl(F16, 0xCC40)) == fl(F16, 1))
    assert_true(cr("exp", fl(F16, 0xCC80)) == fl(F16, 0))
    # f32: the edge of the subnormal range.
    var big = fl(F32, 0x42B17218)
    assert_true(cr("exp", big.copy()) == inf_of(F32))
    var below = run("next_down", [big.copy()])
    var r = cr("exp", below)
    assert_true(run("is_finite", [r.copy()]).as_bool() and r.float_bits() > 0x7F000000)
    assert_true(cr("exp", fl(F32, 0xC2CFF0A4)) == fl(F32, 1))
    assert_true(cr("exp", fl(F32, 0xC2D00000)) == fl(F32, 0))
    var sub = cr("exp", fl(F32, 0xC2CE0000))
    assert_true(run("is_subnormal", [sub.copy()]).as_bool())


def test_errors() raises:
    assert_true(error_of("cr.cos", [Value.int(1)]).startswith("cr.cos: "))
    assert_true(error_of("cr.sqrt", [rat(1, 2)]).startswith("cr.sqrt: "))
    assert_true(error_of("cr.exp", []).startswith("cr.exp: "))
    assert_true(error_of("cr.exp", [fl(F16, 0), fl(F16, 0)]).startswith("cr.exp: "))


def mp_rounded(name: String, x: Value, f: FloatFormat) raises -> Optional[Value]:
    """round<f>(mp.name(real(x))), unless mp has no value there."""
    var types = Types()
    var t = types.float_(f.id)
    try:
        var r = run("mp." + name, [x.copy()])
        return run_typed("round", [r^], t, types)
    except:
        return None


def agrees_with_mp(name: String, f: FloatFormat, bits: UInt64) raises -> Bool:
    """cr.name is the nearest value to the exact one: mp at 256 bits, rounded once. Skips
    zero arguments (their signs are cr's own) and arguments mp can't take."""
    var x = fl(f, bits)
    if run("is_nan", [x.copy()]).as_bool() or run("is_inf", [x.copy()]).as_bool() or run("is_zero", [x.copy()]).as_bool():
        return True
    var want = mp_rounded(name, x, f)
    if not want:
        return True
    var got = cr(name, x)
    if got == want.value():
        return True
    # A zero from mp carries no sign; cr's may be negative.
    if run("is_zero", [got.copy()]).as_bool() and run("is_zero", [want.value().copy()]).as_bool():
        return True
    print(name, f, hex(bits), "got", got, "want", want.value())
    return False


def test_f16_matches_mp() raises:
    var step = samples(61, 1)
    for name in names():
        for bits in range(0, 1 << 16, step):
            assert_true(agrees_with_mp(name, F16, UInt64(bits)))


def test_bf16_matches_mp() raises:
    var step = samples(257, 5)
    for name in names():
        for bits in range(0, 1 << 16, step):
            assert_true(agrees_with_mp(name, BF16, UInt64(bits)))


def random_bits(mut rng: Lcg, f: FloatFormat) -> UInt64:
    """A pattern with a modest exponent, so the functions aren't all saturated."""
    var span = 40
    var e = f.bias() - span + rng.below(2 * span)
    var frac = rng.next() & f.fraction_mask()
    var sign = f.sign_mask() if rng.below(2) == 0 else UInt64(0)
    return sign | (UInt64(e) << UInt64(f.fraction_bits)) | frac


def test_f32_matches_mp() raises:
    var rng = Lcg(7)
    for name in names():
        for _ in range(samples(40, 2000)):
            assert_true(agrees_with_mp(name, F32, random_bits(rng, F32)))


def test_f64_matches_mp() raises:
    var rng = Lcg(11)
    for name in names():
        for _ in range(samples(40, 2000)):
            assert_true(agrees_with_mp(name, F64, random_bits(rng, F64)))


def within_steps(got: Value, want: Float64, steps: Int) raises -> Bool:
    var y = f64v(want)
    var q = run("qe", [got.copy(), y^])
    return q.item(1) == Value.int(0) and q.item(0).small_int().value() <= steps


def test_f64_is_within_one_step_of_the_math_library() raises:
    var rng = Lcg(3)
    for _ in range(samples(60, 3000)):
        var bits = random_bits(rng, F64)
        var x = bitcast_f64_back(bits)
        var v = fl(F64, bits)
        assert_true(within_steps(cr("sin", v.copy()), sin(x), 1))
        assert_true(within_steps(cr("cos", v.copy()), cos(x), 1))
        assert_true(within_steps(cr("tan", v.copy()), tan(x), 1))
        assert_true(within_steps(cr("atan", v.copy()), atan(x), 1))
        # Mojo's exp is several steps off in places, so exp is checked against mp and known values.
        var p = abs(x)
        var pv = f64v(p)
        assert_true(within_steps(cr("log", pv.copy()), log(p), 1))
        # sqrt is correctly rounded by IEEE, so it must match exactly.
        assert_true(cr("sqrt", pv) == f64v(sqrt(p)))


def bitcast_f64_back(bits: UInt64) -> Float64:
    from std.memory import bitcast

    return bitcast[DType.float64](bits)


def test_known_f64_values() raises:
    # cos(1e22) is a classic hard argument-reduction case.
    assert_true(cr("cos", f64v(1e22)) == f64v(0.523214785395139))
    assert_true(cr("sqrt", f64v(2.0)) == fl(F64, 0x3FF6A09E667F3BCD))
    assert_true(cr("exp", f64v(1.0)) == fl(F64, 0x4005BF0A8B145769))
    assert_true(cr("log", f64v(2.0)) == fl(F64, 0x3FE62E42FEFA39EF))
    assert_true(cr("atan", f64v(1.0)) == fl(F64, 0x3FE921FB54442D18))
    assert_true(cr("sin", f64v(1.0)) == fl(F64, 0x3FEAED548F090CEE))
    assert_true(cr("exp", f64v(709.782712893384)) == fl(F64, 0x7FEFFFFFFFFFFF2A))
    assert_true(cr("exp", f64v(709.79)) == inf_of(F64))
    assert_true(cr("exp", f64v(-745.2)) == fl(F64, 0))
    assert_true(cr("exp", f64v(-745.0)) == fl(F64, 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
