from std.memory import bitcast
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from spec.types import Types
from value.float_formats import BF16, F16, F32, F64, FloatFormat
from partitions.compile import compile_set_aliased
from partitions_testing import compile_set, parse_set_expr, set_expr_node
from sets import BitSet, SetContext

comptime NEG_ZERO = UInt64(1) << 63


def _classes() -> Dict[String, BitSet]:
    return Dict[String, BitSet]()


def comp(
    mut c: SetContext,
    text: String,
    elem: String,
    classes: Dict[String, BitSet] = Dict[String, BitSet](),
) raises -> BitSet:
    var ast = parse_set_expr(text)
    var types = Types()
    var t = types.scalar(elem).value()
    return compile_set(c, ast, types, t, set_expr_node(ast), classes)


def error_of(
    mut c: SetContext,
    text: String,
    elem: String,
    classes: Dict[String, BitSet] = Dict[String, BitSet](),
) -> String:
    try:
        _ = comp(c, text, elem, classes)
    except e:
        return String(e)
    return String()


def f64_bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def p2(k: Int) -> UInt64:
    """The f64 pattern of 2**k."""
    return UInt64(1023 + k) << 52


def f32_bits(x: Float32) -> UInt64:
    return UInt64(bitcast[DType.uint32](x))


def assert_error(mut c: SetContext, text: String, elem: String, part: String) raises:
    var message = error_of(c, text, elem)
    assert_true(message.byte_length() > 0, "no error for " + text)
    assert_true(part in message, "expected '" + part + "' in: " + message)


# Named sets


def _named_sizes(name: String, fmt: FloatFormat) raises:
    var c = SetContext()
    var exp = fmt.exponent_bits
    var man = fmt.fraction_bits
    var payloads = (UInt128(1) << UInt128(man)) - 1
    var nan = c.count(comp(c, name + ".nan", name))
    var inf = c.count(comp(c, name + ".inf", name))
    var zero = c.count(comp(c, name + ".zero", name))
    var sub = c.count(comp(c, name + ".subnormal", name))
    var normal = c.count(comp(c, name + ".normal", name))
    assert_equal(nan, 2 * payloads)
    assert_equal(inf, UInt128(2))
    assert_equal(zero, UInt128(2))
    assert_equal(sub, 2 * payloads)
    assert_equal(normal, (2 * ((UInt128(1) << UInt128(exp)) - 2)) << UInt128(man))
    var total = UInt128(1) << UInt128(1 + exp + man)
    assert_equal(nan + inf + zero + sub + normal, total)
    assert_true(
        c.equal(
            comp(c, name + ".finite", name),
            comp(c, name + ".zero | " + name + ".subnormal | " + name + ".normal", name),
        )
    )
    assert_equal(c.count(comp(c, name + ".all", name)), total)


def test_float_named_set_sizes() raises:
    _named_sizes("f16", F16)
    _named_sizes("bf16", BF16)
    _named_sizes("f32", F32)
    _named_sizes("f64", F64)


def test_positive_and_negative_are_by_sign_bit() raises:
    var c = SetContext()
    var pos = comp(c, "f64.positive", "f64")
    var neg = comp(c, "f64.negative", "f64")
    assert_equal(c.count(pos), UInt128(1) << 63)
    assert_equal(c.count(neg), UInt128(1) << 63)
    assert_true(c.contains(pos, 0) and c.contains(neg, NEG_ZERO))
    assert_true(c.contains(pos, f64_bits(Float64.MAX_FINITE)))
    assert_true(c.contains(pos, 0x7FF8000000000000))
    assert_true(c.contains(neg, 0xFFF8000000000000))
    assert_true(c.disjoint(pos, neg))
    assert_true(c.equal(c.union(pos, neg), c.full(64)))


