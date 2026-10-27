"""Helpers for the package's tests: a mock host, and checking and evaluating fragments."""

from std.testing import assert_true

from check.checker import check_source
from check.spec import Spec
from numeric.bigint import BigInt
from numeric.formats import F32, F64, FloatFormat
from wire.format import format_value
from wire.value import HANDLE, Value

from .api import J_ERROR, J_FALSE, J_SKIP, J_TRUE, Judgment, evaluate, judge
from .env import Env
from .host import EvalHost


struct Mock(EvalHost):
    """A host whose answers a test registers; every request is logged."""

    var obs_model: List[Int]
    var obs_observer: List[Int]
    var obs_value: List[Value]
    var obs_handle: List[Int]
    var last_args: List[Value]
    var fn_pos: List[Int]
    var fn_val: List[Value]
    var const_pos: List[Int]
    var const_val: List[Value]
    var extern_name: List[String]
    var extern_val: List[Value]
    var is_fresh: Bool
    var is_same: Bool
    var is_shared: Bool
    var log: List[String]

    def __init__(out self):
        self.obs_model = List[Int]()
        self.obs_observer = List[Int]()
        self.obs_value = List[Value]()
        self.obs_handle = List[Int]()
        self.last_args = List[Value]()
        self.fn_pos = List[Int]()
        self.fn_val = List[Value]()
        self.const_pos = List[Int]()
        self.const_val = List[Value]()
        self.extern_name = List[String]()
        self.extern_val = List[Value]()
        self.is_fresh = True
        self.is_same = True
        self.is_shared = False
        self.log = List[String]()

    def on_observe(mut self, model: Int, observer: Int, var value: Value, handle: Int = -1):
        """Answer observer `observer` of model `model` with `value`, for the handle with
        id `handle` (any handle when -1). A later answer replaces an earlier one."""
        for i in range(len(self.obs_model)):
            if (
                self.obs_model[i] == model
                and self.obs_observer[i] == observer
                and self.obs_handle[i] == handle
            ):
                self.obs_value[i] = value^
                return
        self.obs_model.append(model)
        self.obs_observer.append(observer)
        self.obs_handle.append(handle)
        self.obs_value.append(value^)

    def on_call(mut self, fn_index: Int, var value: Value):
        for i in range(len(self.fn_pos)):
            if self.fn_pos[i] == fn_index:
                self.fn_val[i] = value^
                return
        self.fn_pos.append(fn_index)
        self.fn_val.append(value^)

    def on_constant(mut self, index: Int, var value: Value):
        for i in range(len(self.const_pos)):
            if self.const_pos[i] == index:
                self.const_val[i] = value^
                return
        self.const_pos.append(index)
        self.const_val.append(value^)

    def on_extern(mut self, var name: String, var value: Value):
        for i in range(len(self.extern_name)):
            if self.extern_name[i] == name:
                self.extern_val[i] = value^
                return
        self.extern_name.append(name^)
        self.extern_val.append(value^)

    def calls(self, prefix: String) -> Int:
        var n = 0
        for entry in self.log:
            if entry.startswith(prefix):
                n += 1
        return n

    def observe(
        mut self, obj: Value, model: Int, observer: Int, args: List[Value]
    ) raises -> Value:
        self.log.append(String("observe ", model, ".", observer, " ", len(args)))
        self.last_args = args.copy()
        for i in range(len(self.obs_model)):
            if self.obs_model[i] == model and self.obs_observer[i] == observer:
                if self.obs_handle[i] < 0 or (
                    obj.kind == HANDLE and Int(obj.handle_id()) == self.obs_handle[i]
                ):
                    return self.obs_value[i].copy()
        raise Error("mock: no observer " + String(model) + "." + String(observer))

    def call_fn(mut self, fn_pos: Int, args: List[Value]) raises -> Value:
        var shown = String()
        for a in args:
            shown += " " + format_value(a)
        self.log.append(String("call ", fn_pos, shown))
        self.last_args = args.copy()
        for i in range(len(self.fn_pos)):
            if self.fn_pos[i] == fn_pos:
                return self.fn_val[i].copy()
        raise Error("mock: no planned call " + String(fn_pos))

    def constant(mut self, const_pos: Int) raises -> Value:
        self.log.append(String("constant ", const_pos))
        for i in range(len(self.const_pos)):
            if self.const_pos[i] == const_pos:
                return self.const_val[i].copy()
        raise Error("mock: no constant " + String(const_pos))

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
        for i in range(len(self.extern_name)):
            if self.extern_name[i] == name:
                return self.extern_val[i].copy()
        raise Error("mock: no extern " + name)


def spec_of(body: String) raises -> Spec:
    """Check `spec t` followed by `body`."""
    return check_source("spec t\n" + body, "t.spec")


def clause_pos(spec: Spec, id: String) raises -> Int:
    var found = spec.clause_named(id)
    assert_true(Bool(found), "no clause " + id)
    return found.value()


def judge_clause(spec: Spec, id: String, env: Env, mut host: Mock) raises -> Judgment:
    return judge(spec, clause_pos(spec, id), env, host)


def fragment(params: String, expr: String, returns: String = "") -> String:
    var arrow = (" -> " + returns) if returns else String()
    return "fn f(" + params + ")" + arrow + "\n  ensures e: let v = (" + expr + ") in true\n"


def expr_node(spec: Spec) raises -> Int:
    """The expression of the `let` that `fragment` wraps its expression in."""
    ref clause = spec.clauses[clause_pos(spec, "f.e")]
    return spec.ast.kid(clause.expr, 0)


def value_of(
    params: String, expr: String, var args: List[Value], returns: String = ""
) raises -> Value:
    """Evaluate `expr` as written in an ensures clause of `fn f(params)`."""
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
    assert_true(False, "expected an error evaluating " + expr)
    return String()


def f64v(x: Float64) -> Value:
    return Value.float(F64, UInt64(bitcast_f64(x)))


def bitcast_f64(x: Float64) -> UInt64:
    from std.memory import bitcast

    return bitcast[DType.uint64](x)


def f32v(x: Float32) -> Value:
    from std.memory import bitcast

    return Value.float(F32, UInt64(bitcast[DType.uint32](x)))


def ints(*values: Int) -> Value:
    var out = List[Value]()
    for v in values:
        out.append(Value.int(v))
    return Value.list(out^)


def none_args() -> List[Value]:
    return List[Value]()


def one(var v: Value) -> List[Value]:
    var out = List[Value]()
    out.append(v^)
    return out^


def two(var a: Value, var b: Value) -> List[Value]:
    var out = List[Value]()
    out.append(a^)
    out.append(b^)
    return out^


def bytes_of(text: String) -> Value:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return Value.bytes(out^)


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
