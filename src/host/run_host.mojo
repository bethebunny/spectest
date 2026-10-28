"""The evaluator's host over the driver: observers, planned calls, constants and
identity questions, and the builder that makes values of models."""

from interpreter.api import judge, observe_with
from interpreter.env import Env
from interpreter.host import EvalHost
from value.text import format_value
from value.value import Value

from host.draw.models import Builder

from .decode import decode
from .driver import Driver
from .load import Loaded


comptime TIMEOUT = "spectest.CallTimeout"
"""The class of the error a driver returns for a call past its time limit."""


def error_value(cls: String, message: String) -> Value:
    return Value.error(cls, [], message)


struct RunHost[D: Driver](Builder, EvalHost):
    """Calls the code under test for the evaluator and the generator. It keeps the
    targets it resolved, the planned calls of the current example (identical calls
    are made once), and the handles it saw, which the run releases at its end."""

    var loaded: Pointer[Loaded, MutUntrackedOrigin]
    var client: Pointer[Self.D, MutUntrackedOrigin]
    var targets: List[Optional[Int]]
    """Of each of Spec.fns, once resolved."""
    var named_targets: Dict[String, Int]
    var constants: List[Optional[Value]]
    """Of each of Spec.consts, once read."""
    var instantiation: Dict[String, Int]
    """Each type parameter of the declaration being run and its type."""
    var planned: Dict[Value, Value]
    """The planned calls of the current example, each the function and arguments as
    one list value, and their results."""
    var known: List[UInt64]
    """Ids of the handles among the current example's arguments."""
    var seen: List[UInt64]
    """Ids of every handle the run met, to release."""
    var timed_out: Bool
    """A reply of class TIMEOUT came back since the catch paths last took it."""

    def __init__(out self, mut loaded: Loaded, mut client: Self.D):
        self.loaded = Pointer(to=loaded).unsafe_origin_cast[MutUntrackedOrigin]()
        self.client = Pointer(to=client).unsafe_origin_cast[MutUntrackedOrigin]()
        self.targets = [None for _ in loaded.spec.fns]
        self.named_targets = {}
        self.constants = [None for _ in loaded.spec.consts]
        self.instantiation = {}
        self.planned = {}
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
        if reply.kind == .Error and reply.name() == TIMEOUT:
            self.timed_out = True
        return reply^

    def begin_example(mut self, args: List[Value]):
        self.timed_out = False
        self.planned.clear()
        self.known = [a.handle_id() for a in args if a.kind == .Handle]

    def bind_types(self, mut env: Env):
        for e in self.instantiation.items():
            env.bind_type(e.key, e.value)

    def instantiation_text(self) -> List[Tuple[String, String]]:
        return [(e.key.copy(), self.loaded[].spec.types.text(e.value)) for e in self.instantiation.items()]

    def track(mut self, v: Value, *, deep: Bool = True):
        """Remembers the handles in `v`, or only `v` itself when not `deep`."""
        if v.kind == .Handle:
            self.seen.append(v.handle_id())
        elif deep:
            for item in v.items():
                self.track(item)

    def release_all(mut self):
        if not self.seen:
            return
        try:
            self.client[].release(self.seen)
        except:
            pass
        self.seen.clear()

    # Targets

    def fn_target(mut self, f: Int) raises -> Int:
        if self.targets[f] is None:
            self.targets[f] = self.client[].resolve(self.loaded[].spec.fns[f].target)
        return self.targets[f].value()

    def named_target(mut self, name: String) raises -> Int:
        if case .Some(target) = self.named_targets.get(name):
            return target
        var target = self.client[].resolve(name)
        self.named_targets[name] = target
        return target

    def call(mut self, f: Int, args: List[Value]) raises -> Value:
        """Calls Spec.fns[f]; a library error comes back as an ERROR value."""
        return self._reply(self.client[].call(self.fn_target(f), args))

    # Builder

    def build(mut self, model: Int, build: Int, args: List[Value]) raises -> Value:
        ref b = self.loaded[].spec.models[model].builds[build]
        var out = self._reply(self.client[].call(self.named_target(b.target), args))
        if out.kind == .Error:
            raise Error(t"building {b.target} raised {out.error_text()}")
        if out.kind != .Handle:
            raise Error(t"building {b.target} returned {format_value(out)}, not an object")
        self.track(out, deep=False)
        return out^

    # EvalHost

    def observe(
        mut self, obj: Value, model: Int, observer: Int, args: List[Value]
    ) raises -> Value:
        ref spec = self.loaded[].spec
        ref o = spec.models[model].observers[observer]
        var got: Value
        if o.expr != 0:
            got = observe_with(spec, model, observer, obj, args, self)
        else:
            var reply = self._reply(self.client[].observe(obj, o.name, Optional(args.copy()) if o.params or args else None))
            if reply.kind == .Error:
                raise Error(t"observer {spec.models[model].name}.{o.name} raised {reply.error_text()}")
            try:
                got = decode(reply, o.type, spec.types)
            except e:
                raise Error(t"observer {spec.models[model].name}.{o.name}: {e}")
        if got.kind == .Handle:
            self.seen.append(got.handle_id())
        return got^

    def call_fn(mut self, `fn`: Int, args: List[Value]) raises -> Value:
        var packed: List[Value] = [Value.int(`fn`)]
        packed += args.copy()
        var key = Value.list(packed^)
        var out: Value
        if case .Some(known) = self.planned.get(key):
            out = known.copy()
        else:
            out = self._planned(`fn`, args)
            self.planned[key^] = out.copy()
        if out.kind == .Error and out.name() == TIMEOUT:
            self.timed_out = True
            raise Error(t"planned call of {self.loaded[].spec.fns[`fn`].name} raised {TIMEOUT}: {out.text()}")
        return out^

    def _planned(mut self, f: Int, args: List[Value]) raises -> Value:
        ref spec = self.loaded[].spec
        ref func = spec.fns[f]
        var env = Env(args.copy())
        var names: List[String] = []
        var types: List[Int] = []
        for tparam in func.tparams:
            if case .Some(t) = self.instantiation.get(tparam):
                env.bind_type(tparam, t)
                names.append(tparam)
                types.append(t)
        var result_type = spec.types.substitute(func.result, names, types) if func.tparams else func.result
        for c in func.clauses:
            ref cl = spec.clauses[c]
            if cl.kind != .REQUIRES:
                continue
            var j = judge(spec, c, env, self)
            if j.is_false():
                return error_value("spectest.RequiresFalse", String(t"planned call of {func.name} is outside {cl.id}"))
            if j.is_error() or j.is_skip():
                raise Error(t"{cl.id}: {j.describe(spec)}")
        var out = self.call(f, args)
        if out.kind == .Error:
            return out^
        try:
            var got = decode(out, result_type, spec.types)
            self.track(got)
            return got^
        except e:
            return error_value(
                "spectest.TypeMismatch",
                String(t"planned call of {func.name} returned a value that is not {spec.types.text(result_type)}: {e}"),
            )

    def constant(mut self, `const`: Int) raises -> Value:
        if case .Some(known) = self.constants[`const`]:
            return known.copy()
        ref c = self.loaded[].spec.consts[`const`]
        var raw = self.client[].get(self.client[].resolve(c.name))
        if raw.kind == .Error:
            raise Error(t"constant {c.name}: {raw.error_text()}")
        var got = decode(raw, c.type, self.loaded[].spec.types)
        self.constants[`const`] = got.copy()
        self.track(got, deep=False)
        return got^

    def fresh(mut self, obj: Value) raises -> Bool:
        return obj.kind == .Handle and obj.handle_id() not in self.known

    def same_object(mut self, a: Value, b: Value) raises -> Bool:
        if a.kind == .Handle and b.kind == .Handle:
            return a.handle_id() == b.handle_id()
        return a == b

    def shares_memory(mut self, a: Value, b: Value) raises -> Bool:
        if a.kind == .Handle and b.kind == .Handle:
            return a.handle_id() == b.handle_id()
        raise Error("shares_memory needs two objects")

    def call_extern(mut self, name: String, args: List[Value]) raises -> Value:
        var out = self._reply(self.client[].call(self.named_target(name), args))
        if out.kind == .Error:
            raise Error(t"{name} raised {out.error_text()}")
        return out^
