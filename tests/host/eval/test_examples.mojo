"""The clauses of the example specs, judged on inputs and results from real behaviour."""

from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite

from check.checker import check_source
from spec.spec import Spec
from eval.api import explain, snapshot_olds
from eval_testkit import *
from value.float_formats import F32
from spec.ast import Op
from value.value import Value


def example(name: String) raises -> Spec:
    var path = "examples/" + name + "/" + name + ".spec"
    return check_source(Path(path).read_text(), path)


def clause_ids(spec: Spec, decl: String, *kinds: Op) -> List[Int]:
    """Positions of the clauses of declaration `decl` of the given kinds."""
    var out = List[Int]()
    for i in range(len(spec.clauses)):
        ref c = spec.clauses[i]
        if not (c.id.startswith(decl + ".") or c.id.startswith(decl + "#")):
            continue
        for k in kinds:
            if c.kind == k:
                out.append(i)
    return out^


def all_hold(spec: Spec, clauses: List[Int], env: Env, mut host: Mock) raises:
    for c in clauses:
        var j = judge(spec, c, env, host)
        assert_true(j.is_true(), spec.clauses[c].id + ": " + j.describe(spec))


def cr_value(name: String, x: Value) raises -> Value:
    return value_of("x: f64", name + "(x)", one(x.copy()))


def test_libm_cos_holds_for_correctly_rounded_results() raises:
    var spec = example("libm")
    var host = Mock()
    var cos = spec.fn_named("cos").value()
    var clauses = clause_ids(spec, "cos", Op.ENSURES, Op.RELATES)
    assert_equal(len(clauses), 3)
    var inputs = List[Value]()
    for x in [0.0, -0.0, 1.0, -1.0, 0.5, 1e-300, 5e-324, 1e-9, 3.0, 1e5, 1048575.5, 1e10, -1e22, 1.7976931348623157e308]:
        inputs.append(f64v(x))
    inputs.append(inf64())
    inputs.append(inf64(True))
    inputs.append(nan64())
    for x in inputs:
        var result = cr_value("cr.cos", x)
        host.on_call(cos, result.copy())
        var env = Env(one(x.copy()))
        env.set_result(result^)
        all_hold(spec, clauses, env, host)


def test_libm_cos_fails_when_off_by_two_steps() raises:
    var spec = example("libm")
    var host = Mock()
    var good = cr_value("cr.cos", f64v(1.0))
    var bad = Value.float(F64, good.float_bits() + 2)
    var env = Env(one(f64v(1.0)))
    env.set_result(bad^)
    assert_true(judge_clause(spec, "cos.accurate", env, host).is_false())
    # NaN for a finite input is one NaN error; NaN for an infinity is right.
    env.set_result(nan64())
    assert_true(judge_clause(spec, "cos.accurate", env, host).is_false())
    var inf_env = Env(one(inf64()))
    inf_env.set_result(nan64())
    assert_true(judge_clause(spec, "cos.accurate", inf_env, host).is_true())
    inf_env.set_result(f64v(1.0))
    assert_true(judge_clause(spec, "cos.accurate", inf_env, host).is_false())
    assert_true(judge_clause(spec, "cos.bounded", inf_env, host).is_true())
    env.set_result(f64v(1.5))
    assert_true(judge_clause(spec, "cos.bounded", env, host).is_false())


def test_libm_cos32_with_correctly_rounded_f32_results() raises:
    var spec = example("libm")
    var host = Mock()
    var x = f32v(1.0)
    var result = value_of("x: f32", "cr.cos(x)", one(x.copy()))
    host.on_call(spec.fn_named("cos32").value(), result.copy())
    var env = Env(one(x^))
    env.set_result(result^)
    all_hold(spec, clause_ids(spec, "cos32", Op.ENSURES, Op.RELATES), env, host)


def test_libm_sqrt() raises:
    var spec = example("libm")
    var host = Mock()
    var sqrt = spec.fn_named("sqrt").value()
    var clauses = clause_ids(spec, "sqrt", Op.ENSURES, Op.RELATES)
    for x in [0.0, -0.0, 1.0, 2.0, 0.25, 5e-324, 1e300, 1.7976931348623157e308]:
        var result = value_of("x: f64", "cr.sqrt(x)", one(f64v(x)))
        host.on_call(sqrt, result.copy())
        var env = Env(one(f64v(x)))
        env.set_result(result^)
        all_hold(spec, clauses, env, host)
    # The freedom to raise applies to negative inputs only.
    var may = clause_ids(spec, "sqrt", Op.MAY_RAISE)
    assert_equal(len(may), 1)
    assert_true(judge(spec, may[0], Env(one(f64v(4.0))), host).is_false())
    assert_true(judge(spec, may[0], Env(one(f64v(-1.0))), host).is_true())
    assert_true(judge(spec, may[0], Env(one(nan64())), host).is_false())