def test_named_sets_hold_the_right_values() raises:
    var c = SetContext()
    var zero = comp(c, "f64.zero", "f64")
    assert_true(c.contains(zero, 0) and c.contains(zero, NEG_ZERO))
    assert_true(c.contains(comp(c, "f64.subnormal", "f64"), 1))
    assert_true(c.contains(comp(c, "f64.normal", "f64"), 0x0010000000000000))
    assert_false(c.contains(comp(c, "f64.subnormal", "f64"), 0x0010000000000000))
    var nan = comp(c, "f64.nan", "f64")
    assert_true(c.contains(nan, 0x7FF0000000000001))
    assert_false(c.contains(nan, 0x7FF0000000000000))
    assert_false(c.contains(nan, f64_bits(1.0)))


def test_int_named_sets() raises:
    var c = SetContext()
    assert_equal(c.count(comp(c, "i32.negative", "i32")), UInt128(1) << 31)
    assert_equal(c.count(comp(c, "i32.positive", "i32")), UInt128(1) << 31)
    assert_true(c.contains(comp(c, "i32.positive", "i32"), 0))
    assert_true(c.contains(comp(c, "i32.negative", "i32"), 0xFFFFFFFF))
    assert_true(c.equal(comp(c, "i8.zero", "i8"), comp(c, "{0}", "i8")))
    assert_equal(c.count(comp(c, "u32.negative", "u32")), UInt128(0))
    assert_true(c.equal(comp(c, "u32.positive", "u32"), c.full(32)))
    assert_equal(c.count(comp(c, "i64.all", "i64")), UInt128(1) << 64)


def test_bool_sets() raises:
    var c = SetContext()
    var t = comp(c, "{true}", "bool")
    assert_equal(c.count(t), UInt128(1))
    assert_true(c.contains(t, 1) and not c.contains(t, 0))
    assert_equal(c.count(comp(c, "bool.all", "bool")), UInt128(2))
    assert_true(c.equal(comp(c, "bool.all - {false}", "bool"), t))


# Ranges


def test_range_around_zero_holds_both_zeros() raises:
    var c = SetContext()
    var s = comp(c, "f64.range(-1, 1)", "f64")
    assert_true(c.contains(s, 0) and c.contains(s, NEG_ZERO))
    assert_true(c.contains(s, f64_bits(-1.0)))
    assert_false(c.contains(s, f64_bits(1.0)))
    assert_false(c.contains(s, 0x7FF8000000000000))


def test_range_from_zero_holds_both_zeros() raises:
    var c = SetContext()
    var s = comp(c, "f64.range(0, 1)", "f64")
    assert_true(c.contains(s, 0) and c.contains(s, NEG_ZERO))
    assert_equal(c.count(s), UInt128(f64_bits(1.0)) + 1)
    assert_false(c.contains(s, NEG_ZERO | 1))


def test_range_to_zero_holds_no_zero() raises:
    var c = SetContext()
    var s = comp(c, "f64.range(-1, 0)", "f64")
    assert_false(c.contains(s, 0) or c.contains(s, NEG_ZERO))
    assert_true(c.contains(s, f64_bits(-1.0)) and c.contains(s, NEG_ZERO | 1))
    assert_equal(c.count(s), UInt128(f64_bits(1.0)))


def test_ranges_never_hold_nan() raises:
    var c = SetContext()
    var nan = comp(c, "f64.nan", "f64")
    for text in ["f64.range(none, none)", "f64.range(0, none)", "f64.range(none, 0)"]:
        assert_true(c.is_empty(c.intersection(comp(c, text, "f64"), nan)))
    assert_true(
        c.equal(
            comp(c, "f64.range(none, none)", "f64"), c.difference(c.full(64), nan)
        )
    )


def test_open_ends_include_their_infinity() raises:
    var c = SetContext()
    var up = comp(c, "f64.range(0, none)", "f64")
    var down = comp(c, "f64.range(none, 0)", "f64")
    assert_true(c.contains(up, f64_bits(Float64.MAX)))
    assert_false(c.contains(up, NEG_ZERO | 0x7FF0000000000000))
    assert_true(c.contains(down, NEG_ZERO | 0x7FF0000000000000))
    assert_false(c.contains(down, 0x7FF0000000000000))
    assert_false(
        c.contains(comp(c, "f64.range(0, f64.max)", "f64"), 0x7FF0000000000000)
    )


