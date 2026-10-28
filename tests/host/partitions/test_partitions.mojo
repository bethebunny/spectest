from std.testing import assert_equal, assert_true, assert_false, TestSuite

from partition.coverage import PartitionSets, compile_partitions
from partition.requires import admitted
from partition.sets import SetContext
from partitions_testing import build_spec
from spec.spec import Spec


def errors_of(source: String) raises -> String:
    """The message compile_partitions raises for a spec, or "" if it compiles."""
    var spec = build_spec(source)
    var c = SetContext()
    try:
        _ = compile_partitions(c, spec)
    except e:
        return String(e)
    return String()


def warnings_of(source: String) raises -> List[String]:
    var spec = build_spec(source)
    var c = SetContext()
    var sets = compile_partitions(c, spec)
    var out = List[String]()
    for w in sets.warnings:
        out.append(String(w))
    return out^


comptime COS = """spec t
fn cos(x: f64) -> f64
  partition x
    nan       = f64.nan
    inf       = f64.inf
{zero}
    subnormal = f64.subnormal
    small     = {small}
    moderate  = f64.range(-0x1p20, 0x1p20) & f64.normal - small
    huge      = f64.normal - small - moderate
"""


def cos(zero: String = "    zero      = f64.zero", small: String = "f64.range(-0x1p-26, 0x1p-26) & f64.normal") -> String:
    return String(COS).replace("{zero}", zero).replace("{small}", small)


def test_a_correct_partition_compiles() raises:
    var spec = build_spec(cos())
    var c = SetContext()
    var sets = compile_partitions(c, spec)
    assert_equal(sets.class_count(0, 0), 7)
    assert_false(sets.is_predicate(0, 0, 0))
    assert_equal(len(sets.warnings), 0)
    var nan = sets.set_of(0, 0, 0)
    assert_true(c.contains(nan, 0x7FF8000000000000))
    assert_true(c.contains(sets.set_of(0, 0, 2), 1 << 63))


def test_missing_class_is_reported_with_an_example() raises:
    assert_equal(
        errors_of(cos(zero="")),
        "t.spec:3:3: partition x of cos does not cover every f64: 2 values in no class, "
        "e.g. x = 0.0 (0x0000000000000000)",
    )


def test_overlap_messages() raises:
    var message = errors_of(cos(small="f64.range(-0x1p-26, 0x1p-26)"))
    var lines = message.split("\n")
    assert_equal(len(lines), 2)
    assert_equal(
        String(lines[0]),
        "t.spec:8:5: partition x of cos: classes zero and small overlap on 2 values, "
        "e.g. x = 0.0 (0x0000000000000000)",
    )
    assert_equal(
        String(lines[1]),
        "t.spec:8:5: partition x of cos: classes subnormal and small overlap on about "
        "2^53.0 values, e.g. x = 5e-324 (0x0000000000000001)",
    )


def test_sqrt_forgetting_negative_zero() raises:
    assert_equal(
        errors_of(
            """spec t
fn sqrt(x: f64) -> f64
  partition x
    nan       = f64.nan
    negative  = f64.negative - f64.nan
    zero      = f64.zero
    subnormal = f64.subnormal & f64.positive
    normal    = f64.normal & f64.positive
    inf       = f64.inf & f64.positive
"""
        ),
        "t.spec:6:5: partition x of sqrt: classes negative and zero overlap on 1 value, "
        "e.g. x = -0.0 (0x8000000000000000)",
    )


def test_pack_i32_off_by_one() raises:
    assert_equal(
        errors_of(
            """spec t
fn pack_i32(x: i64) -> bytes
  partition x
    in_range  = i64.range(i32.min, i32.max)
    too_small = i64.range(none, i32.min)
    too_large = i64.range(i32.max + 1, none)
"""
        ),
        "t.spec:3:3: partition x of pack_i32 does not cover every i64: 1 value in no "
        "class, e.g. x = 2147483647",
    )


def test_type_mismatch_is_reported_once() raises:
    assert_equal(
        errors_of(
            """spec t
fn cos(x: f64) -> f64
  partition x
    nan   = f32.nan
    rest  = f64.all - nan
"""
        ),
        "t.spec:4:13: partition x of cos: class nan: f32.nan is a set of f32 values, "
        "but this partition is of f64",
    )


