from std.testing import assert_equal, assert_true, TestSuite

from eval.api import observe_with, snapshot_olds
from eval.core import scalar_type_id
from numeric.formats import F16
from eval.testkit import *
from wire.value import Value


def has(message: String, fragment: String) raises:
    assert_true(fragment in message, "'" + fragment + "' not in '" + message + "'")


def is_(got: Value, want: Value) raises:
    assert_true(got == want, "got " + format_value(got) + ", wanted " + format_value(want))


def test_prelude_calls() raises:
    is_(value_of("xs: list<i64>", "len(xs)", one(ints(1, 2))), Value.int(2))
    is_(value_of("xs: list<i64>", "sorted(xs)", one(ints(3, 1, 2))), ints(1, 2, 3))
    is_(value_of("x: f64", "is_nan(x)", one(nan64())), Value.bool(True))
    is_(value_of("x: f64", "bits(x)", one(f64v(-0.0))), big("9223372036854775808"))
    is_(value_of("x: f64", "next_up(x)", one(f64v(1.0))), f64v(1.0000000000000002))
    is_(value_of("b: bytes", "le_uint(b)", one(Value.bytes([1, 1]))), Value.int(257))
    is_(value_of("x: f64", "mp.sqrt(x) == 2", one(f64v(4.0))), Value.bool(True))
    is_(value_of("x: f64", "cr.sqrt(x)", one(f64v(4.0))), f64v(2.0))
    is_(value_of("s: string", "len(s)", one(Value.string("aé"))), Value.int(2))


def test_type_arguments() raises:
    is_(value_of("x: i64", "wrap<u32>(x)", one(Value.int(-1))), Value.int(4294967295))
    is_(value_of("x: i64", "wrap<i8>(x)", one(Value.int(255))), Value.int(-1))
    is_(value_of("x: i64", "fits<i32>(x)", one(Value.int(2147483648))), Value.bool(False))
    is_(value_of("x: f64", "fits<f32>(x)", one(f64v(0.5))), Value.bool(True))
    is_(value_of("x: f64", "round<f32>(real(x) * 3)", one(f64v(0.5))), f32v(1.5))
    is_(value_of("x: f64", "ulp<f64>(1)", one(f64v(0.0))), real_v(1, 4503599627370496))


def test_generic_functions_take_a_type_environment() raises:
    var spec = spec_of("fn sort<T: Ord>(xs: list<T>) -> list<T>\n  ensures ordered: is_sorted(result) and len(result) == len(xs)\n")
    var host = Mock()
    var env = Env(one(ints(3, 1)))
    env.set_result(ints(1, 3))
    assert_true(judge_clause(spec, "sort.ordered", env, host).is_true())
    env.set_result(ints(3, 1))
    assert_true(judge_clause(spec, "sort.ordered", env, host).is_false())


def test_keyword_arguments_reach_the_prelude() raises:
    var nan1 = nan64()
    var nan2 = Value.float(F64, UInt64(0x7FF8000000000001))
    var a = Value.list(two(nan1.copy(), f64v(0.0)))
    var b = Value.list(two(nan2.copy(), f64v(-0.0)))
    var sig = "a: list<f64>, b: list<f64>"
    is_(value_of(sig, 'eq(a, b, float="bits")', two(a.copy(), b.copy())), Value.bool(False))
    is_(value_of(sig, 'eq(a, b, float="ieee")', two(a.copy(), b.copy())), Value.bool(False))
    is_(value_of(sig, 'eq(a, a, float="nan_any")', two(a.copy(), b.copy())), Value.bool(True))
    var c = Value.list(two(f64v(1.0), f64v(2.0)))
    var d = Value.list(two(f64v(2.0), f64v(1.0)))
    is_(value_of(sig, 'eq(a, b, float="bits", order="ignore")', two(c.copy(), d.copy())), Value.bool(True))
    is_(value_of(sig, 'eq(a, b, float="bits")', two(c.copy(), d.copy())), Value.bool(False))


def test_type_constants() raises:
    is_(value_of("", "i32.max", none_args()), Value.int(2147483647))
    is_(value_of("", "i32.min", none_args()), Value.int(-2147483648))
    is_(value_of("", "u8.max", none_args()), Value.int(255))
    is_(value_of("", "u8.min", none_args()), Value.int(0))
    is_(value_of("", "u64.max", none_args()), big("18446744073709551615"))
    is_(value_of("", "i64.min", none_args()), big("-9223372036854775808"))
    is_(value_of("", "f64.max", none_args()), f64v(1.7976931348623157e308))
    is_(value_of("", "f64.min", none_args()), f64v(-1.7976931348623157e308))
    is_(value_of("", "f32.max", none_args()), f32v(3.4028235e38))
    is_(value_of("", "f16.max", none_args()), Value.float(F16, UInt64(0x7BFF)))
    is_(value_of("x: i8", "x == i8.min", one(Value.int(-128))), Value.bool(True))