def test_empty_and_inverted_ranges() raises:
    var c = SetContext()
    assert_true(c.is_empty(comp(c, "f64.range(1, 1)", "f64")))
    assert_true(c.is_empty(comp(c, "f64.range(2, 1)", "f64")))
    assert_true(c.is_empty(comp(c, "i32.range(5, 5)", "i32")))
    assert_true(c.is_empty(comp(c, "i32.range(5, -5)", "i32")))


def test_range_with_type_bounds() raises:
    var c = SetContext()
    var s = comp(c, "f16.range(f16.min, f16.max)", "f16")
    assert_equal(c.count(s), c.count(comp(c, "f16.finite", "f16")) - 1)
    assert_true(c.contains(s, 0xFBFF))
    assert_false(c.contains(s, 0x7BFF))


def test_range_of_subnormal_width() raises:
    var c = SetContext()
    assert_true(
        c.equal(comp(c, "f64.range(0, 0x1p-1074)", "f64"), comp(c, "f64.zero", "f64"))
    )
    assert_equal(c.count(comp(c, "f64.range(-0x1p-1074, 0x1p-1074)", "f64")), UInt128(3))


def test_libm_small_range() raises:
    var c = SetContext()
    var small = comp(c, "f64.range(-0x1p-26, 0x1p-26) & f64.normal", "f64")
    assert_false(c.contains(small, p2(-26)))
    assert_true(c.contains(small, (p2(-26) | NEG_ZERO)))
    assert_true(c.contains(small, p2(-27)))
    assert_true(c.contains(small, 0x0010000000000000))
    assert_false(c.contains(small, 0))
    assert_false(c.contains(small, 1))


def test_range_bounds_must_be_exact() raises:
    var c = SetContext()
    assert_error(c, "f64.range(0.1, 1)", "f64", "not exactly representable")
    assert_error(c, "f16.range(0, 0x1p20)", "f16", "not exactly representable")
    assert_error(c, "f32.range(0, 0x1p-150)", "f32", "not exactly representable")
    assert_error(c, "f32.range(1/3, 1)", "f32", "not exactly representable")
    assert_equal(
        error_of(c, "f32.range(none, 0.1)", "f32"),
        "t.spec:3:27: f32.range bound 0.1 is not exactly representable in f32",
    )


def test_int_ranges() raises:
    var c = SetContext()
    assert_true(c.equal(comp(c, "i8.range(-128, 128)", "i8"), c.full(8)))
    assert_true(c.equal(comp(c, "i8.range(none, 0)", "i8"), comp(c, "i8.negative", "i8")))
    assert_true(c.equal(comp(c, "u8.range(0, 256)", "u8"), c.full(8)))
    assert_equal(c.count(comp(c, "i64.range(i32.min, i32.max + 1)", "i64")), UInt128(1) << 32)
    assert_equal(
        c.count(comp(c, "i64.range(i32.max + 1, none)", "i64")),
        (UInt128(1) << 63) - (UInt128(1) << 31),
    )
    assert_error(c, "i8.range(-129, 0)", "i8", "outside i8")
    assert_error(c, "i8.range(0, 129)", "i8", "outside i8")
    assert_error(c, "i32.range(0, 1.5)", "i32", "not an integer")


def test_i8_range_matches_brute_force() raises:
    var c = SetContext()
    var bounds: List[Optional[Int]] = [None, -128, -127, -1, 0, 1, 127, 128]
    var highs: List[Optional[Int]] = [None, -128, -1, 0, 1, 100, 128]
    for lo in bounds:
        for hi in highs:
            var text = String("i8.range(")
            text += "none" if not lo else String(lo.value())
            text += ", "
            text += "none" if not hi else String(hi.value())
            text += ")"
            var s = comp(c, text, "i8")
            for v in range(-128, 128):
                var want = (not lo or lo.value() <= v) and (not hi or v < hi.value())
                assert_equal(c.contains(s, UInt64(v & 255)), want, text + " at " + String(v))


# Patterns, literals, constants


