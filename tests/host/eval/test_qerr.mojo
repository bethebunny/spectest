from std.testing import assert_equal, assert_true, TestSuite

from eval_testkit import *
from numeric.bigint import BigInt
from wire.value import Value


def is_(got: Value, want: Value) raises:
    assert_true(got == want, "got " + format_value(got) + ", wanted " + format_value(want))


def q(steps: Int, nans: Int) -> Value:
    return Value.qerr(BigInt(steps), BigInt(nans))


def yes(params: String, expr: String, var args: List[Value]) raises:
    is_(value_of(params, expr, args^), Value.bool(True))


def no(params: String, expr: String, var args: List[Value]) raises:
    is_(value_of(params, expr, args^), Value.bool(False))


def xy(a: Float64, b: Float64) -> List[Value]:
    return two(f64v(a), f64v(b))


def test_qe_values_and_parts() raises:
    is_(value_of("x: f64, y: f64", "qe(x, y)", xy(1.0, 1.0)), q(0, 0))
    is_(value_of("x: f64, y: f64", "qe(x, y)", two(f64v(1.0), f64v(1.0000000000000002))), q(1, 0))
    is_(value_of("x: f64, y: f64", "qe(x, y)", two(nan64(), f64v(1.0))), q(0, 1))
    is_(value_of("x: f64, y: f64", "qe(x, y)", two(nan64(), nan64())), q(0, 0))
    is_(value_of("x: f64, y: f64", "steps(qe(x, y))", two(f64v(1.0), f64v(1.0000000000000002))), Value.int(1))
    is_(value_of("x: f64, y: f64", "nans(qe(x, y))", two(nan64(), f64v(1.0))), Value.int(1))
    is_(value_of("x: f64, y: f64", "qe(x, y).steps", two(f64v(1.0), f64v(1.0000000000000002))), Value.int(1))
    is_(value_of("x: f64, y: f64", "qe(x, y).nans", two(nan64(), f64v(1.0))), Value.int(1))
    is_(value_of("x: f32, y: f32", "qe(x, y)", two(f32v(1.0), f32v(1.0000001))), q(1, 0))


def test_qerr_addition_is_componentwise() raises:
    var a = two(f64v(1.0), f64v(1.0000000000000002))
    is_(value_of("x: f64, y: f64", "qe(x, y) + qe(x, y)", a.copy()), q(2, 0))
    is_(value_of("x: f64, y: f64", "qe(x, y) + qe(x, x) + qe(y, y)", a.copy()), q(1, 0))
    is_(value_of("x: f64, y: f64", "qe(x, y) + qe(x, y) + qe(x, y)", a.copy()), q(3, 0))


def test_qerr_comparisons_are_componentwise() raises:
    var one_step = two(f64v(1.0), f64v(1.0000000000000002))
    var nan_error = two(nan64(), f64v(1.0))
    yes("x: f64, y: f64", "qe(x, y) <= 1", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) < 2", one_step.copy())
    no("x: f64, y: f64", "qe(x, y) < 1", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) == 1", one_step.copy())
    no("x: f64, y: f64", "qe(x, y) == 0", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) != 0", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) >= 1", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) > 0", one_step.copy())
    # A number c reads as c + 0*nan, so a NaN error is above any number.
    no("x: f64, y: f64", "qe(x, y) <= 100", nan_error.copy())
    no("x: f64, y: f64", "qe(x, y) < 100", nan_error.copy())
    no("x: f64, y: f64", "qe(x, y) == 0", nan_error.copy())
    yes("x: f64, y: f64", "qe(x, y) >= 0", nan_error.copy())
    yes("x: f64, y: f64", "qe(x, y) > 0", nan_error.copy())
    # Comparisons with a qerr on the left or the right, and with reals.
    yes("x: f64, y: f64", "1 >= qe(x, y)", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) <= 3 / 2", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) == qe(x, y)", one_step.copy())
    no("x: f64, y: f64", "qe(x, y) < qe(x, y)", one_step.copy())
    yes("x: f64, y: f64", "qe(x, y) <= qe(x, y) + qe(x, y)", one_step.copy())
    # The order is partial: neither is below the other.


