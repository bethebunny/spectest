from std.testing import assert_equal, assert_true, assert_false, TestSuite

from host.decode import decode, encode
from host.util import (
    collect_models,
    contains_name,
    handles_of,
    names_text,
    norm_name,
    parse_type,
    type_has_model,
)
from host.verdict import CAUSE_COUNT, CAUSE_NAMES, Cause
from spec.types import Types
from value.bigint import BigInt
from value.float_formats import BF16, F16, F32, F64
from value.text import format_value
from value.value import Value


def fails(v: Value, t: Int, types: Types, fragment: String) raises:
    try:
        _ = decode(v, t, types)
    except e:
        assert_true(fragment in String(e), "'" + fragment + "' not in '" + String(e) + "'")
        return
    assert_true(False, "expected a failure mentioning " + fragment)


def test_options() raises:
    var types = Types()
    var o = types.option_of(types.fixed(8, False))
    assert_true(decode(Value.none(), o, types) == Value.none())
    assert_true(decode(Value.int(3), o, types) == Value.some(Value.int(3)))
    assert_true(decode(Value.some(Value.int(3)), o, types) == Value.some(Value.int(3)))
    fails(Value.int(300), o, types, "outside the u8 range 0..255")
    fails(Value.string("x"), o, types, "expected u8, got string")


def test_fixed_width_integers_are_range_checked() raises:
    var types = Types()
    var i8 = types.fixed(8, True)
    assert_true(decode(Value.int(-128), i8, types) == Value.int(-128))
    assert_true(decode(Value.int(127), i8, types) == Value.int(127))
    fails(Value.int(128), i8, types, "outside the i8 range -128..127")
    fails(Value.int(-129), i8, types, "outside the i8 range")
    var u64 = types.fixed(64, False)
    var big = Value.int(BigInt.parse("18446744073709551615"))
    assert_true(decode(big, u64, types) == big)
    fails(Value.int(BigInt.parse("18446744073709551616")), u64, types, "outside the u64 range")
    fails(Value.bool(True), i8, types, "expected i8, got bool")
    var unbounded = types.int_()
    var huge = Value.int(BigInt.parse("123456789012345678901234567890"))
    assert_true(decode(huge, unbounded, types) == huge)


def test_floats_of_a_wider_format_are_accepted_when_exact() raises:
    var types = Types()
    var f32 = types.float_(3)
    var f16 = types.float_(1)
    var bf16 = types.float_(2)
    var half = Value.float(F64, UInt64(0x3FE0000000000000))
    assert_true(decode(half, f32, types) == Value.float(F32, UInt64(0x3F000000)))
    assert_true(decode(half, f16, types) == Value.float(F16, UInt64(0x3800)))
    assert_true(decode(half, bf16, types) == Value.float(BF16, UInt64(0x3F00)))
    # 0.1 is not exact in f32.
    fails(Value.float(F64, UInt64(0x3FB999999999999A)), f32, types, "not exact in f32")
    # Zeros keep their sign, infinities stay infinite, exact values narrow.
    assert_true(decode(Value.float(F64, UInt64(0x8000000000000000)), f32, types) == Value.float(F32, UInt64(0x80000000)))
    assert_true(decode(Value.float(F64, UInt64(0x7FF0000000000000)), f16, types) == Value.float(F16, UInt64(0x7C00)))
    # A float of the right format passes untouched; a number is not a float.
    var same = Value.float(F32, UInt64(0x3F800000))
    assert_true(decode(same, f32, types) == same)
    fails(Value.int(1), f32, types, "expected f32, got int")


def test_nans_narrow_when_the_payload_fits() raises:
    var types = Types()
    var f32 = types.float_(3)
    # The default quiet NaN of f64 and of f32.
    var nan64 = Value.float(F64, UInt64(0x7FF8000000000000))
    assert_true(decode(nan64, f32, types) == Value.float(F32, UInt64(0x7FC00000)))
    # A payload in the low bits of f64 cannot be held by f32.
    fails(Value.float(F64, UInt64(0x7FF8000000000001)), f32, types, "NaN payload")
    var negative = Value.float(F64, UInt64(0xFFF8000000000000))
    assert_true(decode(negative, f32, types) == Value.float(F32, UInt64(0xFFC00000)))