def test_binary_pack_and_utf8() raises:
    var spec = example("binary")
    var host = Mock()
    var env = Env(one(Value.int(-2)))
    env.set_result(Value.bytes([0xFE, 0xFF, 0xFF, 0xFF]))
    host.on_call(spec.fn_named("unpack_i32").value(), Value.int(-2))
    all_hold(spec, clause_ids(spec, "pack_i32", Op.ENSURES, Op.RELATES), env, host)
    var raising = clause_ids(spec, "pack_i32", Op.RAISES)
    assert_equal(len(raising), 1)
    assert_true(judge(spec, raising[0], Env(one(Value.int(-2))), host).is_false())
    assert_true(judge(spec, raising[0], Env(one(big("2147483648"))), host).is_true())
    assert_true(judge(spec, raising[0], Env(one(Value.int(-2147483649))), host).is_true())
    # utf8_encode: the length is the sum of the code points' widths.
    var text = Value.string("aé€" + chr(0x1F600))
    var encoded = Value.bytes([0x61, 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80])
    host.on_call(spec.fn_named("utf8_decode").value(), text.copy())
    var env2 = Env(one(text.copy()))
    env2.set_result(encoded.copy())
    all_hold(spec, clause_ids(spec, "utf8_encode", Op.ENSURES, Op.RELATES), env2, host)
    env2.set_result(Value.bytes([0x61, 0xC3, 0xA9]))
    assert_true(judge_clause(spec, "utf8_encode.length", env2, host).is_false())
    assert_true(judge_clause(spec, "utf8_encode.valid", env2, host).is_true())
    env2.set_result(Value.bytes([0x61, 0xC3]))
    assert_true(judge_clause(spec, "utf8_encode.valid", env2, host).is_false())


def frame(rows: List[List[Value]]) -> Value:
    var out = List[Value]()
    for r in rows:
        out.append(Value.list(r.copy()))
    return Value.list(out^)


def cell(x: Float64) -> Value:
    return Value.some(f64v(x))


def test_frames_invariants_and_dropna() raises:
    var spec = example("frames")
    var host = Mock()
    var model = spec.model_named("Frame").value()
    var rows = frame([[cell(1.0), Value.none()], [cell(2.0), cell(3.0)]])
    var names = Value.list(two(Value.string("a"), Value.string("b")))
    host.on_observe(model, 0, names.copy())
    host.on_observe(model, 1, rows.copy())
    host.on_observe(model, 2, Value.int(2))
    var env = Env()
    env.set_self(Value.handle(1, "Frame"))
    for c in spec.models[model].clauses:
        assert_true(judge(spec, c, env, host).is_true(), spec.clauses[c].id)
    # A ragged row breaks `rectangular`, and the explanation names the row.
    var ragged = frame([[cell(1.0)], [cell(2.0), Value.none()]])
    host.on_observe(model, 1, ragged^)
    var rect = judge_clause(spec, "Frame.rectangular", env, host)
    assert_true(rect.is_false())
    var why = explain(spec, clause_pos(spec, "Frame.rectangular"), env, host)
    var found = False
    for p in why:
        if p[0] == "r":
            found = True
            assert_true(p[1].startswith("[some("))
    assert_true(found)
    # dropna with how = "any" keeps the rows without a missing cell; eq compares the
    # models' observers through the host.
    host.on_observe(model, 1, rows.copy(), 1)
    host.on_observe(model, 0, names.copy(), 1)
    host.on_observe(model, 2, Value.int(2), 1)
    var kept = frame([[cell(2.0), cell(3.0)]])
    host.on_observe(model, 1, kept.copy(), 2)
    host.on_observe(model, 0, names.copy(), 2)
    host.on_observe(model, 2, Value.int(1), 2)
    var denv = Env(two(Value.handle(1, "Frame"), Value.string("any")))
    denv.set_result(Value.handle(2, "Frame"))
    var dropna = clause_ids(spec, "dropna", Op.ENSURES)
    for c in dropna:
        assert_true(judge(spec, c, denv, host).is_true(), spec.clauses[c].id)
    host.on_observe(model, 1, rows.copy(), 2)
    assert_true(judge_clause(spec, "dropna.rows", denv, host).is_false())


