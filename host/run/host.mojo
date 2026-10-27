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
comptime TIMEOUT = "spectest.CallTimeout"
"""The class of the error a driver returns for a call past its time limit."""


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
    var build_targets: Dict[String, Int]
    var const_values: List[Value]
    var const_known: List[Bool]
    var tnames: List[String]
    var tids: List[Int]
    """The instantiation of the declaration being run."""
    var memo: Dict[Value, Int]
    """Planned calls of the current example: the function and arguments as one list
    value, to the position of the result in `memo_result`."""
    var memo_result: List[Value]
    var known: List[UInt64]
    """Ids of the handles among the current example's arguments."""
    var seen: List[UInt64]
    """Ids of every handle the run met, to release."""
    var timed_out: Bool
    """A reply of class TIMEOUT came back since the catch paths last took it."""

    def __init__(out self, mut loaded: Loaded, mut client: DriverClient):
        self.loaded = Pointer[Loaded, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=loaded))
        )
        self.client = Pointer[DriverClient, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=client))
        )
        self.targets = List[Int](length=len(loaded.spec.fns), fill=NO_TARGET)
        self.build_targets = {}
        self.const_values = [Value.none() for _ in loaded.spec.consts]
        self.const_known = [False for _ in loaded.spec.consts]
        self.tnames = []
        self.tids = []
        self.memo = {}
        self.memo_result = []
        self.known = []
        self.seen = []
        self.timed_out = False

    # Example bookkeeping

    def take_timeout(mut self) -> Bool:
        """Whether a call timed out since the last take; clears the mark."""
        var out = self.timed_out
        self.timed_out = False
        return out

    def _reply(mut self, var reply: Value) -> Value:
        if reply.kind == ERROR and reply.name() == TIMEOUT:
            self.timed_out = True
        return reply^

    def begin_example(mut self, args: List[Value]):
        self.timed_out = False
        if len(self.memo_result) > 0:
            self.memo.clear()
            self.memo_result.clear()
        self.known.clear()
        self.known += [a.handle_id() for a in args if a.kind == HANDLE]

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
        if name not in self.build_targets:
            self.build_targets[name] = self.client[].resolve(name)
        return self.build_targets[name]

    def call(mut self, f: Int, args: List[Value]) raises -> Value:
        """Calls Spec.fns[f]; a library error comes back as an ERROR value."""
        return self._reply(self.client[].call(self.fn_target(f), args))

    # Builder

    def build(mut self, model: Int, build: Int, args: List[Value]) raises -> Value:
        ref b = self.loaded[].spec.models[model].builds[build]
        var target = self.named_target(b.target)
        var out = self._reply(self.client[].call(target, args))
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
                self.timed_out = self.timed_out or reply.name() == TIMEOUT
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
        var packed: List[Value] = [Value.int(`fn`)]
        packed += args.copy()
        var key = Value.list(packed^)
        var found = self.memo.get(key)
        var out: Value
        if found is not None:
            out = self.memo_result[found.value()].copy()
        else:
            out = self._planned(`fn`, args)
            self.memo[key^] = len(self.memo_result)
            self.memo_result.append(out.copy())
        if out.kind == ERROR and out.name() == TIMEOUT:
            self.timed_out = True
            raise Error(String("planned call of ", self.loaded[].spec.fns[`fn`].name, " raised ", TIMEOUT, ": ", out.text()))
        return out^

    def _planned(mut self, f: Int, args: List[Value]) raises -> Value:
        ref func = self.loaded[].spec.fns[f]
        var env = Env(args.copy())
        var rtype = func.result
        var names = List[String]()
        var ids = List[Int]()
        for tparam in func.tparams:
            for name, id in zip(self.tnames, self.tids):
                if name == tparam:
                    env.bind_type(tparam, id)
                    names.append(tparam)
                    ids.append(id)
        if len(func.tparams) > 0:
            rtype = self.loaded[].spec.types.substitute(rtype, names, ids)
        for c in func.clauses:
            if self.loaded[].spec.clauses[c].kind != .REQUIRES:
                continue
            var j = judge(self.loaded[].spec, c, env, self)
            if j.is_false():
                return error_value(
                    "spectest.RequiresFalse",
                    String("planned call of ", func.name, " is outside ", self.loaded[].spec.clauses[c].id),
                )
            if j.is_error() or j.is_skip():
                raise Error(String(self.loaded[].spec.clauses[c].id, ": ", j.describe(self.loaded[].spec)))
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
        return obj.kind == HANDLE and obj.handle_id() not in self.known

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
        var out = self._reply(self.client[].call(target, args))
        if out.kind == ERROR:
            raise Error(String(name, " raised ", out.name(), ": ", out.text()))
        return out^