def test_bad_bound_points_at_the_bound() raises:
    var message = errors_of(
        """spec t
fn f(x: f32) -> f32
  partition x
    low  = f32.range(none, 0.1)
    high = f32.range(0.1, none)
    nan  = f32.nan
"""
    )
    var lines = message.split("\n")
    assert_equal(len(lines), 2)
    assert_equal(
        String(lines[0]),
        "t.spec:4:28: partition x of f: class low: f32.range bound 0.1 is not exactly "
        "representable in f32",
    )
    assert_equal(
        String(lines[1]),
        "t.spec:5:22: partition x of f: class high: f32.range bound 0.1 is not exactly "
        "representable in f32",
    )


def test_errors_of_several_functions_come_together() raises:
    var message = errors_of(
        """spec t
fn a(x: u8) -> u8
  partition x
    low = u8.range(0, 100)
fn b(x: u8) -> u8
  partition x
    low = u8.range(0, 128)
    high = u8.range(100, none)
"""
    )
    var lines = message.split("\n")
    assert_equal(len(lines), 2)
    assert_true("partition x of a does not cover every u8: 156 values" in String(lines[0]))
    assert_true("partition x of b: classes low and high overlap on 28 values" in String(lines[1]))


def test_duplicate_and_empty_classes() raises:
    assert_equal(
        errors_of(
            """spec t
fn f(x: u8) -> u8
  partition x
    low  = u8.range(0, 128)
    low  = u8.range(128, none)
"""
        ),
        "t.spec:5:5: partition x of f: class low is defined twice",
    )
    var warnings = warnings_of(
        """spec t
fn f(x: u8) -> u8
  partition x
    all   = u8.all
    none_ = u8.range(5, 5)
"""
    )
    assert_equal(len(warnings), 1)
    assert_equal(warnings[0], "t.spec:5:5: partition x of f: class none_ is empty")


def test_predicate_class_on_a_fixed_width_parameter() raises:
    var message = errors_of(
        """spec t
fn f(x: f64) -> f64
  partition x
    big   = x > 1
    other = x <= 1
"""
    )
    var lines = message.split("\n")
    assert_equal(len(lines), 2)
    for line in lines:
        assert_true("expected a set expression, got the operator" in String(line))


def test_other_parameter_types_are_predicates() raises:
    var spec = build_spec(
        """spec t
fn f(xs: list<u8>, n: i32, s: string) -> u8
  partition xs
    naturals = all(x in xs: x >= 0)
    some = exists(x in xs: x < 0)
  partition s
    a = len(s) == 0
  partition n
    low = i32.negative
    high = i32.range(0, none)
"""
    )
    var c = SetContext()
    var sets = compile_partitions(c, spec)
    assert_equal(sets.class_count(0, 0), 2)
    assert_true(sets.is_predicate(0, 0, 0) and sets.is_predicate(0, 0, 1))
    assert_true(sets.is_predicate(0, 1, 0))
    assert_false(sets.is_predicate(0, 2, 0))
    assert_true(c.contains(sets.set_of(0, 2, 0), 0xFFFFFFFF))


def test_generic_and_interface_partitions() raises:
    var spec = build_spec(
        """spec t
fn id<T>(x: T, n: u8) -> T
  partition x
    any = true
  partition n
    low = u8.range(0, 10)
    high = u8.range(10, none)
interface Deque<T>
  method pop(self, n: u8) -> T
    partition n
      zero = {0}
      rest = u8.range(1, none)
"""
    )
    var c = SetContext()
    var sets = compile_partitions(c, spec)
    assert_true(sets.is_predicate(0, 0, 0))
    assert_false(sets.is_predicate(0, 1, 1))
    assert_equal(sets.class_count(1, 0), 2)
    assert_equal(spec.fns[1].decl_id, "Deque.pop")


def test_type_aliases() raises:
    var spec = build_spec(
        """spec t
type Angle = f64
fn f(x: Angle) -> Angle
  partition x
    nan = Angle.nan
    rest = Angle.all - nan
"""
    )
    var c = SetContext()
    var sets = compile_partitions(c, spec)
    assert_equal(sets.class_count(0, 0), 2)
    assert_false(sets.is_predicate(0, 0, 0))


# requires narrows the target


def test_requires_not_nan_lets_the_partition_skip_nan() raises:
    assert_equal(
        errors_of(
            """spec t
fn fill(value: f64) -> f64
  requires not is_nan(value)
  partition value
    zero   = f64.zero
    finite = f64.finite - f64.zero
    inf    = f64.inf
"""
        ),
        "",
    )


