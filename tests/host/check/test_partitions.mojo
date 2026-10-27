from std.testing import assert_equal, assert_true, TestSuite

from check.spec import R_CLASS
from check.testkit import fails, named, nodes_of, ok, type_text
from syntax import ast


def test_fixed_width_classes_are_sets() raises:
    var spec = ok(
        "fn f(x: i64, y: u8, b: bool, z: f32)\n"
        "  partition x\n"
        "    lo = i64.range(none, i32.min)\n"
        "    mid = i64.range(i32.min, i32.max + 1)\n"
        "    hi = i64.all - lo - mid\n"
        "  partition y\n"
        "    small = {0, 1, 2}\n"
        "    big = u8.all - small\n"
        "  partition b\n"
        "    t = {true}\n"
        "    f = bool.all - t\n"
        "  partition z\n"
        "    special = f32.nan | f32.inf | {0, f32.max, -f32.max}\n"
        '    pat = f32.pattern("0 11111111 0*")\n'
        "    other = f32.all - special - pat\n"
    )
    var fun = spec.fns[spec.fn_named("f").value()].copy()
    assert_equal(len(fun.partitions), 4)
    var want = ["set<i64>", "set<u8>", "set<bool>", "set<f32>"]
    var counts = [3, 2, 2, 3]
    for i in range(4):
        assert_equal(len(fun.partitions[i].classes), counts[i])
        assert_equal(fun.partitions[i].param, i)
        for cls in fun.partitions[i].classes:
            assert_equal(type_text(spec, cls.expr), want[i])
    var lo = fun.partitions[0].classes[0].expr
    var none = spec.ast.kid(spec.ast.kid(lo, 2), 0)
    assert_equal(spec.ast.nodes[none].kind, ast.NONE)
    assert_equal(type_text(spec, none), "option<?>")


def test_predicate_classes() raises:
    var spec = ok(
        "model M\n  observe n: int\n"
        "fn f(xs: list<int>, s: string, m: M)\n"
        "  partition xs\n"
        "    empty = len(xs) == 0\n"
        "    one = len(xs) == 1\n"
        "    more = not empty and not one\n"
        "  partition m\n"
        "    zero = m.n == 0\n"
        "    other = m.n != 0\n"
    )
    var fun = spec.fns[spec.fn_named("f").value()].copy()
    var part = fun.partitions[0].copy()
    var more = part.classes[2].expr
    var empty_ref = named(spec, more, ast.NAME, "empty")[0]
    var one_ref = named(spec, more, ast.NAME, "one")[0]
    assert_equal(spec.resolution(empty_ref).value().kind, R_CLASS)
    assert_equal(spec.resolution(empty_ref).value().index, part.classes[0].node)
    assert_equal(spec.resolution(one_ref).value().index, part.classes[1].node)
    for p in fun.partitions:
        for cls in p.classes:
            assert_equal(type_text(spec, cls.expr), "bool")
    assert_equal(fun.partitions[1].param, 2)


def partition_error(body: String, message: String) raises:
    fails(body, message)


def test_partition_errors() raises:
    partition_error(
        "fn f(x: f64)\n  partition x\n    nan = is_nan(x)\n",
        "classes of the fixed-width parameter x are sets of values, so x cannot appear",
    )
    partition_error("fn f(x: f64)\n  partition x\n    a = x > 0\n", "x cannot appear in them")
    partition_error(
        "fn f(x: i64)\n  partition x\n    a = i32.all\n",
        "class a of the i64 parameter x must be a set of i64 values",
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f32.nan | f64.nan\n",
        "cannot combine a set of f32 with a set of f64",
    )
    partition_error("fn f(x: f64)\n  partition x\n    a = 1\n", "must be a set of f64 values")
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = b\n    b = f64.nan\n", "unknown name b"
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.nan\n    a = f64.inf\n",
        "already has a class named a",
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.all\n  partition x\n    b = f64.all\n",
        "x is already partitioned at line 3",
    )
    partition_error("fn f(x: f64)\n  partition y\n    a = f64.all\n", "f has no parameter y")
    partition_error(
        "fn f(x: f64)\n  partition x\n    x = f64.all\n",
        "class x has the name of a parameter",
    )
    partition_error('fn f(x: f64)\n  partition x\n    a = {"s"}\n', "a member of a set of f64")
    partition_error("fn f(x: u8)\n  partition x\n    a = {0.5}\n", "a member of a set of u8")
    partition_error("fn f(x: f64)\n  partition x\n    a = f64.range(0)\n", "takes two bounds")
    partition_error(
        'fn f(x: f64)\n  partition x\n    a = f64.range("a", none)\n',
        "a bound of f64.range must be a number or none",
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.pattern(1)\n", "takes one string literal"
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.bogus\n", "f64 has no constant bogus"
    )
    partition_error(
        "fn f(x: f64)\n  partition x\n    a = f64.range\n", "f64.range is called"
    )
    partition_error("fn f(x: i8)\n  partition x\n    a = i8.nan\n", "i8 has no constant nan")
    partition_error(
        "fn f(x: bool)\n  partition x\n    a = bool.range(0, 1)\n", "bool has no range"
    )
    partition_error(
        "fn f(xs: list<int>, n: int)\n  partition xs\n    a = len(xs) == n\n",
        "a class of partition xs may only refer to xs, not to n",
    )
    partition_error(
        "fn f(xs: list<int>)\n  partition xs\n    a = len(xs)\n",
        "class a (a predicate over xs) must be a bool",
    )
    partition_error(
        "fn f(xs: list<int>)\n  partition xs\n    a = f64.nan\n", "f64.nan is a partition set"
    )
    partition_error(
        "fn f(xs: list<int>)\n  partition xs\n    a = {1}\n", "{...} is a partition set"
    )
    partition_error(
        "interface Q\n  observe n: int\n  method m(self)\n    partition self\n      a = true\n",
        "self cannot be partitioned",
    )
    partition_error(
        "fn f(x: f64) -> f64\n  partition x\n    a = f64.range(0, result)\n",
        "a partition class describes an input",
    )


def test_sets_outside_partitions() raises:
    fails(
        "fn f(x: f64)\n  requires x in f64.nan\n",
        "f64.nan is a partition set",
    )
    fails("fn f(x: f64)\n  requires x in f64.nan\n", "test the value with is_nan(x)")
    fails(
        "fn f(x: f64)\n  ensures f64.range(0, 1) == f64.range(0, 1)\n",
        "f64.range(...) is a partition set",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