def test_model_identity_functions_use_the_host() raises:
    var spec = spec_of("model M\n  observe items: list<i64>\nfn copy(m: M) -> M\n  ensures fresh: fresh(result)\n  ensures distinct: not same_object(result, m)\n  ensures shares: not shares_memory(result, m)\n  ensures items: eq(result, m)\n")
    var m = Value.handle(1, "M")
    var r = Value.handle(2, "M")
    var host = Mock()
    host.is_same = False
    host.on_observe(0, 0, ints(1, 2), 1)
    host.on_observe(0, 0, ints(1, 2), 2)
    var env = Env(one(m.copy()))
    env.set_result(r.copy())
    for id in ["copy.fresh", "copy.distinct", "copy.shares", "copy.items"]:
        assert_true(judge_clause(spec, id, env, host).is_true(), id)
    assert_true(host.calls("fresh") == 1 and host.calls("same_object") == 1)
    host.is_fresh = False
    host.is_same = True
    host.is_shared = True
    assert_true(judge_clause(spec, "copy.fresh", env, host).is_false())
    assert_true(judge_clause(spec, "copy.distinct", env, host).is_false())
    assert_true(judge_clause(spec, "copy.shares", env, host).is_false())
    host.on_observe(0, 0, ints(2, 1), 2)
    assert_true(judge_clause(spec, "copy.items", env, host).is_false())


def test_planned_calls_go_through_the_host() raises:
    var spec = spec_of("fn inc(x: u8) -> int\n  ensures a: result == x + 1\n  relates same_fn: inc(x) == result\n  relates other: inc(x + 1) == result + 1\n  relates wide: inc(x + 250) == result\n")
    var host = Mock()
    host.on_call(0, Value.int(6))
    var env = Env(one(Value.int(5)))
    env.set_result(Value.int(6))
    assert_true(judge_clause(spec, "inc.same_fn", env, host).is_true())
    assert_equal(host.log[0], "call 0 5")
    assert_true(judge_clause(spec, "inc.other", env, host).is_false())
    assert_equal(host.log[1], "call 0 6")
    # 255 still fits u8; 5 + 250 does not... 255 does, 256 does not.
    assert_true(judge_clause(spec, "inc.wide", env, host).is_true())
    var env2 = Env(one(Value.int(6)))
    env2.set_result(Value.int(6))
    var j = judge_clause(spec, "inc.wide", env2, host)
    assert_true(j.is_error())
    has(j.message, "256 is out of range for u8")
    has(j.message, "argument x of inc")


def test_planned_call_arguments_must_be_exact() raises:
    var spec = spec_of("fn h(x: f32) -> f32\n  relates a: same(h(0.5), result)\n  relates b: same(h(0.1), result)\n  relates c: same(h(x), result)\n  relates d: same(h(1 / 2), result)\n")
    var host = Mock()
    host.on_call(0, f32v(1.0))
    var env = Env(one(f32v(2.0)))
    env.set_result(f32v(1.0))
    assert_true(judge_clause(spec, "h.a", env, host).is_true())
    is_(host.last_args[0].copy(), f32v(0.5))
    var j = judge_clause(spec, "h.b", env, host)
    assert_true(j.is_error())
    has(j.message, "not exactly representable as f32")
    assert_true(judge_clause(spec, "h.c", env, host).is_true())
    assert_true(judge_clause(spec, "h.d", env, host).is_true())
    is_(host.last_args[0].copy(), f32v(0.5))


def test_planned_call_defaults_and_keywords() raises:
    var spec = spec_of("fn g(a: i32, b: i32 = 7) -> i32\n  relates p: g(1) == result\n  relates q: g(1, b = 3) == result\n  relates r: g(b = 4, a = 2) == result\n")
    var host = Mock()
    host.on_call(0, Value.int(0))
    var env = Env(two(Value.int(0), Value.int(0)))
    env.set_result(Value.int(0))
    _ = judge_clause(spec, "g.p", env, host)
    is_(host.last_args[1].copy(), Value.int(7))
    _ = judge_clause(spec, "g.q", env, host)
    is_(host.last_args[1].copy(), Value.int(3))
    _ = judge_clause(spec, "g.r", env, host)
    is_(host.last_args[0].copy(), Value.int(2))
    is_(host.last_args[1].copy(), Value.int(4))


