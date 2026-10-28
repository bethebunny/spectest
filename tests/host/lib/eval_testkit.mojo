"""A mock host for the evaluator's tests, and helpers to check and evaluate fragments."""

from std.memory import bitcast
from std.testing import assert_true

from check.checker import check_source
from spec.spec import Spec
from value.bigint import BigInt
from value.float_formats import F32, F64, FloatFormat
from value.text import format_value
from value.value import Value

from eval.api import Judgment, evaluate, judge
from eval.env import Env
from eval.host import EvalHost


struct Mock(EvalHost):
    """A host whose answers a test registers; every request is logged."""

    var observed: Dict[String, Value]
    var called: Dict[Int, Value]
    var constants: Dict[Int, Value]
    var externs: Dict[String, Value]
    var last_args: List[Value]
    var is_fresh: Bool
    var is_same: Bool
    var is_shared: Bool
    var log: List[String]

    def __init__(out self):
        self.observed = {}
        self.called = {}
        self.constants = {}
        self.externs = {}
        self.last_args = []
        self.is_fresh = True
        self.is_same = True
        self.is_shared = False
        self.log = []

    def on_observe(mut self, model: Int, observer: Int, var value: Value, handle: Int = -1):
        """Answer the observer for the handle with id `handle` (any handle when -1)."""
        self.observed[String(model, ".", observer, ".", handle)] = value^

    def on_call(mut self, fn_index: Int, var value: Value):
        self.called[fn_index] = value^

    def on_constant(mut self, index: Int, var value: Value):
        self.constants[index] = value^

    def on_extern(mut self, var name: String, var value: Value):
        self.externs[name^] = value^

    def calls(self, prefix: String) -> Int:
        return len([entry for entry in self.log if entry.startswith(prefix)])

    def observe(
        mut self, obj: Value, model: Int, observer: Int, args: List[Value]
    ) raises -> Value:
        self.log.append(String("observe ", model, ".", observer, " ", len(args)))
        self.last_args = args.copy()
        var of_handle = String(model, ".", observer, ".", Int(obj.handle_id()) if obj.kind == .HANDLE else -2)
        if of_handle in self.observed:
            return self.observed[of_handle].copy()
        var of_any = String(model, ".", observer, ".-1")
        if of_any in self.observed:
            return self.observed[of_any].copy()
        raise Error(t"mock: no observer {model}.{observer}")

    def call_fn(mut self, fn_pos: Int, args: List[Value]) raises -> Value:
        self.log.append(String("call ", fn_pos, "".join([String(" ", format_value(a)) for a in args])))
        self.last_args = args.copy()
        if fn_pos in self.called:
            return self.called[fn_pos].copy()
        raise Error(t"mock: no planned call {fn_pos}")

    def constant(mut self, const_pos: Int) raises -> Value:
        self.log.append(String("constant ", const_pos))
        if const_pos in self.constants:
            return self.constants[const_pos].copy()
        raise Error(t"mock: no constant {const_pos}")

    def fresh(mut self, obj: Value) raises -> Bool:
        self.log.append("fresh")
        return self.is_fresh

    def same_object(mut self, a: Value, b: Value) raises -> Bool:
        self.log.append("same_object")
        return self.is_same

    def shares_memory(mut self, a: Value, b: Value) raises -> Bool:
        self.log.append("shares_memory")
        return self.is_shared

    def call_extern(mut self, name: String, args: List[Value]) raises -> Value:
        self.log.append("extern " + name)
        if name in self.externs:
            return self.externs[name].copy()
        raise Error(t"mock: no extern {name}")


def spec_of(body: String) raises -> Spec:
    return check_source("spec t\n" + body, "t.spec")


def clause_pos(spec: Spec, id: String) raises -> Int:
    var found = spec.clause_named(id)
    assert_true(found is not None, String(t"no clause {id}"))
    return found.value()


def judge_clause(spec: Spec, id: String, env: Env, mut host: Mock) raises -> Judgment:
    return judge(spec, clause_pos(spec, id), env, host)


def fragment(params: String, expr: String, returns: String = "") -> String:
    var arrow = String(" -> ", returns) if returns else String()
    return String("fn f(", params, ")", arrow, "\n  ensures e: let v = (", expr, ") in true\n")


def expr_node(spec: Spec) raises -> Int:
    """The expression of the `let` that `fragment` wraps its expression in."""
    return spec.ast.child(spec.clauses[clause_pos(spec, "f.e")].expr, 0)


def value_of(
    params: String, expr: String, var args: List[Value], returns: String = ""
) raises -> Value:
    var spec = spec_of(fragment(params, expr, returns))
    var host = Mock()
    return evaluate(spec, expr_node(spec), Env(args^), host)


def value_text(
    params: String, expr: String, var args: List[Value], returns: String = ""
) raises -> String:
    return format_value(value_of(params, expr, args^, returns))


def error_of(
    params: String, expr: String, var args: List[Value], returns: String = ""
) raises -> String:
    """The message evaluating `expr` raises; fails the test if it doesn't."""
    var spec = spec_of(fragment(params, expr, returns))
    var host = Mock()
    try:
        _ = evaluate(spec, expr_node(spec), Env(args^), host)
    except e:
        return String(e)
    assert_true(False, String(t"expected an error evaluating {expr}"))
    return String()


def bitcast_f64(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def f64v(x: Float64) -> Value:
    return Value.float(F64, bitcast_f64(x))


def f32v(x: Float32) -> Value:
    return Value.float(F32, UInt64(bitcast[DType.uint32](x)))


def ints(*values: Int) -> Value:
    return Value.list([Value.int(v) for v in values])


def none_args() -> List[Value]:
    return []


def one(var v: Value) -> List[Value]:
    return [v^]


def two(var a: Value, var b: Value) -> List[Value]:
    return [a^, b^]


def bytes_of(text: String) -> Value:
    return Value.bytes(List(text.as_bytes()))


def real_v(n: Int, d: Int = 1) -> Value:
    """The REAL n/d, in lowest terms with a positive denominator (d may be 0 for the
    infinities: n is then 1 or -1)."""
    return Value.real(BigInt(n), BigInt(d))


def nan64() -> Value:
    return Value.float(F64, UInt64(0x7FF8000000000000))


def inf64(negative: Bool = False) -> Value:
    return Value.float(F64, UInt64(0xFFF0000000000000) if negative else UInt64(0x7FF0000000000000))


def big(text: String) raises -> Value:
    return Value.int(BigInt.parse(text))