def test_patterns() raises:
    var c = SetContext()
    assert_true(
        c.equal(
            comp(c, 'f16.pattern("?111.11??.*.*")', "f16"),
            comp(c, "f16.nan | f16.inf", "f16"),
        )
    )
    var quiet = comp(c, 'f64.pattern("?111.1111.1111.1*.*.*.*.*.*.*.*.*.*.*.*.*")', "f64")
    assert_true(c.subset(quiet, comp(c, "f64.nan", "f64")))
    assert_equal(c.count(quiet), UInt128(1) << 52)
    assert_equal(c.count(comp(c, 'u8.pattern("1???.????")', "u8")), UInt128(128))
    assert_true(
        c.equal(comp(c, 'i8.pattern("1???.????")', "i8"), comp(c, "i8.negative", "i8"))
    )
    assert_error(c, 'f64.pattern("0000.0000")', "f64", "8 bits, not 64")
    assert_error(c, 'f64.pattern("xyz")', "f64", "pattern")


def test_set_literals() raises:
    var c = SetContext()
    var ints = c.members(comp(c, "{1, 2, 3}", "i32"), 10)
    assert_equal(len(ints), 3)
    var edge = comp(c, "{i32.min, i32.max, -1}", "i32")
    assert_true(c.contains(edge, 0x80000000) and c.contains(edge, 0x7FFFFFFF))
    assert_true(c.contains(edge, 0xFFFFFFFF))
    assert_equal(c.count(edge), UInt128(3))
    var fl = comp(c, "{0.5, 1, -2, 0x1p-149}", "f32")
    assert_equal(c.count(fl), UInt128(4))
    assert_true(c.contains(fl, f32_bits(0.5)) and c.contains(fl, f32_bits(1.0)))
    assert_true(c.contains(fl, f32_bits(-2.0)) and c.contains(fl, 1))
    assert_true(c.equal(comp(c, "{0}", "f64"), c.exactly([UInt64(0)], 64)))
    assert_true(c.equal(comp(c, "{f64.max}", "f64"), c.exactly([UInt64(0x7FEFFFFFFFFFFFFF)], 64)))
    assert_true(c.equal(comp(c, "{f64.min}", "f64"), c.exactly([UInt64(0xFFEFFFFFFFFFFFFF)], 64)))
    assert_true(c.is_empty(comp(c, "{}", "i32")))


def test_set_literal_errors() raises:
    var c = SetContext()
    assert_error(c, "{0.1}", "f32", "not exactly representable in f32")
    assert_error(c, "{300}", "u8", "not a u8 value")
    assert_error(c, "{1.5}", "i32", "not a i32 value")
    assert_error(c, "{1}", "bool", "true and false")


def test_negative_zero_literal_is_rejected_with_a_hint() raises:
    var c = SetContext()
    assert_error(c, "{-0}", "f64", "f64.zero & f64.negative")
    assert_error(c, "{-0.0}", "f64", "-0")


def test_constant_arithmetic() raises:
    var c = SetContext()
    assert_true(
        c.equal(
            comp(c, "f64.range(-1/2, 2 * 0.25 + 0.5)", "f64"),
            comp(c, "f64.range(-0.5, 1)", "f64"),
        )
    )
    assert_true(
        c.equal(
            comp(c, "i32.range(-(3 - 1), 2 * 3)", "i32"), comp(c, "i32.range(-2, 6)", "i32")
        )
    )
    assert_equal(c.count(comp(c, "i64.range(i32.min - 1, i32.min)", "i64")), UInt128(1))
    assert_error(c, "f64.range(1/0, 2)", "f64", "division by zero")


