from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite

from check.checker import check_source
from check.spec import Spec
from eval.api import class_holds, explain, snapshot_olds
from eval.testkit import *
from numeric.formats import F64
from wire.value import Value


def has(message: String, fragment: String) raises:
    assert_true(fragment in message, "'" + fragment + "' not in '" + message + "'")


def example(name: String) raises -> Spec:
    var path = "examples/" + name + "/" + name + ".spec"
    return check_source(Path(path).read_text(), path)


def pairs_text(pairs: List[Tuple[String, String]]) -> String:
    var out = String()
    for p in pairs:
        out += "\n  " + p[0] + " => " + p[1]
    return out


def lookup(pairs: List[Tuple[String, String]], text: String) raises -> String:
    for p in pairs:
        if p[0] == text:
            return p[1]
    assert_true(False, "no entry for '" + text + "' in:" + pairs_text(pairs))
    return String()


def keys_of(pairs: List[Tuple[String, String]]) -> List[String]:
    var out = List[String]()
    for p in pairs:
        out.append(p[0])
    return out^


def explained(spec: Spec, id: String, env: Env, mut host: Mock) raises -> List[Tuple[String, String]]:
    var j = judge_clause(spec, id, env, host)
    assert_true(j.is_false(), id + " should be false: " + j.describe(spec))
    return explain(spec, clause_pos(spec, id), env, host)


def test_judgments() raises:
    var spec = spec_of("fn f(x: i64) -> i64\n  ensures t: result == x\n  ensures bad: result // 0 == x\n")
    var host = Mock()
    var env = Env(one(Value.int(2)))
    env.set_result(Value.int(2))
    var t = judge_clause(spec, "f.t", env, host)
    assert_true(t.is_true() and not t.is_false() and not t.is_error() and not t.is_skip())
    assert_equal(t.describe(spec), "true")
    env.set_result(Value.int(3))
    var f = judge_clause(spec, "f.t", env, host)
    assert_true(f.is_false())
    assert_equal(f.describe(spec), "false")
    var e = judge_clause(spec, "f.bad", env, host)
    assert_true(e.is_error())
    has(e.message, "division by zero")
    assert_true(e.node > 0)
    assert_true(spec.ast.source_text(e.node) == "result // 0")
    has(e.describe(spec), "(at t.spec:4:16: result // 0)")


def test_a_clause_that_is_not_a_bool_is_an_error() raises:
    var spec = spec_of("model M\n  observe flag: bool\nfn f(m: M)\n  ensures e: m.flag\n")
    var host = Mock()
    host.on_observe(0, 0, Value.int(1))
    var j = judge_clause(spec, "f.e", Env(one(Value.handle(1, "M"))), host)
    assert_true(j.is_error())
    has(j.message, "must evaluate to a bool, but it is 1")
    host.on_observe(0, 0, Value.bool(True))
    assert_true(judge_clause(spec, "f.e", Env(one(Value.handle(1, "M"))), host).is_true())


def test_a_missing_value_is_an_error_not_a_crash() raises:
    var spec = spec_of("fn f(x: i64) -> i64\n  ensures t: result == x\n")
    var host = Mock()
    var j = judge_clause(spec, "f.t", Env(one(Value.int(2))), host)
    assert_true(j.is_error())
    has(j.message, "no value for the result")


def test_raises_and_may_raise_judge_their_condition() raises:
    var spec = spec_of("error E\nfn f(x: i64) -> i64\n  raises E when x < 0\n  raises always: E when 1 // 0 == 0\n  may_raise F: E\n  may_raise G: E when x > 100\n")
    var host = Mock()
    var env = Env(one(Value.int(-1)))
    assert_true(judge(spec, 0, env, host).is_true())
    assert_true(judge_clause(spec, "f.always", env, host).is_error())
    assert_true(judge_clause(spec, "f.F", env, host).is_true())
    assert_true(judge_clause(spec, "f.G", env, host).is_false())
    assert_true(judge(spec, 0, Env(one(Value.int(1))), host).is_false())


def test_clauses_without_a_condition_are_errors() raises:
    var spec = spec_of("model M\n  observe n: i64\nfn f(m: M) -> i64\n  modifies m\n  impl_defined nan_payload\n  ensures t: true\n")
    var host = Mock()
    var env = Env(one(Value.handle(1, "M")))
    assert_true(judge(spec, 0, env, host).is_error())
    assert_true(judge(spec, 1, env, host).is_error())
    assert_true(judge(spec, 2, env, host).is_true())


