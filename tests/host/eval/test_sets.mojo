from std.testing import assert_equal, assert_true, TestSuite

from check.spec import Spec
from eval.api import class_holds
from eval.core import set_contains
from eval_testkit import *
from numeric.formats import F16
from wire.value import Value


def has(message: String, fragment: String) raises:
    assert_true(fragment in message, "'" + fragment + "' not in '" + message + "'")


def class_node(spec: Spec, fn_pos: Int, partition: Int, index: Int) -> Int:
    return spec.fns[fn_pos].partitions[partition].classes[index].node


def test_classes_of_an_integer_parameter() raises:
    var spec = spec_of("fn f(x: u8) -> u8\n  partition x\n    small = u8.range(0, 10)\n    odd = {11, 13}\n    rest = u8.all - small - odd\n  ensures e: true\n")
    var host = Mock()
    var small = class_node(spec, 0, 0, 0)
    var odd = class_node(spec, 0, 0, 1)
    var rest = class_node(spec, 0, 0, 2)
    for x in [0, 5, 9]:
        assert_true(class_holds(spec, small, Value.int(x), host))
        assert_true(not class_holds(spec, odd, Value.int(x), host))
        assert_true(not class_holds(spec, rest, Value.int(x), host))
    for x in [11, 13]:
        assert_true(class_holds(spec, odd, Value.int(x), host))
        assert_true(not class_holds(spec, small, Value.int(x), host))
    for x in [10, 12, 14, 255]:
        assert_true(class_holds(spec, rest, Value.int(x), host))
        assert_true(not class_holds(spec, small, Value.int(x), host))
    assert_true(not class_holds(spec, small, Value.int(10), host))
    assert_true(not class_holds(spec, small, Value.int(255), host))


def test_classes_of_a_signed_parameter() raises:
    var spec = spec_of("fn f(x: i8) -> i8\n  partition x\n    neg = i8.range(-128, 0)\n    nonneg = i8.all - neg\n  ensures e: true\n")
    var host = Mock()
    var neg = class_node(spec, 0, 0, 0)
    var nonneg = class_node(spec, 0, 0, 1)
    assert_true(class_holds(spec, neg, Value.int(-128), host))
    assert_true(class_holds(spec, neg, Value.int(-1), host))
    assert_true(not class_holds(spec, neg, Value.int(0), host))
    assert_true(class_holds(spec, nonneg, Value.int(127), host))
    assert_true(not class_holds(spec, nonneg, Value.int(-5), host))


def test_classes_of_a_float_parameter() raises:
    var spec = spec_of("fn f(x: f64) -> f64\n  partition x\n    nan = f64.nan\n    inf = f64.inf\n    negative = f64.negative - nan - inf\n    rest = f64.all - nan - inf - negative\n  ensures e: true\n")
    var host = Mock()
    var nan = class_node(spec, 0, 0, 0)
    var inf = class_node(spec, 0, 0, 1)
    var negative = class_node(spec, 0, 0, 2)
    var rest = class_node(spec, 0, 0, 3)
    assert_true(class_holds(spec, nan, nan64(), host))
    assert_true(not class_holds(spec, nan, f64v(1.0), host))
    assert_true(class_holds(spec, inf, inf64(True), host))
    assert_true(class_holds(spec, inf, inf64(), host))
    assert_true(class_holds(spec, negative, f64v(-2.5), host))
    assert_true(not class_holds(spec, negative, inf64(True), host))
    assert_true(class_holds(spec, rest, f64v(2.5), host))
    assert_true(not class_holds(spec, rest, f64v(-2.5), host))
    assert_true(not class_holds(spec, rest, nan64(), host))


def test_predicate_classes_evaluate_on_the_value() raises:
    var spec = spec_of("fn g(n: int, xs: list<int>) -> int\n  partition xs\n    empty = len(xs) == 0\n    long = len(xs) > 3\n  ensures e: true\n")
    var host = Mock()
    var empty = class_node(spec, 0, 0, 0)
    var long = class_node(spec, 0, 0, 1)
    assert_true(class_holds(spec, empty, ints(), host))
    assert_true(not class_holds(spec, empty, ints(1), host))
    assert_true(class_holds(spec, long, ints(1, 2, 3, 4), host))
    assert_true(not class_holds(spec, long, ints(1, 2, 3), host))