def test_records_come_from_records_or_maps() raises:
    var types = Types()
    var u8 = types.fixed(8, False)
    var str = types.string()
    var r = types.record("pkg.R", ["a", "b"], [u8, str])
    var fields = List[String]()
    fields.append("b")
    fields.append("a")
    var values = List[Value]()
    values.append(Value.string("s"))
    values.append(Value.int(7))
    # Fields in any order come out in the declared order.
    var got = decode(Value.record("pkg.Other", fields, values^), r, types)
    assert_equal(format_value(got), 'pkg.R { a: 7, b: "s" }')
    var keys = List[Value]()
    keys.append(Value.string("a"))
    keys.append(Value.string("b"))
    var vals = List[Value]()
    vals.append(Value.int(1))
    vals.append(Value.string("x"))
    assert_equal(format_value(decode(Value.map(keys^, vals^), r, types)), 'pkg.R { a: 1, b: "x" }')
    var k2 = List[Value]()
    k2.append(Value.string("a"))
    var v2 = List[Value]()
    v2.append(Value.int(1))
    fails(Value.map(k2^, v2^), r, types, "missing field b")
    var k3 = List[Value]()
    k3.append(Value.string("a"))
    k3.append(Value.string("b"))
    k3.append(Value.string("c"))
    var v3 = List[Value]()
    v3.append(Value.int(1))
    v3.append(Value.string("x"))
    v3.append(Value.int(1))
    fails(Value.map(k3^, v3^), r, types, "no field c")
    var k4 = List[Value]()
    k4.append(Value.string("a"))
    k4.append(Value.string("b"))
    var v4 = List[Value]()
    v4.append(Value.int(256))
    v4.append(Value.string("x"))
    fails(Value.map(k4^, v4^), r, types, "at .a")


def test_enums_and_literal_unions() raises:
    var types = Types()
    var lit = types.literal(["any", "all"])
    assert_true(decode(Value.string("any"), lit, types) == Value.enum("", "any"))
    assert_true(decode(Value.enum("", "all"), lit, types) == Value.enum("", "all"))
    fails(Value.string("some"), lit, types, "not a member of the union")
    var color = types.enum_("pkg.Color", ["RED", "BLUE"])
    assert_true(decode(Value.enum("pkg.Color", "RED"), color, types) == Value.enum("pkg.Color", "RED"))
    assert_true(decode(Value.string("BLUE"), color, types) == Value.enum("pkg.Color", "BLUE"))
    fails(Value.enum("pkg.Other", "RED"), color, types, "an enum of pkg.Other")
    fails(Value.string("GREEN"), color, types, "GREEN is not a member")


def test_collections_are_read_element_by_element() raises:
    var types = Types()
    var u8 = types.fixed(8, False)
    var l = types.list_of(u8)
    var t = Value.tuple([Value.int(1), Value.int(2)])
    assert_true(decode(t, l, types) == Value.list([Value.int(1), Value.int(2)]))
    fails(Value.list([Value.int(1), Value.int(256)]), l, types, "at [1]")
    var pair = types.tuple_of([u8, types.string()])
    assert_true(decode(Value.list([Value.int(1), Value.string("a")]), pair, types) == Value.tuple([Value.int(1), Value.string("a")]))
    fails(Value.list([Value.int(1)]), pair, types, "expected (u8, string)")
    var m = types.map_of(types.string(), u8)
    var keys = List[Value]()
    keys.append(Value.string("k"))
    var vals = List[Value]()
    vals.append(Value.int(300))
    fails(Value.map(keys^, vals^), m, types, "outside the u8 range")