def test_sorting_clauses() raises:
    var spec = example("sorting")
    var host = Mock()
    var xs = Value.list(two(
        Value.tuple(two(Value.int(2), Value.string("a"))),
        Value.tuple(two(Value.int(1), Value.string("b"))),
    ))
    var stable = Value.list(two(
        Value.tuple(two(Value.int(1), Value.string("b"))),
        Value.tuple(two(Value.int(2), Value.string("a"))),
    ))
    var env = Env(one(xs.copy()))
    env.set_result(stable^)
    all_hold(spec, clause_ids(spec, "sort_by_first", Op.ENSURES), env, host)
    var dup = Value.list(three_pairs())
    var env2 = Env(one(dup.copy()))
    # Equal keys must keep their input order.
    var swapped = List[Value]()
    swapped.append(dup.item(1))
    swapped.append(dup.item(0))
    swapped.append(dup.item(2))
    env2.set_result(Value.list(swapped^))
    assert_true(judge_clause(spec, "sort_by_first.permutation", env2, host).is_true())
    assert_true(judge_clause(spec, "sort_by_first.ordered", env2, host).is_true())
    assert_true(judge_clause(spec, "sort_by_first.stable", env2, host).is_false())


def three_pairs() -> List[Value]:
    var out = List[Value]()
    out.append(Value.tuple(two(Value.int(1), Value.string("a"))))
    out.append(Value.tuple(two(Value.int(1), Value.string("b"))))
    out.append(Value.tuple(two(Value.int(2), Value.string("c"))))
    return out^


def test_deque_append_with_old() raises:
    var spec = example("deque")
    var host = Mock()
    var h = Value.handle(1, "Deque")
    var model = spec.model_named("Deque").value()
    host.on_observe(model, 0, ints(1, 2, 3))
    host.on_observe(model, 1, Value.some(Value.int(3)))
    var env = Env(two(h.copy(), Value.int(4)))
    var clauses = clause_ids(spec, "Deque.append", Op.ENSURES)
    snapshot_olds(spec, clauses, env, host)
    # A bounded deque drops from the opposite end.
    host.on_observe(model, 0, ints(2, 3, 4))
    all_hold(spec, clauses, env, host)
    host.on_observe(model, 0, ints(1, 2, 4))
    var j = judge_clause(spec, "Deque.append.items", env, host)
    assert_true(j.is_false())
    var why = explain(spec, clause_pos(spec, "Deque.append.items"), env, host)
    assert_equal(why[0][0], "ys")
    assert_equal(why[0][1], "[1, 2, 3, 4]")
    var texts = List[String]()
    for p in why:
        texts.append(p[0])
    assert_true("self.items" in texts)


def test_deque_pop() raises:
    var spec = example("deque")
    var host = Mock()
    var model = spec.model_named("Deque").value()
    var h = Value.handle(1, "Deque")
    host.on_observe(model, 0, ints(5, 6, 7))
    host.on_observe(model, 1, Value.none())
    var env = Env(one(h.copy()))
    var clauses = clause_ids(spec, "Deque.pop", Op.ENSURES)
    snapshot_olds(spec, clauses, env, host)
    host.on_observe(model, 0, ints(5, 6))
    env.set_result(Value.int(7))
    all_hold(spec, clauses, env, host)
    env.set_result(Value.int(5))
    assert_true(judge_clause(spec, "Deque.pop.value", env, host).is_false())
    var raises = clause_ids(spec, "Deque.pop", Op.RAISES)
    assert_equal(len(raises), 1)
    assert_true(judge(spec, raises[0], env, host).is_false())
    host.on_observe(model, 0, ints())
    assert_true(judge(spec, raises[0], env, host).is_true())
    # With nothing to pop, old(...) of the last element is an error.
    var empty = Env(one(h.copy()))
    snapshot_olds(spec, clauses, empty, host)
    empty.set_result(Value.int(1))
    var e = judge_clause(spec, "Deque.pop.value", empty, host)
    assert_true(e.is_error())
    assert_true("index -1 is out of range" in e.message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