def test_qerr_ordering_is_partial() raises:
    # (2 steps, 0 nans) against (0 steps, 1 nan): neither bounds the other.
    var spec = spec_of(fragment("a: f64, b: f64", "(qe(a, b) + qe(a, b)) <= qe(a, b)"))
    var host = Mock()
    var args = two(f64v(1.0), f64v(1.0000000000000002))
    is_(evaluate(spec, expr_node(spec), Env(args^), host), Value.bool(False))
    var spec2 = spec_of(fragment("a: f64, b: f64, c: f64", "qe(a, b) <= qe(a, c) or qe(a, c) <= qe(a, b)"))
    var args2 = List[Value]()
    args2.append(f64v(1.0))
    args2.append(f64v(1.0000000000000002))
    args2.append(nan64())
    is_(evaluate(spec2, expr_node(spec2), Env(args2^), host), Value.bool(False))


def test_sum_and_max_of_qerr() raises:
    var xs = Value.list(two(f64v(1.0), f64v(1.0000000000000002)))
    is_(value_of("xs: list<f64>", "sum(a in xs: qe(a, a))", one(xs.copy())), q(0, 0))
    is_(value_of("xs: list<f64>", "sum(a in xs: qe(a, xs[0]))", one(xs.copy())), q(1, 0))
    is_(value_of("xs: list<f64>", "max(a in xs: qe(a, xs[0]))", one(xs.copy())), q(1, 0))
    is_(value_of("xs: list<f64>", "sum(a in xs: qe(a, xs[0]) + qe(a, xs[0]))", one(xs.copy())), q(2, 0))
    # An empty qerr sum is the zero qerr.
    is_(value_of("xs: list<f64>", "sum(a in xs: qe(a, a))", one(Value.list(List[Value]()))), q(0, 0))


def test_qerr_max_is_componentwise() raises:
    var spec = spec_of(fragment("a: f64, b: f64, c: f64", "max(i in [0, 1]: if i == 0 then qe(a, b) else qe(a, c))"))
    var host = Mock()
    var args = List[Value]()
    args.append(f64v(1.0))
    args.append(f64v(1.0000000000000004))
    args.append(nan64())
    # (2 steps, 0 nans) and (0 steps, 1 nan): the componentwise maximum.
    is_(evaluate(spec, expr_node(spec), Env(args^), host), q(2, 1))


def test_sum_and_max_of_numbers() raises:
    is_(value_of("xs: list<f64>", "sum(x in xs: x)", one(Value.list(two(f64v(0.5), f64v(0.25))))), real_v(3, 4))
    is_(value_of("xs: list<f64>", "max(x in xs: x)", one(Value.list(two(f64v(0.5), f64v(0.25))))), real_v(1, 2))
    is_(value_of("xs: list<f64>", "max(x in xs: x)", one(Value.list(two(f64v(1.0), inf64())))), real_v(1, 0))
    is_(value_of("xs: list<i8>", "max(x in xs: x)", one(ints(-3, -1, -2))), Value.int(-1))
    is_(value_of("xs: list<i8>", "sum(x in xs: x * 100)", one(ints(1, 2))), Value.int(300))


def test_a_qerr_sum_in_a_clause() raises:
    var spec = spec_of("fn f(x: f64) -> f64\n  ensures e: sum(i in [1, 2]: qe(x, result)) <= 2\n")
    var host = Mock()
    var env = Env(one(f64v(1.0)))
    env.set_result(f64v(1.0000000000000002))
    assert_true(judge_clause(spec, "f.e", env, host).is_true())
    env.set_result(f64v(1.0000000000000004))
    assert_true(judge_clause(spec, "f.e", env, host).is_false())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
