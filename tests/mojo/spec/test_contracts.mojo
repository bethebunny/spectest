from std.testing import assert_equal, assert_true, assert_false, TestSuite

from spec.ast import Ast
from spec.prelude_names import prelude_id, prelude_name, prelude_count
from spec.spec import Resolution, ResolutionKind, Spec
from spec.types import ANY_TYPE, TypeKind, Types


def test_types_intern() raises:
    var t = Types()
    var f64 = t.scalar("f64").value()
    var a = t.list_of(f64)
    var b = t.list_of(t.scalar("f64").value())
    assert_equal(a, b)
    assert_equal(t.text(a), "list<f64>")
    assert_equal(t.kind(a), TypeKind.List)
    var i32 = t.scalar("i32").value()
    assert_equal(t.kind(i32), TypeKind.FixedInt)
    assert_equal(t.text(t.map_of(t.string(), t.tuple_of([i32, t.bool_()]))), "map<string, (i32, bool)>")
    assert_equal(t.text(t.literal(["any", "all"])), "\"any\" | \"all\"")
    assert_false(t.has_canonical_eq(a))
    assert_true(t.has_canonical_eq(t.list_of(i32)))
    assert_true(t.has_total_order(t.list_of(t.string())))
    assert_false(t.has_total_order(t.qerr()))
    var tv = t.typevar("T", "Ord")
    var lt = t.list_of(tv)
    assert_equal(t.substitute(lt, ["T"], [i32]), t.list_of(i32))
    assert_equal(t.text(ANY_TYPE), "?")
    var r1 = t.record("pkg.R", ["x"], [i32])
    assert_equal(t.record("pkg.R", ["x"], [i32]), r1)


def test_types_intern_by_value() raises:
    var t = Types()
    assert_true(t.literal(["a", "b"]) != t.literal(["a\x1fb"]))
    assert_equal(t.enum_("pkg.E", ["a"]), t.enum_("pkg.E", ["b"]))


def test_spec_tables() raises:
    var spec = Spec("s", Ast("x", "s.spec"), Types())
    assert_equal(len(spec.node_types), 1)
    spec.resolutions[0] = Resolution(ResolutionKind.Param, 2, -1, "x")
    assert_equal(spec.resolution(0).value().index, 2)
    assert_false(spec.resolution(5))


def test_resolution_kinds_are_distinct() raises:
    assert_equal(Int(ResolutionKind.QerrPart), 16)
    assert_equal(Int(ResolutionKind.Extern), 17)


def test_prelude_names() raises:
    assert_equal(prelude_id("len").value(), 27)
    assert_equal(prelude_name(prelude_id("mp.cos").value()), "mp.cos")
    assert_false(prelude_id("nope"))
    assert_equal(prelude_count(), 56)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