def test_sorting_explanations() raises:
    var spec = example("sorting")
    var host = Mock()
    var env = Env(one(ints(1, 2, 3)))
    env.set_result(ints(3, 1, 2))
    var got = explained(spec, "sort.ordered", env, host)
    assert_equal(len(got), 2)
    assert_equal(lookup(got, "result"), "[3, 1, 2]")
    assert_equal(lookup(got, "is_sorted(result)"), "false")
    var env2 = Env(one(ints(1, 2, 2)))
    env2.set_result(ints(1, 2))
    var got2 = explained(spec, "sort.permutation", env2, host)
    assert_equal(lookup(got2, "result"), "[1, 2]")
    assert_equal(lookup(got2, "xs"), "[1, 2, 2]")
    assert_equal(lookup(got2, "is_permutation(result, xs)"), "false")
    assert_equal(len(got2), 3)


def test_cos_accuracy_explained() raises:
    var spec = example("libm")
    var host = Mock()
    var good = f64v(0.5403023058681398)
    var bad = Value.float(F64, good.float_bits() + 3)
    var env = Env(one(f64v(1.0)))
    env.set_result(bad.copy())
    var got = explained(spec, "cos.accurate", env, host)
    var keys = keys_of(got)
    assert_equal(len(keys), 3)
    assert_equal(keys[0], "result")
    assert_equal(keys[1], "cr.cos(x)")
    assert_equal(keys[2], "qe(result, cr.cos(x))")
    assert_equal(lookup(got, "result"), format_value(bad))
    assert_equal(lookup(got, "cr.cos(x)"), format_value(good))
    assert_equal(lookup(got, "qe(result, cr.cos(x))"), "3")
    var nan_env = Env(one(f64v(1.0)))
    nan_env.set_result(nan64())
    assert_equal(lookup(explained(spec, "cos.accurate", nan_env, host), "qe(result, cr.cos(x))"), "1nan")
    var inf_env = Env(one(inf64()))
    inf_env.set_result(f64v(0.5))
    var got_inf = explained(spec, "cos.accurate", inf_env, host)
    assert_equal(lookup(got_inf, "qe(result, cr.cos(x))"), "1nan")


def test_conjunctions_pick_the_first_false_part() raises:
    var spec = example("libm")
    var host = Mock()
    var env = Env(one(f64v(0.5)))
    env.set_result(f64v(1.5))
    var got = explained(spec, "cos.bounded", env, host)
    assert_equal(len(got), 1)
    assert_equal(lookup(got, "result"), format_value(f64v(1.5)))


def test_negation_and_predicates() raises:
    var spec = spec_of("fn cos(x: f64) -> f64\n  ensures nonfinite: not is_finite(x) implies is_nan(result)\n")
    var host = Mock()
    var env = Env(one(inf64()))
    env.set_result(f64v(0.5))
    var got = explained(spec, "cos.nonfinite", env, host)
    assert_equal(len(got), 2)
    assert_equal(lookup(got, "result"), format_value(f64v(0.5)))
    assert_equal(lookup(got, "is_nan(result)"), "false")


def test_a_relates_clause_shows_the_planned_call() raises:
    var spec = example("libm")
    var host = Mock()
    host.on_call(spec.fn_named("cos").value(), f64v(0.25))
    var env = Env(one(f64v(1.0)))
    env.set_result(f64v(0.5))
    var got = explained(spec, "cos.even", env, host)
    assert_equal(lookup(got, "cos(-x)"), format_value(f64v(0.25)))
    assert_equal(lookup(got, "result"), format_value(f64v(0.5)))
    assert_equal(lookup(got, "same(cos(-x), result)"), "false")


def test_a_quantifier_shows_the_failing_element() raises:
    var spec = spec_of("fn f(xs: list<list<i64>>) -> bool\n  ensures e: all(r in xs: len(r) == 2)\n")
    var host = Mock()
    var env = Env(one(Value.list(two(ints(1, 2), ints(3)))))
    env.set_result(Value.bool(True))
    var got = explained(spec, "f.e", env, host)
    assert_equal(lookup(got, "r"), "[3]")
    assert_equal(lookup(got, "len(r)"), "1")


def test_let_values_are_shown() raises:
    var spec = spec_of("fn f(x: i64) -> i64\n  ensures e: let y = x + 1 in y == result\n")
    var host = Mock()
    var env = Env(one(Value.int(1)))
    env.set_result(Value.int(5))
    var got = explained(spec, "f.e", env, host)
    assert_equal(lookup(got, "y"), "2")
    assert_equal(lookup(got, "result"), "5")


