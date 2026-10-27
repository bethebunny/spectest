from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check.types import Types
from numeric.bigint import BigInt
from numeric.formats import FloatFormat, F16, BF16, F32, F64
from numeric.real import Real
from prelude_testkit import Lcg, bi, error_of, fl, formats, rat, run, run_typed, samples
from prelude.util import real_of, real_value
from wire.order import compare
from wire.value import Value


def b(v: Value) -> Bool:
    return v.as_bool()


def classes(f: FloatFormat, bits: UInt64) raises -> String:
    var out = String()
    var x = fl(f, bits)
    if b(run("is_nan", [x.copy()])):
        out += "n"
    if b(run("is_inf", [x.copy()])):
        out += "i"
    if b(run("is_zero", [x.copy()])):
        out += "z"
    if b(run("is_subnormal", [x.copy()])):
        out += "s"
    if b(run("is_finite", [x.copy()])):
        out += "f"
    if b(run("signbit", [x.copy()])):
        out += "-"
    return out


def test_classification_table() raises:
    for f in formats():
        var sign = f.sign_mask()
        var q = UInt64(1) << UInt64(f.fraction_bits - 1)
        var inf = f.exponent_mask()
        assert_equal(classes(f, 0), "zf")
        assert_equal(classes(f, sign), "zf-")
        assert_equal(classes(f, 1), "sf")
        assert_equal(classes(f, f.fraction_mask()), "sf")
        assert_equal(classes(f, sign | 1), "sf-")
        assert_equal(classes(f, UInt64(1) << UInt64(f.fraction_bits)), "f")
        assert_equal(classes(f, inf - 1), "f")
        assert_equal(classes(f, inf), "i")
        assert_equal(classes(f, inf | sign), "i-")
        assert_equal(classes(f, inf | q), "n")
        assert_equal(classes(f, inf | 1), "n")
        assert_equal(classes(f, inf | q | sign), "n-")


def test_bits() raises:
    assert_true(run("bits", [fl(F32, 0x3F800000)]) == Value.int(0x3F800000))
    assert_true(run("bits", [fl(F64, 0xFFF8000000000001)]) == bi("18444492273895866369"))
    assert_true(run("bits", [fl(F16, 0x8000)]) == Value.int(0x8000))


def test_real_known() raises:
    assert_true(run("real", [fl(F16, 0x3C00)]) == Value.real(BigInt(1), BigInt(1)))
    assert_true(run("real", [fl(F16, 0x0001)]) == Value.real(BigInt(1), BigInt(1) << 24))
    assert_true(run("real", [fl(F16, 0x7BFF)]) == Value.real(BigInt(65504), BigInt(1)))
    assert_true(run("real", [fl(F16, 0x3555)]) == Value.real(BigInt(1365), BigInt(4096)))
    assert_true(run("real", [fl(F32, 0x3DCCCCCD)]) == Value.real(BigInt(13421773), BigInt(1) << 27))
    assert_true(run("real", [fl(F64, 0xBFF8000000000000)]) == Value.real(BigInt(-3), BigInt(2)))
    assert_true(run("real", [fl(F16, 0x8000)]) == Value.real(BigInt(0), BigInt(1)))
    assert_true(run("real", [fl(BF16, 0x3F80)]) == Value.real(BigInt(1), BigInt(1)))
    assert_true(run("real", [fl(F64, 1)]) == Value.real(BigInt(1), BigInt(1) << 1074))
    assert_true(run("real", [fl(F16, 0x7C00)]) == Value.real(BigInt(1), BigInt(0)))
    assert_true(run("real", [fl(F16, 0xFC00)]) == Value.real(BigInt(-1), BigInt(0)))
    assert_true(run("real", [Value.int(5)]) == Value.real(BigInt(5), BigInt(1)))
    assert_true(run("real", [rat(1, 3)]) == rat(1, 3))


def test_errors_name_the_function() raises:
    assert_true("NaN" in error_of("real", [fl(F32, 0x7FC00000)]))
    assert_true(error_of("real", [fl(F32, 0x7FC00000)]).startswith("real: "))
    assert_true(error_of("real", [Value.string("x")]).startswith("real: "))
    assert_true(error_of("is_nan", [Value.int(1)]).startswith("is_nan: "))
    assert_true(error_of("is_nan", []).startswith("is_nan: "))
    assert_true(error_of("bits", [Value.bool(True)]).startswith("bits: "))
    assert_true(error_of("next_up", [Value.int(1)]).startswith("next_up: "))
    assert_true(error_of("ieee_eq", [fl(F16, 0), Value.int(1)]).startswith("ieee_eq: "))
    assert_equal(error_of("is_nan", [fl(F16, 0)]), "")


