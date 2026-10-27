from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check.types import Types
from numeric.bigint import BigInt
from numeric.formats import F16, BF16, F32, F64
from prelude.testkit import Lcg, bi, error_of, fl, int_list, rat, run, run_typed, samples
from wire.value import Value


def b(v: Value) -> Bool:
    return v.as_bool()


def qe(x: Value, y: Value) raises -> Value:
    return run("qe", [x.copy(), y.copy()])


def parts(q: Value) raises -> Tuple[Value, Value]:
    return (run("steps", [q.copy()]), run("nans", [q.copy()]))


def test_qe_table() raises:
    var one = fl(F16, 0x3C00)
    var pz = fl(F16, 0)
    var nz = fl(F16, 0x8000)
    var nan = fl(F16, 0x7E00)
    assert_true(qe(one, one) == Value.qerr(BigInt(0), BigInt(0)))
    assert_true(qe(one, fl(F16, 0x3C01)) == Value.qerr(BigInt(1), BigInt(0)))
    assert_true(qe(fl(F16, 0x3C01), one) == Value.qerr(BigInt(1), BigInt(0)))
    assert_true(qe(pz, nz) == Value.qerr(BigInt(0), BigInt(0)))
    assert_true(qe(fl(F16, 1), fl(F16, 0x8001)) == Value.qerr(BigInt(2), BigInt(0)))
    assert_true(qe(nan, nan) == Value.qerr(BigInt(0), BigInt(0)))
    assert_true(qe(nan, one) == Value.qerr(BigInt(0), BigInt(1)))
    assert_true(qe(one, nan) == Value.qerr(BigInt(0), BigInt(1)))
    # The infinities are values: 0x7BFF to +inf is one step, -inf to +inf spans all.
    assert_true(qe(fl(F16, 0x7BFF), fl(F16, 0x7C00)) == Value.qerr(BigInt(1), BigInt(0)))
    assert_true(qe(fl(F16, 0xFC00), fl(F16, 0x7C00)) == Value.qerr(BigInt(0x7C00 * 2), BigInt(0)))
    # f64: the span can pass what an Int holds.
    assert_true(
        qe(fl(F64, 0xFFF0000000000000), fl(F64, 0x7FF0000000000000))
        == Value.qerr(BigInt.parse("18437736874454810624"), BigInt(0))
    )


def test_qe_errors() raises:
    assert_true(error_of("qe", [Value.int(1), Value.int(2)]).startswith("qe: "))
    assert_true(error_of("qe", [fl(F16, 0), fl(F32, 0)]).startswith("qe: "))
    assert_true(error_of("steps", [Value.int(1)]).startswith("steps: "))
    assert_true(error_of("nans", [Value.int(1)]).startswith("nans: "))


def test_steps_and_nans() raises:
    var q = Value.qerr(BigInt(7), BigInt(2))
    assert_true(run("steps", [q.copy()]) == Value.int(7))
    assert_true(run("nans", [q.copy()]) == Value.int(2))


def test_qe_with_a_type_argument() raises:
    var types = Types()
    var f32 = types.float_(3)
    var got = run_typed("qe", [Value.int(1), fl(F32, 0x3F800001)], f32, types)
    assert_true(got == Value.qerr(BigInt(1), BigInt(0)))
    got = run_typed("qe", [rat(1, 2), rat(1, 2)], f32, types)
    assert_true(got == Value.qerr(BigInt(0), BigInt(0)))
    # 1/3 isn't exactly an f32.
    assert_true(error_of_typed(rat(1, 3), fl(F32, 0), f32, types).startswith("qe<f32>: "))
    # A value of another format is refused.
    assert_true(error_of_typed(fl(F16, 0), fl(F32, 0), f32, types).startswith("qe<f32>: "))


def error_of_typed(x: Value, y: Value, t: Int, types: Types) -> String:
    try:
        _ = run_typed("qe", [x.copy(), y.copy()], t, types)
    except e:
        return String(e)
    return String()