def test_old_shows_the_value_before_the_call() raises:
    var spec = spec_of("model C\n  observe items: list<i64>\nfn pop(c: C) -> i64\n  modifies c\n  ensures value: result == old(c.items)[len(old(c.items)) - 1]\n")
    var host = Mock()
    host.on_observe(0, 0, ints(5, 6, 7))
    var env = Env(one(Value.handle(1, "C")))
    snapshot_olds(spec, [clause_pos(spec, "pop.value")], env, host)
    env.set_result(Value.int(5))
    var got = explained(spec, "pop.value", env, host)
    assert_equal(lookup(got, "result"), "5")
    assert_equal(lookup(got, "old(c.items)"), "[5, 6, 7]")
    assert_equal(lookup(got, "len(old(c.items)) - 1"), "2")
    assert_equal(lookup(got, "old(c.items)[len(old(c.items)) - 1]"), "7")


def test_errors_inside_explain_are_summarized() raises:
    var spec = spec_of("fn f(xs: list<i64>) -> i64\n  ensures e: xs[result] > 0\n  ensures g: result > 0 and xs[5] > 0 or false\n")
    var host = Mock()
    var env = Env(one(ints(1)))
    env.set_result(Value.int(3))
    var got = explain(spec, clause_pos(spec, "f.e"), env, host)
    assert_equal(got[0][0], "xs[result] > 0")
    assert_true(got[0][1].startswith("error: index 3 is out of range"))
    var env2 = Env(one(ints(1)))
    env2.set_result(Value.int(1))
    var got2 = explain(spec, clause_pos(spec, "f.g"), env2, host)
    assert_equal(len(got2), 1)
    assert_equal(got2[0][0], "result > 0 and xs[5] > 0 or false")
    assert_true(got2[0][1].startswith("error: index 5 is out of range"))
    assert_true(got2[0][1].endswith("(at t.spec:4:29: xs[5])"))


def test_explain_never_raises() raises:
    var spec = spec_of("model M\n  observe items: list<i64>\nfn f(m: M)\n  ensures e: is_sorted(m.items)\n")
    var host = Mock()
    var got = explain(spec, clause_pos(spec, "f.e"), Env(), host)
    assert_true(len(got) > 0)
    assert_true(got[len(got) - 1][1].startswith("error"))


def test_explaining_true_and_literal_clauses() raises:
    var spec = example("sorting")
    var host = Mock()
    var env = Env()
    env.set_result(ints(1, 2))
    var got = explain(spec, clause_pos(spec, "sort.ordered"), env, host)
    assert_equal(len(got), 2)
    assert_equal(lookup(got, "result"), "[1, 2]")
    assert_equal(lookup(got, "is_sorted(result)"), "true")
    var lit = spec_of("fn f(a: bool) -> i64\n  ensures e: false\n  ensures g: a\n  ensures h: not (a and result > 1)\n")
    var e = explain(lit, clause_pos(lit, "f.e"), Env(), host)
    assert_equal(len(e), 1)
    assert_equal(e[0][0], "false")
    var g = explain(lit, clause_pos(lit, "f.g"), Env(one(Value.bool(False))), host)
    assert_equal(g[0][0], "a")
    assert_equal(g[0][1], "false")
    var env3 = Env(one(Value.bool(True)))
    env3.set_result(Value.int(2))
    var h = explain(lit, clause_pos(lit, "f.h"), env3, host)
    assert_equal(len(h), 2)
    assert_equal(h[0][0], "a")
    assert_equal(h[1][0], "result")


def test_explain_limits_and_truncates() raises:
    var spec = spec_of("fn f(xs: list<i64>) -> list<i64>\n  ensures e: result == xs\n")
    var host = Mock()
    var items = List[Value]()
    for i in range(1000):
        items.append(Value.int(i))
    var env = Env(one(Value.list(items^)))
    env.set_result(Value.list(List[Value]()))
    var got = explain(spec, clause_pos(spec, "f.e"), env, host)
    assert_equal(lookup(got, "result"), "[]")
    var shown = lookup(got, "xs")
    assert_true(shown.byte_length() <= 300 and shown.endswith("..."))
    var many = spec_of("fn f(a: i64, b: i64, c: i64, d: i64) -> i64\n  ensures e: a == b or b == c or c == d or d == a\n")
    var args = List[Value]()
    for i in range(4):
        args.append(Value.int(i))
    var env2 = Env(args^)
    env2.set_result(Value.int(0))
    assert_equal(len(explain(many, clause_pos(many, "f.e"), env2, host, 3)), 3)
    assert_equal(len(explain(many, clause_pos(many, "f.e"), env2, host)), 4)


def test_implies_with_a_failing_antecedent_is_explained() raises:
    var spec = spec_of("fn f(o: option<i64>) -> i64\n  ensures e: not (unwrap(o) > 0 implies result > 0)\n")
    var host = Mock()
    var env = Env(one(Value.none()))
    env.set_result(Value.int(1))
    var got = explain(spec, clause_pos(spec, "f.e"), env, host)
    assert_true(got[0][1].startswith("error: unwrap"), got[0][1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