def test_next_up_known() raises:
    assert_true(run("next_up", [fl(F16, 0x0000)]) == fl(F16, 1))
    assert_true(run("next_up", [fl(F16, 0x8000)]) == fl(F16, 1))
    assert_true(run("next_up", [fl(F16, 0x8001)]) == fl(F16, 0x8000))
    assert_true(run("next_up", [fl(F16, 0x7BFF)]) == fl(F16, 0x7C00))
    assert_true(run("next_up", [fl(F16, 0x7C00)]) == fl(F16, 0x7C00))
    assert_true(run("next_up", [fl(F16, 0xFC00)]) == fl(F16, 0xFBFF))
    assert_true(run("next_up", [fl(F16, 0x7E01)]) == fl(F16, 0x7E01))
    assert_true(run("next_down", [fl(F16, 0x0000)]) == fl(F16, 0x8001))
    assert_true(run("next_down", [fl(F16, 0xFC00)]) == fl(F16, 0xFC00))
    assert_true(run("next_down", [fl(F16, 0x3C00)]) == fl(F16, 0x3BFF))
    assert_true(run("next_up", [fl(F64, 0x3FF0000000000000)]) == fl(F64, 0x3FF0000000000001))


def test_next_up_exhaustive_f16() raises:
    for bits in range(0, 1 << 16):
        var x = fl(F16, UInt64(bits))
        if b(run("is_nan", [x.copy()])):
            assert_true(run("next_up", [x.copy()]) == x)
            assert_true(run("next_down", [x.copy()]) == x)
            continue
        var up = run("next_up", [x.copy()])
        var down = run("next_down", [x.copy()])
        if bits != 0x7C00:
            assert_true(compare(run("real", [up.copy()]), run("real", [x.copy()])) > 0)
        if bits != 0xFC00:
            assert_true(compare(run("real", [down.copy()]), run("real", [x.copy()])) < 0)
        # Away from the ends and the zeros, up and down undo each other.
        if bits != 0x7C00 and bits != 0xFC00 and bits != 0 and bits != 0x8000:
            assert_true(run("next_down", [up.copy()]) == x)
            assert_true(run("next_up", [down.copy()]) == x)


def test_same_and_ieee_eq() raises:
    var pz = fl(F32, 0)
    var nz = fl(F32, 0x80000000)
    var nan1 = fl(F32, 0x7FC00000)
    var nan2 = fl(F32, 0x7FC00001)
    assert_true(b(run("ieee_eq", [pz.copy(), nz.copy()])))
    assert_false(b(run("same", [pz.copy(), nz.copy()])))
    assert_false(b(run("ieee_eq", [nan1.copy(), nan1.copy()])))
    assert_true(b(run("same", [nan1.copy(), nan1.copy()])))
    assert_false(b(run("same", [nan1.copy(), nan2.copy()])))
    assert_true(b(run("ieee_eq", [fl(F32, 0x7F800000), fl(F32, 0x7F800000)])))
    assert_false(b(run("ieee_eq", [fl(F32, 0x7F800000), fl(F32, 0xFF800000)])))
    assert_true(b(run("ieee_eq", [fl(F32, 0x3F800000), fl(F32, 0x3F800000)])))
    assert_false(b(run("same", [fl(F32, 0x3F800000), fl(F64, 0x3F800000)])))
    assert_false(b(run("same", [Value.int(1), rat(1, 1)])))
    assert_true(b(run("same", [Value.list([pz.copy()]), Value.list([pz.copy()])])))
    assert_false(b(run("same", [Value.list([pz.copy()]), Value.list([nz.copy()])])))


def round_to(name: String, v: Value, format_id: Int) raises -> Value:
    var types = Types()
    return run_typed(name, [v.copy()], types.float_(UInt8(format_id)), types)