def test_qe_next_up_is_one_and_adds_f16() raises:
    var rng = Lcg()
    for bits in range(0, 1 << 16, 5):
        var x = fl(F16, UInt64(bits))
        if bits & 0x7C00 == 0x7C00 and (bits & 0x3FF != 0 or bits == 0x7C00 or bits == 0xFC00):
            continue
        var up = run("next_up", [x.copy()])
        assert_true(qe(x, up) == Value.qerr(BigInt(1), BigInt(0)))
    # Along the line, steps add: qe(x, z) == qe(x, y) + qe(y, z) for x <= y <= z.
    for _ in range(samples(500, 20000)):
        var xs = List[Int]()
        for _k in range(3):
            xs.append(rng.below(0x7C00))
        # Sort the three non-negative patterns, which order like their values.
        if xs[0] > xs[1]:
            xs[0], xs[1] = xs[1], xs[0]
        if xs[1] > xs[2]:
            xs[1], xs[2] = xs[2], xs[1]
        if xs[0] > xs[1]:
            xs[0], xs[1] = xs[1], xs[0]
        var xz = parts(qe(fl(F16, UInt64(xs[0])), fl(F16, UInt64(xs[2]))))[0].as_bigint()
        var xy = parts(qe(fl(F16, UInt64(xs[0])), fl(F16, UInt64(xs[1]))))[0].as_bigint()
        var yz = parts(qe(fl(F16, UInt64(xs[1])), fl(F16, UInt64(xs[2]))))[0].as_bigint()
        assert_true(xz == xy + yz)
        assert_true(xz == BigInt(xs[2] - xs[0]))


def test_f16_has_63489_distinct_values() raises:
    # -inf to +inf spans every value but one: signed zeros count once, NaNs not at all.
    var span = parts(qe(fl(F16, 0xFC00), fl(F16, 0x7C00)))
    assert_true(span[0] == Value.int(63488))


# Fixed-width integers


def wrap(bits: Int, signed: Bool, n: Value) raises -> Value:
    var types = Types()
    return run_typed("wrap", [n.copy()], types.fixed(bits, signed), types)


def fits(bits: Int, signed: Bool, x: Value) raises -> Bool:
    var types = Types()
    return run_typed("fits", [x.copy()], types.fixed(bits, signed), types).as_bool()


def test_wrap_known() raises:
    assert_true(wrap(8, True, Value.int(127)) == Value.int(127))
    assert_true(wrap(8, True, Value.int(128)) == Value.int(-128))
    assert_true(wrap(8, True, Value.int(-129)) == Value.int(127))
    assert_true(wrap(8, False, Value.int(256)) == Value.int(0))
    assert_true(wrap(8, False, Value.int(-1)) == Value.int(255))
    assert_true(wrap(32, True, Value.int(0x80000000)) == Value.int(-0x80000000))
    assert_true(wrap(64, False, Value.int(-1)) == bi("18446744073709551615"))
    assert_true(wrap(64, True, bi("9223372036854775808")) == bi("-9223372036854775808"))
    assert_true(wrap(64, True, bi("-9223372036854775809")) == bi("9223372036854775807"))
    assert_true(wrap(16, False, bi("123456789012345678901234567890")) == Value.int(2770))


def test_wrap_properties() raises:
    var rng = Lcg()
    for _ in range(samples(300, 20000)):
        var n = Int(rng.next() >> 1) - Int(rng.next() >> 2)
        for bits in [8, 16, 32, 64]:
            var u = wrap(bits, False, Value.int(n))
            var s = wrap(bits, True, Value.int(n))
            assert_true(fits(bits, False, u))
            assert_true(fits(bits, True, s))
            # Idempotent, and the two views differ by a multiple of 2**bits.
            assert_true(wrap(bits, False, u.copy()) == u)
            assert_true(wrap(bits, True, s.copy()) == s)
            var d = u.as_bigint() - s.as_bigint()
            assert_true(d == BigInt(0) or d == BigInt(1) << bits)


def test_wrap_errors() raises:
    var types = Types()
    try:
        _ = run_typed("wrap", [Value.int(1)], types.float_(3), types)
        assert_true(False)
    except e:
        assert_true(String(e).startswith("wrap<f32>: "))
    try:
        _ = run_typed("wrap", [rat(1, 2)], types.fixed(8, True), types)
        assert_true(False)
    except e:
        assert_true(String(e).startswith("wrap: "))
    assert_true(error_of("wrap", [Value.int(1)]).startswith("wrap: "))


