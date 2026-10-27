from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns

from check.checker import check_source
from eval.api import judge
from eval.env import Env
from eval.host import EvalHost
from eval_testkit import f64v
from wire.value import Value


struct Lean(EvalHost):
    """A host that answers the one planned call of the benchmark and nothing else."""

    var answer: Value

    def __init__(out self, var answer: Value):
        self.answer = answer^

    def observe(mut self, obj: Value, model: Int, observer: Int, args: List[Value]) raises -> Value:
        raise Error("no observers")

    def call_fn(mut self, fn_pos: Int, args: List[Value]) raises -> Value:
        return self.answer.copy()

    def constant(mut self, const_pos: Int) raises -> Value:
        raise Error("no constants")

    def fresh(mut self, obj: Value) raises -> Bool:
        return True

    def same_object(mut self, a: Value, b: Value) raises -> Bool:
        return True

    def shares_memory(mut self, a: Value, b: Value) raises -> Bool:
        return False

    def call_extern(mut self, name: String, args: List[Value]) raises -> Value:
        raise Error("no externs")


def test_judging_the_clauses_of_cos_takes_microseconds() raises:
    var path = "examples/libm/libm.spec"
    var spec = check_source(Path(path).read_text(), path)
    var cos = spec.fn_named("cos").value()
    var clauses = List[Int]()
    for c in spec.fns[cos].clauses:
        if spec.clauses[c].kind == 25 or spec.clauses[c].kind == 29:
            clauses.append(c)
    assert_equal(len(clauses), 3)
    # cos(1.0) correctly rounded, and the planned call cos(-1.0) the same.
    var x = f64v(1.0)
    var result = f64v(0.5403023058681398)
    var host = Lean(result.copy())
    var rounds = 2000
    var best = Int.MAX
    for _ in range(5):
        var start = perf_counter_ns()
        for _ in range(rounds):
            var params = List[Value]()
            params.append(x.copy())
            var env = Env(params^)
            env.set_result(result.copy())
            for c in clauses:
                var j = judge(spec, c, env, host)
                if not j.is_true():
                    raise Error("clause " + spec.clauses[c].id + ": " + j.describe(spec))
        var per_input = Int(perf_counter_ns() - start) // rounds
        if per_input < best:
            best = per_input
    print("judging the 3 clauses of cos on one input:", Float64(best) / 1000.0, "us")
    # The evaluator's share of the 50 us budget per example is 20 us. The bound is ten
    # times that, so a busy machine doesn't fail it; the print is the measurement.
    assert_true(best < 200_000, "judging took " + String(best) + " ns")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
