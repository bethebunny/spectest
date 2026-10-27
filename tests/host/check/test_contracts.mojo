from std.testing import assert_equal, assert_true, assert_false, TestSuite

from check.types import Types, ANY_TYPE, LIST, FIXED_INT
from check.spec import Spec, Resolution, R_PARAM, R_QERR_PART, R_EXTERN
from prelude.names import prelude_id, prelude_name, prelude_count
from syntax.ast import Ast


def test_types_intern() raises:
    var t = Types()
    var f64 = t.scalar("f64").value()
    var a = t.list_of(f64)
    var b = t.list_of(t.scalar("f64").value())
    assert_equal(a, b)
    assert_equal(t.text(a), "list<f64>")
    assert_equal(t.kind(a), LIST)
    var i32 = t.scalar("i32").value()
    assert_equal(t.kind(i32), FIXED_INT)
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


def test_spec_tables() raises:
    var spec = Spec("s", Ast("x", "s.spec"), Types())
    assert_equal(len(spec.node_types), 1)
    spec.resolutions[0] = Resolution(R_PARAM, 2, -1, "x")
    assert_equal(spec.resolution(0).value().index, 2)
    assert_false(spec.resolution(5))


def test_resolution_kinds_are_distinct() raises:
    assert_equal(Int(R_QERR_PART), 17)
    assert_equal(Int(R_EXTERN), 18)


def test_prelude_names() raises:
    assert_equal(prelude_id("len").value(), 27)
    assert_equal(prelude_name(prelude_id("mp.cos").value()), "mp.cos")
    assert_false(prelude_id("nope"))
    assert_equal(prelude_count(), 56)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