def test_fits_integers() raises:
    assert_true(fits(8, True, Value.int(127)))
    assert_false(fits(8, True, Value.int(128)))
    assert_true(fits(8, True, Value.int(-128)))
    assert_false(fits(8, True, Value.int(-129)))
    assert_true(fits(8, False, Value.int(255)))
    assert_false(fits(8, False, Value.int(-1)))
    assert_true(fits(64, False, bi("18446744073709551615")))
    assert_false(fits(64, False, bi("18446744073709551616")))
    assert_true(fits(64, True, bi("-9223372036854775808")))
    # A real fits only when it is a whole number in range.
    assert_true(fits(8, True, Value.real(BigInt(100), BigInt(1))))
    assert_false(fits(8, True, rat(1, 2)))
    assert_false(fits(8, True, Value.real(BigInt(1), BigInt(0))))
    assert_true(fits(16, True, fl(F32, 0x42C80000)))
    assert_false(fits(16, True, fl(F32, 0x3F000000)))


def fits_float(format_id: Int, x: Value) raises -> Bool:
    var types = Types()
    return run_typed("fits", [x.copy()], types.float_(UInt8(format_id)), types).as_bool()


def test_fits_floats() raises:
    assert_true(fits_float(1, Value.int(65504)))
    assert_false(fits_float(1, Value.int(65505)))
    assert_false(fits_float(1, rat(1, 10)))
    assert_true(fits_float(1, rat(1, 1 << 24)))
    assert_false(fits_float(1, rat(1, 1 << 25)))
    assert_true(fits_float(1, Value.real(BigInt(1), BigInt(0))))
    assert_true(fits_float(3, rat(13421773, 1 << 27)))
    assert_true(fits_float(4, Value.real(BigInt(1), BigInt(1) << 1074)))
    assert_true(fits_float(1, Value.int(0)))
    assert_true(fits_float(4, fl(F32, 0x3DCCCCCD)))
    assert_true(error_of_fits(fl(F32, 0x7FC00000)).startswith("fits<f16>: "))


def error_of_fits(x: Value) -> String:
    try:
        _ = fits_float(1, x)
    except e:
        return String(e)
    return String()


def test_le_uint() raises:
    assert_true(run("le_uint", [Value.bytes([])]) == Value.int(0))
    assert_true(run("le_uint", [Value.bytes([1])]) == Value.int(1))
    assert_true(run("le_uint", [Value.bytes([1, 2])]) == Value.int(0x0201))
    assert_true(run("le_uint", [Value.bytes([0, 0, 1])]) == Value.int(65536))
    assert_true(run("le_uint", [Value.bytes([255, 255, 255, 255, 255, 255, 255, 255])]) == bi("18446744073709551615"))
    assert_true(run("le_uint", [Value.bytes([0, 0, 0, 0, 0, 0, 0, 0, 1])]) == bi("18446744073709551616"))
    assert_true(
        run("le_uint", [Value.bytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])])
        == bi("21345817372864405881847059188222722561")
    )
    assert_true(error_of("le_uint", [Value.string("a")]).startswith("le_uint: "))


def test_bit_length() raises:
    assert_true(run("bit_length", [Value.int(0)]) == Value.int(0))
    assert_true(run("bit_length", [Value.int(1)]) == Value.int(1))
    assert_true(run("bit_length", [Value.int(255)]) == Value.int(8))
    assert_true(run("bit_length", [Value.int(256)]) == Value.int(9))
    assert_true(run("bit_length", [Value.int(-256)]) == Value.int(9))
    assert_true(run("bit_length", [Value.int(-1)]) == Value.int(1))
    assert_true(run("bit_length", [bi("18446744073709551616")]) == Value.int(65))
    assert_true(run("bit_length", [bi("-18446744073709551615")]) == Value.int(64))
    assert_true(error_of("bit_length", [rat(1, 2)]).startswith("bit_length: "))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
