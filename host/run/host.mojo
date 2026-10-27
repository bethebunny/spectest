"""The evaluator's host over the driver: observers, planned calls, constants and
identity questions, and the builder that makes values of models."""

from check import types as ty
from check.spec import Spec
from check.types import Types
from eval.api import judge, observe_with
from eval.env import Env
from eval.host import EvalHost
from gen.models import Builder
from syntax import ast
from wire.format import format_value
from wire.value import ERROR, HANDLE, LIST, Value

from bridge.client import DriverClient

from .decode import decode
from .load import Loaded


comptime NO_TARGET = -2


def error_value(cls: String, message: String) -> Value:
    return Value.error(cls, List[String](), message)


struct RunHost(Builder, EvalHost):
    """Calls the code under test for the evaluator and the generator. It keeps the
    targets it resolved, the planned calls of the current example (identical calls
    are made once), and the handles it saw, which the run releases at its end."""

    var loaded: Pointer[Loaded, MutUntrackedOrigin]
    var client: Pointer[DriverClient, MutUntrackedOrigin]
    var targets: List[Int]
    """By position in Spec.fns; NO_TARGET until resolved."""
    var build_names: List[String]
    var build_targets: List[Int]
    var const_values: List[Value]
    var const_known: List[Bool]
    var tnames: List[String]
    var tids: List[Int]
    """The instantiation of the declaration being run."""
    var memo_fn: List[Int]
    var memo_args: List[Value]
    var memo_result: List[Value]
    var known: List[UInt64]
    """Ids of the handles among the current example's arguments."""
    var seen: List[UInt64]
    """Ids of every handle the run met, to release."""
    var planned: Int
    var calls: Int

    def __init__(out self, mut loaded: Loaded, mut client: DriverClient):
        self.loaded = Pointer[Loaded, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=loaded))
        )
        self.client = Pointer[DriverClient, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=client))
        )
        self.targets = List[Int](length=len(loaded.spec.fns), fill=NO_TARGET)
        self.build_names = List[String]()
        self.build_targets = List[Int]()
        self.const_values = List[Value]()
        self.const_known = List[Bool]()
        for _ in range(len(loaded.spec.consts)):
            self.const_values.append(Value.none())
            self.const_known.append(False)
        self.tnames = List[String]()
        self.tids = List[Int]()
        self.memo_fn = List[Int]()
        self.memo_args = List[Value]()
        self.memo_result = List[Value]()
        self.known = List[UInt64]()
        self.seen = List[UInt64]()
        self.planned = 0
        self.calls = 0

    # Example bookkeeping

    def begin_example(mut self, args: List[Value]):
        self.memo_fn.clear()
        self.memo_args.clear()
        self.memo_result.clear()
        self.known.clear()
        for a in args:
            if a.kind == HANDLE:
                self.known.append(a.handle_id())

    def track(mut self, v: Value, deep: Bool = True):
        """Remembers the handles in `v`."""
        if v.kind == HANDLE:
            self.seen.append(v.handle_id())
        elif deep and Bool(v.heap):
            for i in range(v.item_count()):
                self.track(v.item(i))

    def release_all(mut self):
        if len(self.seen) == 0:
            return
        try:
            self.client[].release(self.seen)
        except:
            pass
        self.seen.clear()

    # Targets

    def fn_target(mut self, f: Int) raises -> Int:
        if self.targets[f] == NO_TARGET:
            self.targets[f] = self.client[].resolve(self.loaded[].spec.fns[f].target)
        return self.targets[f]

    def named_target(mut self, name: String) raises -> Int:
        for i in range(len(self.build_names)):
            if self.build_names[i] == name:
                return self.build_targets[i]
        var t = self.client[].resolve(name)
        self.build_names.append(name)
        self.build_targets.append(t)
        return t

    def call(mut self, f: Int, args: List[Value]) raises -> Value:
        """Calls Spec.fns[f]; a library error comes back as an ERROR value."""
        var target = self.fn_target(f)
        self.calls += 1
        return self.client[].call(target, args)

    # Builder

    def build(mut self, model: Int, build: Int, args: List[Value]) raises -> Value:
        ref b = self.loaded[].spec.models[model].builds[build]
        var target = self.named_target(b.target)
        var out = self.client[].call(target, args)
        if out.kind == ERROR:
            raise Error(String("building ", b.target, " raised ", out.name(), ": ", out.text()))
        if out.kind != HANDLE:
            raise Error(String("building ", b.target, " returned ", format_value(out), ", not an object"))
        self.track(out, False)
        return out^

    # EvalHost

    def observe(
        mut self, obj: Value, model: Int, observer: Int, args: List[Value]
    ) raises -> Value:
        ref o = self.loaded[].spec.models[model].observers[observer]
        var got: Value
        if o.expr != 0:
            got = observe_with(self.loaded[].spec, model, observer, obj, args, self)
        else:
            var reply: Value
            if len(o.params) == 0 and len(args) == 0:
                reply = self.client[].observe(obj, o.name, None)
            else:
                reply = self.client[].observe(obj, o.name, Optional(args.copy()))
            if reply.kind == ERROR:
                raise Error(
                    String(
                        "observer ", self.loaded[].spec.models[model].name, ".", o.name,
                        " raised ", reply.name(), ": ", reply.text(),
                    )
                )
            try:
                got = decode(reply, o.type, self.loaded[].spec.types)
            except e:
                raise Error(
                    String("observer ", self.loaded[].spec.models[model].name, ".", o.name, ": ", e)
                )
        if got.kind == HANDLE:
            self.seen.append(got.handle_id())
        return got^

    def call_fn(mut self, `fn`: Int, args: List[Value]) raises -> Value:
        var packed = Value.list(args.copy())
        for i in range(len(self.memo_fn)):
            if self.memo_fn[i] == `fn` and self.memo_args[i] == packed:
                return self.memo_result[i].copy()
        var out = self._planned(`fn`, args)
        self.memo_fn.append(`fn`)
        self.memo_args.append(packed^)
        self.memo_result.append(out.copy())
        return out^

    def _planned(mut self, f: Int, args: List[Value]) raises -> Value:
        ref func = self.loaded[].spec.fns[f]
        var env = Env(args.copy())
        var rtype = func.result
        for j in range(len(func.tparams)):
            for k in range(len(self.tnames)):
                if self.tnames[k] == func.tparams[j]:
                    env.bind_type(func.tparams[j], self.tids[k])
        if len(func.tparams) > 0:
            var names = List[String]()
            var ids = List[Int]()
            for j in range(len(func.tparams)):
                for k in range(len(self.tnames)):
                    if self.tnames[k] == func.tparams[j]:
                        names.append(func.tparams[j])
                        ids.append(self.tids[k])
            rtype = self.loaded[].spec.types.substitute(rtype, names, ids)
        for c in func.clauses:
            if self.loaded[].spec.clauses[c].kind != ast.REQUIRES:
                continue
            var j = judge(self.loaded[].spec, c, env, self)
            if j.is_false():
                self.planned += 1
                return error_value(
                    "spectest.RequiresFalse",
                    String("planned call of ", func.name, " is outside ", self.loaded[].spec.clauses[c].id),
                )
            if j.is_error() or j.is_skip():
                raise Error(String(self.loaded[].spec.clauses[c].id, ": ", j.describe(self.loaded[].spec)))
        self.planned += 1
        var out = self.call(f, args)
        if out.kind == ERROR:
            return out^
        try:
            var got = decode(out, rtype, self.loaded[].spec.types)
            self.track(got)
            return got^
        except e:
            return error_value(
                "spectest.TypeMismatch",
                String("planned call of ", func.name, " returned a value that is not ",
                       self.loaded[].spec.types.text(rtype), ": ", e),
            )

    def constant(mut self, `const`: Int) raises -> Value:
        if self.const_known[`const`]:
            return self.const_values[`const`].copy()
        ref c = self.loaded[].spec.consts[`const`]
        var target = self.client[].resolve(c.name)
        var raw = self.client[].get(target)
        if raw.kind == ERROR:
            raise Error(String("constant ", c.name, ": ", raw.name(), ": ", raw.text()))
        var got = decode(raw, c.type, self.loaded[].spec.types)
        self.const_values[`const`] = got.copy()
        self.const_known[`const`] = True
        self.track(got, False)
        return got^

    def fresh(mut self, obj: Value) raises -> Bool:
        if obj.kind != HANDLE:
            return False
        for id in self.known:
            if id == obj.handle_id():
                return False
        return True

    def same_object(mut self, a: Value, b: Value) raises -> Bool:
        if a.kind == HANDLE and b.kind == HANDLE:
            return a.handle_id() == b.handle_id()
        return a == b

    def shares_memory(mut self, a: Value, b: Value) raises -> Bool:
        if a.kind == HANDLE and b.kind == HANDLE:
            return a.handle_id() == b.handle_id()
        raise Error("shares_memory needs two objects")

    def call_extern(mut self, name: String, args: List[Value]) raises -> Value:
        var target = self.named_target(name)
        var out = self.client[].call(target, args)
        if out.kind == ERROR:
            raise Error(String(name, " raised ", out.name(), ": ", out.text()))
        return out^