def test_handles_of_qualified_models_are_checked_against_the_class() raises:
    var types = Types()
    var qualified = types.model("pkg.Box", [], False)
    var abstract = types.model("Frame", [], False)
    var h = Value.handle(3, "pkg.Box")
    assert_true(decode(h, qualified, types) == h)
    fails(Value.handle(3, "pkg.Other"), qualified, types, "a handle of class pkg.Other")
    fails(Value.int(1), qualified, types, "expected pkg.Box, got int 1")
    # A model without a module path names no class to check against.
    assert_true(decode(Value.handle(4, "pandas.DataFrame"), abstract, types) == Value.handle(4, "pandas.DataFrame"))


def test_unit_and_unresolved_types() raises:
    var types = Types()
    assert_true(decode(Value.int(5), types.unit(), types) == Value.none())
    var tv = types.typevar("T", "Eq")
    assert_true(decode(Value.int(5), tv, types) == Value.int(5))
    fails(Value.int(5), types.real(), types, "cannot be read")


def test_encode_checks_the_shape() raises:
    var types = Types()
    var u8 = types.fixed(8, False)
    assert_true(encode(Value.int(1), u8, types) == Value.int(1))
    try:
        _ = encode(Value.int(-1), u8, types)
        assert_true(False)
    except e:
        assert_true("outside the u8 range" in String(e))


def test_parse_type() raises:
    var types = Types()
    var t = parse_type("list<option<i64>>", types)
    assert_equal(types.text(t), "list<option<i64>>")
    assert_equal(types.text(parse_type(" f32 ", types)), "f32")
    try:
        _ = parse_type("record<x>", types)
        assert_true(False)
    except e:
        assert_true("not a scalar" in String(e))


def test_error_names() raises:
    assert_equal(norm_name("builtins.ValueError"), "ValueError")
    assert_equal(norm_name("pkg.Error"), "pkg.Error")
    assert_true(contains_name(["builtins.ValueError"], "ValueError"))
    assert_false(contains_name(["pkg.ValueError"], "ValueError"))
    assert_equal(names_text(["b.E", "a.E", "b.E"]), "{a.E, b.E}")
    assert_equal(names_text(List[String]()), "{}")


def test_skip_causes() raises:
    var causes: List[Cause] = [.REQUIRES, .RAISED, .RAISE_DUE, .WRONG_TYPE, .UNREPRESENTABLE, .PLANNED_CALL, .OTHER]
    var names = materialize[CAUSE_NAMES]()
    for i, cause in enumerate(causes):
        assert_equal(cause.index(), i)
        assert_equal(String(cause), String(names[i]))
    assert_equal(Cause.OTHER.index(), CAUSE_COUNT - 1)
    assert_equal(String(Cause.RAISE_DUE), "raise due")


def test_models_inside_types() raises:
    var types = Types()
    var box = types.model("pkg.Box", [], False)
    var iface = types.model("pkg.Queue", [], True)
    var l = types.list_of(types.option_of(box))
    assert_true(type_has_model(types, l))
    assert_false(type_has_model(types, types.list_of(types.int_())))
    var names = List[String]()
    collect_models(types, types.tuple_of([l, box, iface]), names)
    assert_equal(len(names), 1)
    assert_equal(names[0], "pkg.Box")
    var v = Value.list([Value.some(Value.handle(1, "pkg.Box")), Value.none(), Value.some(Value.handle(2, "pkg.Box"))])
    var found = handles_of(types, v, l, "pkg.Box")
    assert_equal(len(found), 2)
    assert_equal(Int(found[1].handle_id()), 2)


def test_handles_inside_a_tuple() raises:
    var types = Types()
    var box = types.model("pkg.Box", [], False)
    var pair = types.tuple_of([box, box])
    var v = Value.tuple([Value.handle(3, "pkg.Box"), Value.handle(4, "pkg.Box")])
    var found = handles_of(types, v, pair, "pkg.Box")
    assert_equal(len(found), 2)
    assert_equal(Int(found[0].handle_id()), 3)
    assert_equal(Int(found[1].handle_id()), 4)
    assert_equal(len(handles_of(types, Value.tuple([Value.handle(3, "pkg.Box")]), pair, "pkg.Box")), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