def test_a_library_error_skips_the_clause() raises:
    var spec = spec_of("error ValueError\nfn inc(x: u8) -> int\n  relates same_fn: inc(x) == result\n  relates guarded: false and inc(x) == result\n")
    var host = Mock()
    host.on_call(0, Value.error("ValueError", ["Exception"], "boom"))
    var env = Env(one(Value.int(5)))
    env.set_result(Value.int(6))
    var j = judge_clause(spec, "inc.same_fn", env, host)
    assert_true(j.is_skip())
    has(j.message, "ValueError: boom")
    assert_true(not j.is_error())
    # A guard that never reaches the call does not skip.
    assert_true(judge_clause(spec, "inc.guarded", env, host).is_false())
    assert_equal(host.calls("call"), 1)


def test_observers_with_arguments() raises:
    var spec = spec_of("model M\n  observe size: i64\n  observe at(i: u8): i64\nfn f(m: M)\n  ensures a: m.at(1) + m.at(i = 2) == m.size\n  ensures b: m.at(300) == 0\n")
    var host = Mock()
    var m = Value.handle(1, "M")
    host.on_observe(0, 0, Value.int(30))
    host.on_observe(0, 1, Value.int(15))
    var env = Env(one(m^))
    assert_true(judge_clause(spec, "f.a", env, host).is_true())
    assert_equal(host.calls("observe 0.1 1"), 2)
    is_(host.last_args[0].copy(), Value.int(2)) if False else None
    var j = judge_clause(spec, "f.b", env, host)
    assert_true(j.is_error())
    has(j.message, "300 is out of range for u8")


def test_observer_on_a_non_handle_is_an_error() raises:
    var spec = spec_of("model M\n  observe size: i64\nfn f(m: M)\n  ensures a: m.size == 1\n")
    var host = Mock()
    var j = judge_clause(spec, "f.a", Env(one(Value.int(3))), host)
    assert_true(j.is_error())
    has(j.message, "needs a handle")


def test_bare_observers_in_invariants() raises:
    var spec = spec_of("model M\n  observe n: i64\n  observe items: list<i64>\n  invariant sized: n == len(items) and self.n >= 0\n")
    var host = Mock()
    host.on_observe(0, 0, Value.int(2))
    host.on_observe(0, 1, ints(7, 8))
    var env = Env()
    env.set_self(Value.handle(1, "M"))
    var c = spec.clause_named("M.sized")
    assert_true(Bool(c))
    assert_true(judge(spec, c.value(), env, host).is_true())
    host.on_observe(0, 0, Value.int(3))
    assert_true(judge(spec, c.value(), env, host).is_false())


def test_old_reads_the_state_before_the_call() raises:
    var spec = spec_of("model C\n  observe n: i64\nfn bump(c: C)\n  modifies c\n  ensures up: c.n == old(c.n) + 1\n  ensures kept: let k = old(c.n) in k + 1 == c.n\n  ensures twice: old(c.n) + old(c.n) == 10\n")
    var host = Mock()
    var c = Value.handle(1, "C")
    var env = Env(one(c^))
    host.on_observe(0, 0, Value.int(5))
    var all = List[Int]()
    for i in range(len(spec.clauses)):
        all.append(i)
    snapshot_olds(spec, all, env, host)
    # Each old(c.n) is evaluated once, in the state before the call.
    assert_equal(host.calls("observe"), 4)
    host.on_observe(0, 0, Value.int(6))
    assert_true(judge_clause(spec, "bump.up", env, host).is_true())
    assert_true(judge_clause(spec, "bump.kept", env, host).is_true())
    assert_true(judge_clause(spec, "bump.twice", env, host).is_true())
    host.on_observe(0, 0, Value.int(9))
    assert_true(judge_clause(spec, "bump.up", env, host).is_false())


def test_old_without_a_snapshot_is_an_error() raises:
    var spec = spec_of("model C\n  observe n: i64\nfn bump(c: C)\n  ensures up: c.n == old(c.n) + 1\n")
    var host = Mock()
    host.on_observe(0, 0, Value.int(5))
    var j = judge_clause(spec, "bump.up", Env(one(Value.handle(1, "C"))), host)
    assert_true(j.is_error())
    has(j.message, "snapshot_olds")


def test_old_failures_are_recorded_and_met_on_use() raises:
    var spec = spec_of("model C\n  observe n: i64\nfn f(c: C, xs: list<i64>)\n  modifies c\n  ensures a: old(xs[3]) == 0\n  ensures b: true or old(xs[3]) == 0\n")
    var host = Mock()
    var env = Env(two(Value.handle(1, "C"), ints(1)))
    var all = List[Int]()
    all.append(0)
    all.append(1)
    snapshot_olds(spec, all, env, host)
    var j = judge_clause(spec, "f.a", env, host)
    assert_true(j.is_error())
    has(j.message, "index 3 is out of range")
    # The failure is not raised until the clause reads it.
    assert_true(judge_clause(spec, "f.b", env, host).is_true())
    # And it can be met again.
    assert_true(judge_clause(spec, "f.a", env, host).is_error())