def test_requires_coverage_error_mentions_requires() raises:
    assert_equal(
        errors_of(
            """spec t
fn f(x: f64) -> f64
  requires x >= 0
  partition x
    pos = f64.positive - f64.zero - f64.nan
"""
        ),
        "t.spec:4:3: partition x of f does not cover the values requires admits: 2 values in "
        "no class, e.g. x = 0.0 (0x0000000000000000)",
    )


def test_class_outside_requires_is_a_warning() raises:
    var warnings = warnings_of(
        """spec t
fn f(x: f64) -> f64
  requires x >= 0
  partition x
    everything = f64.all
"""
    )
    assert_equal(len(warnings), 1)
    assert_true(
        warnings[0].startswith(
            "t.spec:5:5: partition x of f: class everything has about 2^63.0 values"
        )
    )
    assert_true(warnings[0].endswith("that requires rejects, e.g. x = -1.0 (0xbff0000000000000)"))


def test_requires_fits_on_ints() raises:
    assert_equal(
        errors_of(
            """spec t
fn g(n: i64) -> i32
  requires fits<i32>(n)
  partition n
    negative = i64.range(i32.min, 0)
    other    = i64.range(0, i32.max + 1)
"""
        ),
        "",
    )


def test_requires_conjuncts_on_other_parameters_are_ignored() raises:
    assert_equal(
        errors_of(
            """spec t
fn h(x: u8, xs: list<u8>) -> u8
  requires x > 0 and len(xs) > 0
  requires len(xs) < 10
  partition x
    low  = u8.range(1, 128)
    high = u8.range(128, none)
"""
        ),
        "",
    )


def test_requires_not_about_the_parameter_targets_the_whole_type() raises:
    var message = errors_of(
        """spec t
fn h(x: u8, y: u8) -> u8
  requires x > 0 or y > 0
  partition x
    low  = u8.range(1, 128)
    high = u8.range(128, none)
"""
    )
    assert_true("does not cover every u8: 1 value in no class, e.g. x = 0" in message, message)


def test_admitted_sets() raises:
    var spec = build_spec(
        """spec t
fn f(x: u8, y: f32, b: bool, n: i16) -> u8
  requires x >= 10 and x < 20
  requires 5 < x
  requires y > 0 and y <= 1
  requires b
  requires n in [1, 2, 5] or n == 100
"""
    )
    var c = SetContext()
    var x = admitted(c, spec, 0, 0).value()
    assert_equal(c.count(x), UInt128(10))
    assert_true(c.contains(x, 10) and c.contains(x, 19))
    assert_false(c.contains(x, 20) or c.contains(x, 9))
    var y = admitted(c, spec, 0, 1).value()
    assert_false(c.contains(y, 0) or c.contains(y, 1 << 31))
    assert_true(c.contains(y, 0x3F800000))
    assert_false(c.contains(y, 0x3F800001))
    assert_false(c.contains(y, 0x7FC00000))
    assert_true(c.contains(y, 1))
    assert_true(c.contains(y, 0x80000001) == False)
    var b = admitted(c, spec, 0, 2).value()
    assert_true(c.contains(b, 1) and not c.contains(b, 0))
    var n = admitted(c, spec, 0, 3).value()
    assert_equal(c.count(n), UInt128(4))
    assert_true(c.contains(n, 100) and c.contains(n, 5) and not c.contains(n, 3))


def test_admitted_is_none_without_set_like_requires() raises:
    var spec = build_spec(
        """spec t
fn f(x: f64, y: f64) -> f64
  requires x > y
  requires is_finite(y)
"""
    )
    var c = SetContext()
    assert_false(admitted(c, spec, 0, 0))
    assert_true(admitted(c, spec, 0, 1))


def test_admitted_float_logic() raises:
    var spec = build_spec(
        """spec t
fn f(x: f64) -> f64
  requires (x > 0 or x < -1) and not is_inf(x)
"""
    )
    var c = SetContext()
    var s = admitted(c, spec, 0, 0).value()
    assert_true(c.contains(s, 0x3FF0000000000000))
    assert_false(c.contains(s, 0))
    assert_true(c.contains(s, 0xC000000000000000))
    assert_false(c.contains(s, 0xBFF0000000000000))
    assert_false(c.contains(s, 0x7FF0000000000000))
    assert_false(c.contains(s, 0x7FF8000000000000))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