def test_round_known() raises:
    # f16 spacing is 2 on [2048, 4096): ties go to the even significand.
    assert_true(round_to("round", Value.int(2049), 1) == fl(F16, 0x6800))
    assert_true(round_to("round", Value.int(2051), 1) == fl(F16, 0x6802))
    assert_true(round_to("round", Value.int(65519), 1) == fl(F16, 0x7BFF))
    assert_true(round_to("round", Value.int(65520), 1) == fl(F16, 0x7C00))
    assert_true(round_to("round", Value.int(-65520), 1) == fl(F16, 0xFC00))
    # Underflow: half the smallest subnormal ties to zero, keeping the sign.
    var tiny = Value.real(BigInt(1), BigInt(1) << 25)
    assert_true(round_to("round", tiny, 1) == fl(F16, 0))
    assert_true(round_to("round", run("real", [Value.int(0)]), 1) == fl(F16, 0))
    assert_true(round_to("round", rat(-1, 1 << 25), 1) == fl(F16, 0x8000))
    assert_true(round_to("round", rat(3, 1 << 26), 1) == fl(F16, 1))
    assert_true(round_to("round", rat(1, 3), 3) == fl(F32, 0x3EAAAAAB))
    assert_true(round_to("round", rat(1, 10), 4) == fl(F64, 0x3FB999999999999A))
    assert_true(round_to("round", rat(1, 10), 2) == fl(BF16, 0x3DCD))
    assert_true(round_to("round", fl(F64, 0x7FF0000000000000), 3) == fl(F32, 0x7F800000))
    assert_true(round_to("round", fl(F64, 0x3FF8000000000000), 1) == fl(F16, 0x3E00))


def test_round_errors() raises:
    var types = Types()
    var nan = fl(F16, 0x7E00)
    try:
        _ = run_typed("round", [nan.copy()], types.float_(3), types)
        assert_true(False)
    except e:
        assert_true(String(e).startswith("round<f32>: "))
    try:
        _ = run_typed("round", [nan.copy()], types.fixed(32, True), types)
        assert_true(False)
    except e:
        assert_true(String(e).startswith("round<i32>: "))
    try:
        _ = run("round", [Value.int(1)])
        assert_true(False)
    except e:
        assert_true(String(e).startswith("round: "))


def test_round_of_real_is_identity_f16() raises:
    var types = Types()
    var t = types.float_(1)
    for bits in range(0, 1 << 16):
        var x = fl(F16, UInt64(bits))
        if b(run("is_nan", [x.copy()])):
            continue
        var back = run_typed("round", [run("real", [x.copy()])], t, types)
        if b(run("is_zero", [x.copy()])):
            assert_true(back == fl(F16, 0))
        else:
            assert_true(back == x)


def test_round_midpoints_go_to_even_f16() raises:
    var types = Types()
    var t = types.float_(1)
    var step = 13 if not samples(0, 1) else 1
    for bits in range(0, 0x7BFF, step):
        var x = fl(F16, UInt64(bits))
        var up = run("next_up", [x.copy()])
        var mid = (real_of(x, "t") + real_of(up, "t")) / Real(2)
        var got = run_typed("round", [real_value(mid^)], t, types)
        assert_true(got == (x if bits % 2 == 0 else up))


def test_ulp_known() raises:
    var types = Types()
    var f16 = types.float_(1)
    var f64 = types.float_(4)
    assert_true(run_typed("ulp", [Value.int(1)], f16, types) == rat(1, 1 << 10))
    assert_true(run_typed("ulp", [Value.int(0)], f16, types) == rat(1, 1 << 24))
    assert_true(run_typed("ulp", [Value.int(65504)], f16, types) == rat(32, 1))
    assert_true(run_typed("ulp", [fl(F16, 0x7C00)], f16, types) == rat(32, 1))
    assert_true(run_typed("ulp", [rat(1, 3)], f16, types) == rat(1, 1 << 12))
    assert_true(run_typed("ulp", [rat(1, 1 << 15)], f16, types) == rat(1, 1 << 24))
    assert_true(run_typed("ulp", [rat(-3, 1)], f16, types) == rat(1, 1 << 9))
    assert_true(run_typed("ulp", [Value.int(1)], f64, types) == Value.real(BigInt(1), BigInt(1) << 52))
    assert_true(run_typed("ulp", [Value.int(1 << 60)], f64, types) == Value.real(BigInt(1) << 8, BigInt(1)))


def test_ulp_is_the_gap_to_next_up_f16() raises:
    var types = Types()
    var t = types.float_(1)
    for bits in range(0, 0x7BFF, 3):
        var x = fl(F16, UInt64(bits))
        var up = run("next_up", [x.copy()])
        var gap = real_of(up, "t") - real_of(x, "t")
        assert_true(run_typed("ulp", [x.copy()], t, types) == real_value(gap^))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