def test_set_algebra() raises:
    var c = SetContext()
    var a = comp(c, "f64.normal & f64.negative", "f64")
    assert_equal(c.count(a), c.count(comp(c, "f64.normal", "f64")) // 2)
    var b = comp(c, "f64.finite - f64.zero - f64.subnormal", "f64")
    assert_true(c.equal(b, comp(c, "f64.normal", "f64")))
    assert_equal(
        c.count(comp(c, "f64.nan | f64.inf", "f64")),
        c.count(comp(c, "f64.nan", "f64")) + 2,
    )


def test_minus_and_and_precedence() raises:
    var c = SetContext()
    var small = comp(c, "f64.range(-0x1p-26, 0x1p-26) & f64.normal", "f64")
    var classes = Dict[String, BitSet]()
    classes["small"] = small
    var parsed = comp(c, "f64.range(-0x1p20, 0x1p20) & f64.normal - small", "f64", classes)
    var explicit = comp(
        c, "(f64.range(-0x1p20, 0x1p20) & f64.normal) - small", "f64", classes
    )
    assert_true(c.equal(parsed, explicit))


# Names and errors


def test_earlier_classes_by_name() raises:
    var c = SetContext()
    var nan = comp(c, "f64.nan", "f64")
    var classes = Dict[String, BitSet]()
    classes["nan"] = nan
    assert_true(
        c.equal(comp(c, "f64.all - nan", "f64", classes), c.difference(c.full(64), nan))
    )
    var message = error_of(c, "f64.all - later", "f64", classes)
    assert_true("unknown class later" in message, message)


def test_type_mismatch() raises:
    var c = SetContext()
    assert_error(c, "f64.nan", "f32", "f64.nan is a set of f64 values, but this partition is of f32")
    assert_error(c, "i32.range(0, 1)", "i64", "i32.range is a set of i32 values")
    var classes = Dict[String, BitSet]()
    classes["small"] = comp(c, "f32.nan", "f32")
    var message = error_of(c, "small", "f64", classes)
    assert_true("class small is a set of 32-bit values" in message, message)


def test_unknown_and_misused_names() raises:
    var c = SetContext()
    assert_error(c, "f64.normals", "f64", "f64 has no set normals")
    assert_error(c, "i32.nan", "i32", "i32 has no set nan")
    assert_error(c, "f64.max", "f64", "is a value, not a set; write {f64.max}")
    assert_error(c, "f64", "f64", "f64 is a type; write f64.all")
    assert_error(c, "mp.cos", "f64", "mp.cos is not a partition set")


def test_predicates_are_not_sets() raises:
    var c = SetContext()
    assert_error(c, "len(b) == 4", "f64", "expected a set expression, got the operator ==")
    assert_error(c, "is_nan(x)", "f64", "got a call to is_nan")
    assert_error(c, "f64.nan + f64.inf", "f64", "got the operator +")


def test_range_arity_and_constants() raises:
    var c = SetContext()
    assert_error(c, "f64.range(0)", "f64", "takes two bounds")
    assert_error(c, "f64.range(x, 1)", "f64", "expected a constant, got x")
    assert_error(c, "f64.pattern(1)", "f64", "takes one string")
    assert_error(c, "bool.range(0, 1)", "bool", "bool has no range")


def test_errors_carry_the_span_of_the_offending_node() raises:
    var c = SetContext()
    var ast = parse_set_expr("f64.nan | f64.range(0.1, 1)", 4)
    var types = Types()
    var message = String()
    try:
        _ = compile_set(c, ast, types, types.scalar("f64").value(), set_expr_node(ast), _classes())
    except e:
        message = String(e)
    var col = 11 + "f64.nan | f64.range(".byte_length()
    assert_true(message.startswith("t.spec:7:" + String(col) + ": "), message)


def test_aliases() raises:
    var c = SetContext()
    var ast = parse_set_expr("Angle.range(0, Angle.max)")
    var types = Types()
    var f64 = types.scalar("f64").value()
    var aliases = Dict[String, Int]()
    aliases["Angle"] = f64
    var s = compile_set_aliased(c, ast, types, f64, set_expr_node(ast), _classes(), aliases)
    assert_true(not c.is_empty(s))
    var raised = False
    try:
        _ = compile_set(c, ast, types, f64, set_expr_node(ast), _classes())
    except:
        raised = True
    assert_true(raised)


def test_non_fixed_width_element_is_refused() raises:
    var c = SetContext()
    var ast = parse_set_expr("{1}")
    var types = Types()
    var raised = False
    try:
        _ = compile_set(c, ast, types, types.int_(), set_expr_node(ast), _classes())
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