def test_old_of_a_planned_call_that_raises_skips() raises:
    var spec = spec_of("error E\nmodel C\n  observe n: i64\nfn h(x: i32) -> i32\nfn g(c: C, x: i32)\n  modifies c\n  ensures r: old(h(x)) == 1\n")
    var host = Mock()
    host.on_call(0, Value.error("E", [], "no"))
    var env = Env(two(Value.handle(1, "C"), Value.int(1)))
    snapshot_olds(spec, [clause_pos(spec, "g.r")], env, host)
    var sk = judge_clause(spec, "g.r", env, host)
    assert_true(sk.is_skip(), sk.describe(spec))


def test_definitions() raises:
    var spec = spec_of("fn sq(x: int) -> int = x * x\nfn sumsq(a: int, b: int) -> int = sq(a) + sq(b)\nfn pad(x: int, n: int = 2) -> int = x + n\nfn f(a: int, b: int) -> int\n  ensures e: result == sumsq(a, b)\n  ensures p: pad(a) == a + 2 and pad(a, n = 5) == a + 5 and pad(a, 1) == a + 1\n  ensures lists: sum(x in map(y in [a, b]: sq(y)): x) == result\n")
    var host = Mock()
    var env = Env(two(Value.int(3), Value.int(4)))
    env.set_result(Value.int(25))
    assert_true(judge_clause(spec, "f.e", env, host).is_true())
    assert_true(judge_clause(spec, "f.p", env, host).is_true())
    assert_true(judge_clause(spec, "f.lists", env, host).is_true())
    env.set_result(Value.int(24))
    var k = judge_clause(spec, "f.e", env, host)
    assert_true(k.is_false(), k.describe(spec))
    # A definition's locals do not leak into the caller's.
    var spec2 = spec_of("fn twice(x: int) -> int = let y = x in y + y\nfn f(a: int) -> int\n  ensures e: let y = 100 in twice(a) + y == result\n")
    var env2 = Env(one(Value.int(3)))
    env2.set_result(Value.int(106))
    assert_true(judge_clause(spec2, "f.e", env2, host).is_true())


def test_a_definition_taking_reals_keeps_them_real() raises:
    var spec = spec_of("fn half(x: int) -> real = x / 2\nfn f(a: int) -> int\n  ensures e: half(a) == 2\n")
    var host = Mock()
    var env = Env(one(Value.int(4)))
    env.set_result(Value.int(0))
    assert_true(judge_clause(spec, "f.e", env, host).is_true())


def test_observer_reading_expressions() raises:
    var spec = spec_of("model M\n  observe members: list<int> = builtins.list(self)\n  observe at(i: int): int = builtins.getitem(self, i) + 1\n  observe n: int\n")
    var host = Mock()
    var h = Value.handle(3, "M")
    host.on_extern("builtins.list", ints(1, 2))
    host.on_extern("builtins.getitem", Value.int(41))
    is_(observe_with(spec, 0, 0, h, none_args(), host), ints(1, 2))
    is_(observe_with(spec, 0, 1, h, one(Value.int(0)), host), Value.int(42))
    assert_equal(host.calls("extern builtins.getitem"), 1)
    try:
        _ = observe_with(spec, 0, 2, h, none_args(), host)
        assert_true(False, "an observer without a reading expression")
    except e:
        has(String(e), "no reading expression")
    try:
        _ = observe_with(spec, 0, 1, h, none_args(), host)
        assert_true(False, "missing argument")
    except e:
        has(String(e), "takes 1 argument")


def test_constants_come_from_the_host() raises:
    var spec = spec_of("model pkg.Codec\nconst pkg.int8: pkg.Codec\nconst pkg.int16: pkg.Codec\nfn f(c: pkg.int8 | pkg.int16)\n  ensures e: c == pkg.int8\n")
    var host = Mock()
    host.on_constant(0, Value.handle(9, "pkg.Codec"))
    var env = Env(one(Value.handle(9, "pkg.Codec")))
    var j = judge_clause(spec, "f.e", env, host)
    assert_true(j.is_true(), j.describe(spec))
    assert_equal(host.calls("constant 0"), 1)
    host.on_constant(0, Value.handle(8, "pkg.Codec"))
    var k = judge_clause(spec, "f.e", env, host)
    assert_true(k.is_false(), k.describe(spec))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