def test_a_node_that_is_not_a_class_is_an_error() raises:
    var spec = spec_of("fn f(x: u8) -> u8\n  partition x\n    a = u8.all\n  ensures e: true\n")
    var host = Mock()
    try:
        _ = class_holds(spec, 1, Value.int(1), host)
        assert_true(False, "expected an error")
    except e:
        has(String(e), "is not a partition class")


def test_membership_in_a_set_expression() raises:
    var spec = spec_of("fn f(x: u8) -> u8\n  aggregate total: sum(v in u8.range(1, 4) | {9}: v) <= 20\n")
    var clause = spec.clauses[clause_pos(spec, "f.total")].expr
    var set_node = spec.ast.child(spec.ast.child(clause, 0), 0)
    for x in [1, 2, 3, 9]:
        assert_true(set_contains(spec, set_node, Value.int(x)))
    for x in [0, 4, 8, 10, 255]:
        assert_true(not set_contains(spec, set_node, Value.int(x)))
    var host = Mock()
    assert_true(judge_clause(spec, "f.total", Env(), host).is_true())


def test_aggregates_over_integer_sets() raises:
    var spec = spec_of("fn f(x: u8) -> u8\n  aggregate total: sum(v in u8.range(1, 4): v) <= 10\n  aggregate tight: sum(v in u8.range(1, 4): v) <= 5\n  aggregate top: max(v in i8.range(-3, 2): v + 3) <= 5\n  aggregate allbig: all(v in u8.range(200, 205): v > 100)\n  aggregate notall: all(v in u8.range(95, 105): v > 100)\n")
    var host = Mock()
    var env = Env()
    assert_true(judge_clause(spec, "f.total", env, host).is_true())
    assert_true(judge_clause(spec, "f.tight", env, host).is_false())
    assert_true(judge_clause(spec, "f.top", env, host).is_true())
    assert_true(judge_clause(spec, "f.allbig", env, host).is_true())
    assert_true(judge_clause(spec, "f.notall", env, host).is_false())


def test_aggregates_over_bool_and_float_sets() raises:
    var spec = spec_of("fn f(x: f16) -> f16\n  aggregate unit: max(v in f16.range(0, 1): real(v)) <= 1\n  aggregate below: max(v in f16.range(0, 1): real(v)) < 1\n  aggregate over: max(v in f16.range(0, 2): real(v)) < 1\n  aggregate bools: all(b in bool.all: b or not b)\n")
    var host = Mock()
    var env = Env()
    assert_true(judge_clause(spec, "f.unit", env, host).is_true())
    assert_true(judge_clause(spec, "f.below", env, host).is_true())
    assert_true(judge_clause(spec, "f.over", env, host).is_false())
    assert_true(judge_clause(spec, "f.bools", env, host).is_true())


def test_aggregate_terms_are_planned_calls() raises:
    var spec = spec_of("fn g(x: f16) -> f16\n  aggregate calls: sum(v in f16.range(0, 0x1p-20): qe(g(v), v)) <= 120\n  aggregate tight: sum(v in f16.range(0, 0x1p-20): qe(g(v), v)) <= 119\n")
    var host = Mock()
    host.on_call(0, Value.float(F16, UInt64(0)))
    assert_true(judge_clause(spec, "g.calls", Env(), host).is_true())
    assert_equal(host.calls("call"), 17)  # zero, -0 and the fifteen subnormals below 2**-20
    assert_true(judge_clause(spec, "g.tight", Env(), host).is_false())
    # A planned call that raises in the library skips the clause.
    host.on_call(0, Value.error("E", [], "no"))
    assert_true(judge_clause(spec, "g.calls", Env(), host).is_skip())


def test_a_set_that_is_too_large_is_an_error() raises:
    var spec = spec_of("fn f(x: u32) -> u32\n  aggregate big: sum(v in u32.all: v) <= 1\n")
    var host = Mock()
    var j = judge_clause(spec, "f.big", Env(), host)
    assert_true(j.is_error())
    has(j.message, "more than 65536")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
