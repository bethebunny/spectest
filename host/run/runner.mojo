"""Running one declaration: one search whose properties are all of its clauses.

`Prop` is the mcheck property: it draws the arguments of one example, applies
`requires`, snapshots `old`, calls the code under test through the driver and judges
every clause by the verdict table of docs/language.md. `run` drives it: explicit
examples first, then an exhaustive pass over a small domain or a search that replays
the stored failures, generates, and shrinks each failing clause on its own."""

from std.time import perf_counter_ns

from bridge.client import DriverClient
from check import types as ty
from check.spec import Spec
from eval.api import (
    Judgment,
    class_holds,
    evaluate,
    explain,
    judge,
    old_calls,
    snapshot_olds,
)
from eval.coerce import bits_of_value, coerce_arg
from eval.env import Env
from eval.text import source_text
from gen.classes import draw_in_classes
from gen.domain import product_size, values_at
from gen.models import (
    default_marker,
    draw_args,
    draw_model,
    is_default,
    is_not_drawn,
)
from gen.value import draw_value
from mcheck.choices import Choices
from mcheck.property import FAILED, PASSED, SKIPPED, Outcome, Property
from mcheck.search import SearchResult, enumerate_all, search
from mcheck.settings import Settings
from mcheck.shrink import shrink
from mcheck.source import Source
from sets import BitSet
from syntax import ast
from syntax.chars import is_digit, is_word_char
from wire.format import format_value
from wire.value import Value

from .aggregate import run_aggregate
from .decode import decode, describe
from .host import TIMEOUT, RunHost
from .load import Loaded, fnv
from .options import RunOptions
from .util import (
    N_CAUSES,
    cause_index,
    cause_name,
    collect_models,
    contains_name,
    handles_of,
    names_text,
    norm_name,
    parse_type,
    type_has_model,
)
from .results import ClauseResult, Counterexample, RunResult


comptime V_PASS = 0
comptime V_FAIL = 1
comptime V_SKIP = 2
comptime V_ERROR = 3
comptime V_TIMEOUT = 4

comptime K_COND = 0
comptime K_RAISES = 1
comptime K_MODIFIES = 2
comptime K_TYPE = 3
comptime K_ANY_RAISES = 4
comptime K_FRAME = 5
comptime K_INVARIANT = 6

comptime SHRINK_SOURCE = 1 << 30
"""mcheck's shrinker replays through a source with this many choices at most; a
source with a smaller limit belongs to the search proper, whose examples are counted."""
comptime KEPT_SPEC_ERRORS = 20


def _is_handle(spec: Spec, t: Int) -> Bool:
    ref info = spec.types.info(t)
    return info.kind == ty.MODEL and not info.signed


@fieldwise_init
struct PropInfo(Copyable, Movable):
    var kind: Int
    var clause: Int
    """Position in Spec.clauses, or -1 for a built-in."""
    var id: String
    var text: String
    var label: String
    """The kind a result names: "ensures", "type", ..."""
    var model: Int
    """An invariant's model, a position in Spec.models."""


struct Detail(Copyable, Movable):
    """What a counterexample shows, captured while a failing example is replayed."""

    var present: Bool
    var cx: Counterexample

    def __init__(out self):
        self.present = False
        self.cx = Counterexample()


struct Prop(Property, Movable):
    var loaded: Pointer[Loaded, MutUntrackedOrigin]
    var host: RunHost
    var f: Int
    var decl: String
    var tenv: List[Int]
    var ptypes: List[Int]
    var rtype: Int
    var infos: List[PropInfo]
    var requires: List[Int]
    var cond_clauses: List[Int]
    var old_clauses: List[Int]
    var modified: List[String]
    var checked: List[Int]
    var errors: List[String]
    var result_has_model: Bool
    var domain: UInt64
    """The number of inputs when the domain is small enough to run all of them, else 0."""
    var cov_start: List[Int]
    var cov_names: List[String]
    # Per property tallies
    var tp: List[Int]
    var tf: List[Int]
    var ts: List[Int]
    var te: List[Int]
    var tt: List[Int]
    """Examples left inconclusive by a call past its time limit."""
    var causes: List[Int]
    var cov: List[Int]
    var fail_seen: List[Bool]
    var replayed: List[Bool]
    var req_skips: Int
    var unrep_skips: Int
    var se_pid: List[Int]
    var se_msg: List[String]
    var se_input: List[String]
    var se_choices: List[Choices]
    """The choices of the example that raised each spec error; empty when not from a search."""
    var target: String
    """While shrinking a spec error, its shape: an example then fails when it raises that error."""
    var hit_message: String
    var hit_input: String
    var inv_source: List[String]
    var inv_value: List[String]
    """The explanation of the invariant that failed in the current example."""
    # Per example scratch
    var vkind: List[Int]
    var vnote: List[String]
    var part_class: List[Int]
    var defaulted: List[Bool]
    # Detail capture
    var explain_all: Bool
    var focus: Int
    var details: List[Detail]
    var seed: Int
    # Stateful runs (run/stateful.mojo): the callable is a constructor or method of an
    # interface, judged against the objects live at the step.
    var stateful: Bool
    var live: List[Value]
    var live_names: List[String]
    var live_text: List[String]
    var self_name: String
    var timed_out: Bool
    """Whether the last `examine` ended on a call past its time limit."""
    var last_ran: Bool
    """Whether the last `examine` made the call."""
    var last_reply: Value
    var last_result: Value
    var last_ok: Bool
    """The last call returned a value that reads as the declared result type."""
    var iface: Int
    """The handle type of the interface, in a stateful run."""

    def __init__(
        out self,
        mut loaded: Loaded,
        mut client: DriverClient,
        f: Int,
        options: RunOptions,
        stateful: Bool = False,
    ) raises:
        self.stateful = stateful
        self.live = []
        self.live_names = []
        self.live_text = []
        self.self_name = ""
        self.timed_out = False
        self.last_ran = False
        self.last_reply = Value.none()
        self.last_result = Value.none()
        self.last_ok = False
        self.iface = loaded.spec.models[loaded.spec.fns[f].owner].type if stateful else 0
        self.loaded = Pointer[Loaded, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=loaded))
        )
        self.host = RunHost(loaded, client)
        self.f = f
        self.seed = Int(options.seed)
        ref func = loaded.spec.fns[f]
        self.decl = func.decl_id.copy()
        self.tenv = []
        for tparam in func.tparams:
            if tparam not in options.inst_names:
                raise Error(String(func.decl_id, " is generic: the run needs a type for ", tparam))
            var t = parse_type(options.inst_types[options.inst_names.index(tparam)], loaded.spec.types)
            self.tenv.append(t)
            self.host.tnames.append(tparam)
            self.host.tids.append(t)
        ref types = loaded.spec.types
        var generic = len(func.tparams) > 0
        self.ptypes = [types.substitute(p.type, func.tparams, self.tenv) if generic else p.type for p in func.params]
        self.rtype = types.substitute(func.result, func.tparams, self.tenv) if generic else func.result
        self.infos = []
        self.requires = []
        self.cond_clauses = []
        self.old_clauses = []
        self.modified = []
        self.checked = []
        self.errors = loaded.spec.errors.copy()
        self.result_has_model = type_has_model(types, self.rtype)
        self.domain = 0
        self.cov_start = []
        self.cov_names = []
        self.tp = []
        self.tf = []
        self.ts = []
        self.te = []
        self.tt = []
        self.causes = []
        self.cov = []
        self.fail_seen = []
        self.replayed = []
        self.req_skips = 0
        self.unrep_skips = 0
        self.se_pid = []
        self.se_msg = []
        self.se_input = []
        self.se_choices = []
        self.target = ""
        self.hit_message = ""
        self.hit_input = ""
        self.inv_source = []
        self.inv_value = []
        self.vkind = []
        self.vnote = []
        self.part_class = []
        self.defaulted = []
        self.explain_all = False
        self.focus = -1
        self.details = []
        self._plan(func.clauses.copy(), options)

    # Planning

    def _plan(mut self, clauses: List[Int], options: RunOptions) raises:
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var has_modifies = False
        for c in clauses:
            ref cl = spec.clauses[c]
            var k = cl.kind
            if k == .REQUIRES:
                self.requires.append(c)
            elif k == .ENSURES or k == .RELATES:
                self.infos.append(PropInfo(K_COND, c, cl.id.copy(), source_text(spec, cl.node), String(k), -1))
                if cl.expr != 0 and old_calls(spec, cl.expr):
                    self.old_clauses.append(c)
            elif k == .RAISES:
                self.infos.append(PropInfo(K_RAISES, c, cl.id.copy(), source_text(spec, cl.node), "raises", -1))
                self.cond_clauses.append(c)
            elif k == .MAY_RAISE:
                self.cond_clauses.append(c)
            elif k == .MODIFIES:
                has_modifies = True
                for n in cl.names:
                    self.modified.append(n)
                self.infos.append(PropInfo(K_MODIFIES, c, cl.id.copy(), source_text(spec, cl.node), "modifies", -1))
        var decl = func.decl_id
        self.infos.append(PropInfo(K_TYPE, -1, decl + "#type", String("built-in: the result of ", func.name, " reads as ", spec.types.text(self.rtype)), "type", -1))
        self.infos.append(PropInfo(K_ANY_RAISES, -1, decl + "#raises", String("built-in: ", func.name, " raises only what a raises or may_raise admits"), "raises", -1))
        # Handle parameters that the call may not change.
        var handles = [i for i in range(len(func.params)) if _is_handle(spec, self.ptypes[i])]
        self.checked = [i for i in handles if func.params[i].name not in self.modified]
        if (len(handles) > 0 or (self.stateful and func.receiver)) and not has_modifies:
            var names = "every live object" if self.stateful else ", ".join([func.params[i].name for i in self.checked])
            self.infos.append(PropInfo(K_FRAME, -1, decl + "#frame", String("built-in: ", func.name, " leaves ", names, " unchanged (no modifies clause)"), "frame", -1))
        # Invariants of the models the function returns or modifies.
        var models = List[String]()
        collect_models(spec.types, self.rtype, models)
        for i, param in enumerate(func.params):
            if param.name in self.modified:
                collect_models(spec.types, self.ptypes[i], models)
        for name in models:
            var m = spec.model_named(name)
            if m is None or self.stateful:
                continue
            for c in spec.models[m.value()].clauses:
                ref cl = spec.clauses[c]
                if cl.kind == .INVARIANT:
                    self.infos.append(PropInfo(K_INVARIANT, c, decl + ":" + cl.id, source_text(spec, cl.node), "invariant", m.value()))
        # Tallies.
        var n = len(self.infos)
        self.tp = [0 for _ in range(n)]
        self.tf = [0 for _ in range(n)]
        self.ts = [0 for _ in range(n)]
        self.te = [0 for _ in range(n)]
        self.tt = [0 for _ in range(n)]
        self.fail_seen = [False for _ in range(n)]
        self.replayed = [False for _ in range(n)]
        self.vkind = [V_PASS for _ in range(n)]
        self.vnote = [String() for _ in range(n)]
        self.details = [Detail() for _ in range(n)]
        self.causes = [0 for _ in range(n * N_CAUSES)]
        for part in func.partitions:
            self.cov_start.append(len(self.cov_names))
            self.cov_names += [String(func.params[part.param].name, ": ", cls.name) for cls in part.classes]
            self.part_class.append(-1)
        self.cov = [0 for _ in range(n * len(self.cov_names))]
        self.defaulted = [False for _ in func.params]
        # A domain small enough to run every input (a receiver is built, not enumerated).
        if not func.receiver:
            var size = product_size(spec.types, self.ptypes, limit=UInt64(options.exhaustive_limit))
            if size is not None:
                self.domain = size.value()

    def keys(self) -> List[String]:
        return [String(self.loaded[].hash, "/", info.id) for info in self.infos]

    # Drawing

    def draw(mut self, mut src: Source) raises -> List[Value]:
        ref spec = self.loaded[].spec
        if self.domain > 0:
            return values_at(spec.types, self.ptypes, src.draw_below(self.domain))
        var args = draw_args(src, spec, self.f, self.loaded[].sizes, self.host, self.tenv, True)
        if spec.fns[self.f].receiver:
            args[0] = draw_model(src, spec, spec.fns[self.f].owner, self.host, self.loaded[].sizes)
        for p in range(len(spec.fns[self.f].partitions)):
            self._steer(src, p, args)
        return args^

    def draw_stateful(mut self, mut src: Source) raises -> List[Value]:
        """The arguments of a constructor or method of an interface; a receiver is left
        as `not_drawn_marker` for the caller."""
        ref spec = self.loaded[].spec
        var args = draw_args(src, spec, self.f, self.loaded[].sizes, self.host, self.tenv, True)
        for p in range(len(spec.fns[self.f].partitions)):
            self._steer(src, p, args)
        return args^

    def _steer(mut self, mut src: Source, p: Int, mut args: List[Value]) raises:
        ref spec = self.loaded[].spec
        ref part = spec.fns[self.f].partitions[p]
        var i = part.param
        if is_default(args[i]) or is_not_drawn(args[i]):
            return
        var t = self.ptypes[i]
        var n = len(part.classes)
        if n == 0:
            return
        if not self.loaded[].sets.is_predicate(self.f, p, 0):
            var classes = [self.loaded[].sets.set_of(self.f, p, k) for k in range(n)]
            args[i] = draw_in_classes(src, self.loaded[].ctx, spec.types, classes, t)
            return
        if spec.types.kind(t) == ty.MODEL:
            return
        # A predicate class: pick a class (or none), then draw until a value is in it.
        var k = src.draw_choice(n + 1)
        if k >= n:
            return
        for _ in range(8):
            var v = draw_value(src, spec.types, t, self.loaded[].sizes, 0)
            var ok = False
            try:
                ok = class_holds(spec, part.classes[k].node, v, self.host)
            except:
                ok = False
            args[i] = v^
            if ok:
                break

    # Running one example

    def run(mut self, mut src: Source) raises -> Outcome:
        var counting = src.max_choices < SHRINK_SOURCE
        var args: List[Value]
        self.host.timed_out = False
        try:
            args = self.draw(src)
        except e:
            if self.host.take_timeout():
                return self._inconclusive_all(counting, List[Value]())
            if src.invalid and counting and src.extend:
                self.unrep_skips += 1
            raise e^
        var before = len(self.se_pid)
        if self.target:
            return self._examine_target(args^)
        var out = self.examine(args^, counting=counting, is_replay=counting and not src.extend)
        if counting:
            for k in range(before, len(self.se_pid)):
                self.se_choices[k] = src.rec.copy()
        return out^

    def _examine_target(mut self, var args: List[Value]) raises -> Outcome:
        """Judges an example while a spec error is shrunk: it fails when it raises the
        target error (up to the values in its message)."""
        var shown = args.copy()
        var out = self.examine(args^, counting=False, is_replay=False)
        if out.is_invalid:
            return out^
        for i in range(len(self.infos)):
            if self.vkind[i] == V_ERROR and error_shape(self.vnote[i]) == self.target:
                self.hit_message = self.vnote[i].copy()
                self.hit_input = self._inputs_text(shown)
                return Outcome.single(0, FAILED)
        return Outcome.single(0, PASSED)

    def run_fixed(mut self, var args: List[Value]) raises -> Outcome:
        """Judges explicit inputs; the counterexamples keep them as given."""
        self.explain_all = True
        var out = self.examine(args^, counting=True, is_replay=False)
        self.explain_all = False
        return out^

    def _spec_error_all(mut self, message: String, counting: Bool, args: List[Value]) -> Outcome:
        if self.host.take_timeout():
            return self._inconclusive_all(counting, args)
        var out = Outcome()
        for i in range(len(self.infos)):
            self.vkind[i] = V_ERROR
            self.vnote[i] = message.copy()
            out.add(i, SKIPPED)
        if counting:
            self._tally(args, False)
        return out^

    def _inconclusive_all(mut self, counting: Bool, args: List[Value]) -> Outcome:
        """The example judged nothing: a call ran past its time limit."""
        var out = Outcome()
        self.timed_out = True
        _ = self.host.take_timeout()
        for i in range(len(self.infos)):
            self.vkind[i] = V_TIMEOUT
            out.add(i, SKIPPED)
        if counting:
            self._tally(args, False)
        return out^

    def _note_spec_error(mut self, i: Int, message: String, args: List[Value]):
        var kept = List[String]()
        for k in range(len(self.se_pid)):
            if self.se_pid[k] == i:
                kept.append(self.se_msg[k].copy())
        if message in kept or len(kept) >= KEPT_SPEC_ERRORS:
            return
        self.se_pid.append(i)
        self.se_msg.append(message.copy())
        self.se_input.append(self._inputs_text(args))
        self.se_choices.append(Choices())

    def _inputs_text(mut self, args: List[Value]) -> String:
        ref func = self.loaded[].spec.fns[self.f]
        var shown = List[String]()
        for i in range(len(args)):
            shown.append(String(func.params[i].name, " = ", self.show(args[i], self.ptypes[i])))
        return ", ".join(shown) if len(shown) > 0 else "(no inputs)"

    def show(mut self, v: Value, t: Int) -> String:
        """A value for a counterexample: a handle by its observed fields."""
        try:
            if v.kind == .HANDLE:
                ref spec = self.loaded[].spec
                var m = spec.model_named(spec.types.info(t).name) if spec.types.kind(t) == ty.MODEL else Optional[Int]()
                if m:
                    var out = String(spec.models[m.value()].name, " { ")
                    var first = True
                    for oi in range(len(spec.models[m.value()].observers)):
                        if len(spec.models[m.value()].observers[oi].params) > 0:
                            continue
                        var got = self.host.observe(v, m.value(), oi, List[Value]())
                        out += ("" if first else ", ") + spec.models[m.value()].observers[oi].name + ": " + format_value(got)
                        first = False
                    return out + " }" if not first else format_value(v)
            return format_value(v)
        except:
            try:
                return format_value(v)
            except:
                return String("?")

    def _model_type(mut self, name: String) -> Int:
        """The handle type of the model called `name`."""
        var m = self.loaded[].spec.model_named(name)
        return self.loaded[].spec.models[m.value()].type if m is not None else 0

    def digest(mut self, v: Value, t: Int) raises -> Value:
        ref spec = self.loaded[].spec
        var m = spec.model_named(spec.types.info(t).name)
        var items = List[Value]()
        if m and v.kind == .HANDLE:
            for oi in range(len(spec.models[m.value()].observers)):
                if len(spec.models[m.value()].observers[oi].params) > 0:
                    continue
                items.append(self.host.observe(v, m.value(), oi, List[Value]()))
        return Value.list(items^)

    def classify(mut self, args: List[Value]):
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        for p in range(len(func.partitions)):
            ref part = func.partitions[p]
            var found = -1
            var t = self.ptypes[part.param]
            var v = args[part.param].copy()
            for k in range(len(part.classes)):
                var inside = False
                if self.loaded[].sets.is_predicate(self.f, p, k):
                    try:
                        inside = class_holds(spec, part.classes[k].node, v, self.host)
                    except:
                        inside = False
                else:
                    try:
                        inside = self.loaded[].ctx.contains(
                            self.loaded[].sets.set_of(self.f, p, k),
                            bits_of_value(spec.types, t, v),
                        )
                    except:
                        inside = False
                if inside:
                    found = k
                    break
            self.part_class[p] = found

    def map_error(self, err: Value) -> String:
        """The spec's name for a raised error: the nearest class of the error, then of
        its bases, that a `raises`, `may_raise` or `error` declaration names."""
        var names: List[String] = [norm_name(err.name())]
        names += [norm_name(err.item(i).text()) for i in range(err.item_count())]
        ref spec = self.loaded[].spec
        for name in names:
            for c in self.cond_clauses:
                if norm_name(spec.clauses[c].error) == name:
                    return spec.clauses[c].error.copy()
            for error in self.errors:
                if norm_name(error) == name:
                    return error.copy()
        return ""

    def examine(mut self, var args: List[Value], *, counting: Bool, is_replay: Bool) raises -> Outcome:
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var n = len(self.infos)
        self.timed_out = False
        for i in range(n):
            self.vkind[i] = V_PASS
            self.vnote[i] = String()
        # Defaults.
        for i in range(len(args)):
            self.defaulted[i] = False
            if is_default(args[i]):
                try:
                    args[i] = evaluate(spec, func.params[i].default, Env(), self.host)
                    self.defaulted[i] = True
                except e:
                    return self._spec_error_all(String("default of ", func.params[i].name, ": ", e), counting, args)
        self.host.begin_example(args)
        var env = Env(args.copy())
        for name, id in zip(self.host.tnames, self.host.tids):
            env.bind_type(name, id)
        # requires
        for c in self.requires:
            var j = judge(spec, c, env, self.host)
            if j.is_false():
                if counting:
                    self.req_skips += 1
                return Outcome.invalid()
            if not j.is_true():
                return self._spec_error_all(
                    String(spec.clauses[c].id, ": ", j.located_message(spec)),
                    counting,
                    args,
                )
        self.classify(args)
        if len(self.old_clauses) > 0:
            snapshot_olds(spec, self.old_clauses, env, self.host)
        # State before the call.
        var before = List[Value]()
        var digest_error = String()
        var input_text = List[String]()
        var explaining = self.explain_all or self.focus >= 0
        if explaining:
            # The inputs as they were before the call, which may change them.
            for p in range(len(args)):
                input_text.append(self.show(args[p], self.ptypes[p]))
        for i in self.checked:
            if i >= len(args) or args[i].kind != .HANDLE:
                before.append(Value.none())
                continue
            try:
                before.append(self.digest(args[i], self.ptypes[i]))
            except e:
                digest_error = String(e)
                before.append(Value.none())
        # The objects live in a stateful run, which the call may change only if it
        # modifies its receiver, and then only the receiver.
        var live_checked = List[Int]()
        var live_before = List[Value]()
        var own = False
        if self.stateful:
            self.live_text.clear()
            own = "self" in self.modified
            for k in range(len(self.live)):
                if own and len(args) > 0 and args[0].kind == .HANDLE and self.live[k].handle_id() == args[0].handle_id():
                    continue
                live_checked.append(k)
                try:
                    live_before.append(self.digest(self.live[k].copy(), self.iface))
                except e:
                    digest_error = String(e)
                    live_before.append(Value.none())
            if explaining:
                for k in range(len(self.live)):
                    self.live_text.append(self.show(self.live[k].copy(), self.iface))
        var conds = List[Int]()
        var cond_msg = List[String]()
        for c in self.cond_clauses:
            var j = judge(spec, c, env, self.host)
            if j.is_true():
                conds.append(1)
                cond_msg.append(String())
            elif j.is_false():
                conds.append(0)
                cond_msg.append(String())
            else:
                conds.append(-1)
                cond_msg.append(j.located_message(spec))
        # The call.
        var reply = self.host.call(self.f, args)
        if reply.kind == .ERROR and reply.name() == TIMEOUT:
            return self._inconclusive_all(counting, args)
        var raised = reply.kind == .ERROR
        self.last_ran = True
        self.last_reply = reply.copy()
        self.last_result = Value.none()
        self.last_ok = False
        var type_error = String()
        var has_type_error = False
        var result = Value.none()
        var mapped = String()
        if raised:
            mapped = self.map_error(reply)
        else:
            try:
                result = decode(reply, self.rtype, spec.types)
                if self.result_has_model:
                    self.host.track(result)
                env.set_result(result.copy())
                self.last_result = result.copy()
                self.last_ok = True
            except e:
                type_error = String(e)
                has_type_error = True
        # Which raises were due.
        var due = List[Int]()
        var must = List[String]()
        var may = List[String]()
        for k in range(len(self.cond_clauses)):
            if conds[k] == 1:
                ref cl = spec.clauses[self.cond_clauses[k]]
                if cl.kind == .RAISES:
                    due.append(k)
                    must.append(cl.error.copy())
                else:
                    may.append(cl.error.copy())
        var due_ids = String()
        var due_notes = String()
        if not raised:
            for k in due:
                var cl = spec.clauses[self.cond_clauses[k]].copy()
                due_ids += (", " if due_ids else "") + cl.id
                due_notes += String("\nnote: ", cl.id, " required ", cl.error, " on this input")
        # Changes to the handles that were not to be modified.
        var changed = String()
        var frame_ready = False
        # Verdicts.
        var changed_names = List[String]()
        for i in range(n):
            ref info = self.infos[i]
            var k = info.kind
            if k == K_COND:
                if raised:
                    self._skip(i, "raised")
                elif has_type_error:
                    self._skip(i, "wrong type")
                else:
                    self._judge_clause(i, info.clause, env, due_ids, due_notes)
            elif k == K_RAISES:
                self._raises_clause(i, info.clause, conds, cond_msg, raised, reply, mapped, must, may)
            elif k == K_ANY_RAISES:
                self._any_raises(i, raised, reply, mapped, must, may, conds, cond_msg)
            elif k == K_TYPE:
                self._type_verdict(i, raised, has_type_error, type_error, result, reply)
            elif k == K_MODIFIES or k == K_FRAME:
                if not frame_ready:
                    frame_ready = True
                    if digest_error:
                        changed = String("!") + digest_error
                    else:
                        for q in range(len(self.checked)):
                            var pi = self.checked[q]
                            if pi >= len(args) or args[pi].kind != .HANDLE:
                                continue
                            try:
                                var after = self.digest(args[pi], self.ptypes[pi])
                                if after != before[q]:
                                    changed_names.append(func.params[pi].name.copy())
                            except e:
                                changed = String("!") + String(e)
                    if not digest_error:
                        for q in range(len(live_checked)):
                            var lk = live_checked[q]
                            try:
                                var after = self.digest(self.live[lk].copy(), self.iface)
                                if after != live_before[q]:
                                    changed_names.append(self.live_names[lk].copy())
                            except e:
                                changed = String("!") + String(e)
                    if len(changed_names) > 0 and not changed:
                        for q in changed_names:
                            changed += (", " if changed else "") + q
                if changed.startswith("!"):
                    self._error(i, String("digest: ", String(changed[byte = 1 :])))
                elif changed:
                    var allowed = String()
                    for q in self.modified:
                        allowed += (", " if allowed else "") + q
                    if self.stateful:
                        allowed = String("self (", self.self_name, ")") if own else String()
                    self.vkind[i] = V_FAIL
                    self.vnote[i] = String("the call changed ", changed, ", but it may modify only ", allowed if allowed else String("nothing"))
            elif k == K_INVARIANT:
                self._invariant(i, info.clause, info.model, args, result, raised or has_type_error, due_ids, due_notes)
        # Tally and report.
        var out = Outcome()
        for i in range(n):
            var v = self.vkind[i]
            out.add(i, PASSED if v == V_PASS else (FAILED if v == V_FAIL else SKIPPED))
        if counting:
            self._tally(args, is_replay)
        if self.explain_all or self.focus >= 0:
            for i in range(n):
                if self.vkind[i] == V_FAIL and (self.explain_all or self.focus == i):
                    if self.explain_all and self.details[i].present:
                        continue
                    self._capture(
                        i, args, env, raised, reply, mapped, has_type_error, type_error, result,
                        conds, cond_msg, must, may, changed_names, input_text, due_notes,
                    )
        return out^

    def _skip(mut self, i: Int, cause: String):
        self.vkind[i] = V_SKIP
        self.vnote[i] = cause

    def _error(mut self, i: Int, message: String):
        self.vkind[i] = V_TIMEOUT if self.host.take_timeout() else V_ERROR
        self.vnote[i] = message

    def _judge_clause(
        mut self, i: Int, c: Int, env: Env, due_ids: String, due_notes: String
    ):
        ref spec = self.loaded[].spec
        var j = judge(spec, c, env, self.host)
        if j.is_true():
            return
        if j.is_false():
            self.vkind[i] = V_FAIL
            self.vnote[i] = String(spec.clauses[c].id, " is false", due_notes)
            return
        self._unjudged(i, j, due_ids)

    def _unjudged(mut self, i: Int, j: Judgment, due_ids: String):
        """A clause that is neither true nor false: skipped when a planned call or a due raise explains it."""
        if j.is_skip():
            self._skip(i, "planned call")
        elif due_ids:
            self._skip(i, "raise due")
        else:
            self._error(i, j.located_message(self.loaded[].spec))

    def _raises_clause(
        mut self,
        i: Int,
        c: Int,
        conds: List[Int],
        cond_msg: List[String],
        raised: Bool,
        reply: Value,
        mapped: String,
        must: List[String],
        may: List[String],
    ) raises:
        ref spec = self.loaded[].spec
        var k = self.cond_clauses.index(c)
        ref cl = spec.clauses[c]
        if conds[k] < 0:
            self._error(i, cond_msg[k])
            return
        var did = String("returned")
        if raised:
            did = String("raised ", reply.error_text())
        if conds[k] == 1:
            if raised and contains_name(must, mapped):
                return
            self.vkind[i] = V_FAIL
            self.vnote[i] = String(cl.error, " was due (", source_text(spec, cl.expr) if cl.expr != 0 else String("always"), " holds), but the call ", did)
            return
        if len(must) > 0:
            self._skip(i, "raise due")
            return
        if raised and mapped == cl.error and not contains_name(may, mapped):
            self.vkind[i] = V_FAIL
            self.vnote[i] = String("the call raised ", cl.error, " although ", source_text(spec, cl.expr) if cl.expr != 0 else String("always"), " is false")

    def _any_raises(
        mut self,
        i: Int,
        raised: Bool,
        reply: Value,
        mapped: String,
        must: List[String],
        may: List[String],
        conds: List[Int],
        cond_msg: List[String],
    ):
        if not raised:
            return
        ref spec = self.loaded[].spec
        if mapped == "":
            self.vkind[i] = V_FAIL
            self.vnote[i] = String("no raises or may_raise admits ", reply.error_text())
            return
        if contains_name(must, mapped) or contains_name(may, mapped):
            return
        if any([spec.clauses[c].kind == .RAISES and spec.clauses[c].error == mapped for c in self.cond_clauses]):
            return
        for k in range(len(self.cond_clauses)):
            ref cl = spec.clauses[self.cond_clauses[k]]
            if cl.kind == .MAY_RAISE and cl.error == mapped and conds[k] < 0:
                self._error(i, String(cl.id, ": ", cond_msg[k]))
                return
        self.vkind[i] = V_FAIL
        self.vnote[i] = String("no raises or may_raise admits ", mapped, " here")

    def _type_verdict(
        mut self,
        i: Int,
        raised: Bool,
        has_type_error: Bool,
        type_error: String,
        result: Value,
        reply: Value,
    ):
        ref spec = self.loaded[].spec
        if raised:
            self._skip(i, "raised")
            return
        if has_type_error:
            self.vkind[i] = V_FAIL
            self.vnote[i] = String("the result is not ", spec.types.text(self.rtype), ": ", type_error)
            return
        if not self.result_has_model:
            return
        var models = List[String]()
        collect_models(spec.types, self.rtype, models)
        for name in models:
            var m = spec.model_named(name)
            if m is None:
                continue
            var hs = List[Value]()
            handles_of(spec.types, result, self.rtype, name, hs)
            for h in hs:
                for oi in range(len(spec.models[m.value()].observers)):
                    if len(spec.models[m.value()].observers[oi].params) > 0:
                        continue
                    try:
                        _ = self.host.observe(h, m.value(), oi, List[Value]())
                    except e:
                        var text = String(e)
                        if "NotAValue" in text:
                            self.vkind[i] = V_FAIL
                            self.vnote[i] = String("the result is not ", spec.types.text(self.rtype), ": ", text)
                        else:
                            self._error(i, String("reading the result: ", text))
                        return

    def _invariant(
        mut self,
        i: Int,
        c: Int,
        model: Int,
        args: List[Value],
        result: Value,
        no_result: Bool,
        due_ids: String,
        due_notes: String,
    ):
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var name = spec.models[model].name.copy()
        var hs = List[Value]()
        var where = List[String]()
        if not no_result:
            var found = List[Value]()
            handles_of(spec.types, result, self.rtype, name, found)
            for h in found:
                hs.append(h.copy())
                where.append(String("result"))
        for p in range(len(func.params)):
            if func.params[p].name in self.modified:
                var found = List[Value]()
                handles_of(spec.types, args[p], self.ptypes[p], name, found)
                for h in found:
                    hs.append(h.copy())
                    where.append(func.params[p].name.copy())
        if len(hs) == 0:
            self._skip(i, "other")
            return
        for q in range(len(hs)):
            var env = Env()
            env.set_self(hs[q].copy())
            for name, id in zip(self.host.tnames, self.host.tids):
                env.bind_type(name, id)
            var j = judge(spec, c, env, self.host)
            if j.is_true():
                continue
            if j.is_false():
                self.vkind[i] = V_FAIL
                self.vnote[i] = String(spec.clauses[c].id, " is false on ", where[q], due_notes)
                if self.explain_all or self.focus == i:
                    self.inv_source.clear()
                    self.inv_value.clear()
                    self.inv_source.append(where[q].copy())
                    self.inv_value.append(self.show(hs[q], self._model_type(name)))
                    var pairs = explain(spec, c, env, self.host)
                    for pair in pairs:
                        self.inv_source.append(pair[0])
                        self.inv_value.append(pair[1])
                return
            self._unjudged(i, j, due_ids)
            return

    def _tally(mut self, args: List[Value], is_replay: Bool):
        var slots = len(self.cov_names)
        for i in range(len(self.infos)):
            var v = self.vkind[i]
            if v == V_PASS:
                self.tp[i] += 1
            elif v == V_FAIL:
                self.tf[i] += 1
                if not self.fail_seen[i]:
                    self.fail_seen[i] = True
                    if is_replay:
                        self.replayed[i] = True
            elif v == V_SKIP:
                self.ts[i] += 1
                self.causes[i * N_CAUSES + cause_index(self.vnote[i])] += 1
            elif v == V_TIMEOUT:
                self.tt[i] += 1
            else:
                self.te[i] += 1
                var message = self.vnote[i].copy()
                self._note_spec_error(i, message, args)
            if v == V_PASS or v == V_FAIL:
                for p in range(len(self.part_class)):
                    if self.part_class[p] >= 0:
                        self.cov[i * slots + self.cov_start[p] + self.part_class[p]] += 1

    def _capture(
        mut self,
        i: Int,
        args: List[Value],
        env: Env,
        raised: Bool,
        reply: Value,
        mapped: String,
        has_type_error: Bool,
        type_error: String,
        result: Value,
        conds: List[Int],
        cond_msg: List[String],
        must: List[String],
        may: List[String],
        changed_names: List[String],
        input_text: List[String],
        due_notes: String,
    ):
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var d = Counterexample()
        d.seed = self.seed
        for p in range(len(args)):
            d.input_names.append(func.params[p].name.copy())
            if self.defaulted[p]:
                d.input_values.append(String("default (", input_text[p], ")"))
            else:
                d.input_values.append(input_text[p].copy())
        # What the call did.
        var obs = String()
        if raised:
            obs = String("raised ", reply.error_text())
            if mapped:
                obs += String(" (maps to ", mapped, ")")
            else:
                obs += " (no spec error maps it)"
        elif has_type_error:
            obs = String("returned ", describe(reply), ", which is not ", spec.types.text(self.rtype), ": ", type_error)
        else:
            obs = String("result = ", self.show(result, self.rtype))
        # The state after the call of the handles it may modify.
        var afters = String()
        if not raised:
            for p in range(len(func.params)):
                if func.params[p].name in self.modified and args[p].kind == .HANDLE:
                    afters += String("\n", func.params[p].name, " after = ", self.show(args[p], self.ptypes[p]))
        if afters:
            if spec.types.kind(self.rtype) == ty.UNIT:
                obs = String(afters[byte = 1 :])
            else:
                obs += afters
        if self.infos[i].kind == K_COND or self.infos[i].kind == K_INVARIANT:
            var lines = due_notes.split("\n")
            for line in lines:
                if line.startswith("note: "):
                    obs += "\n" + String(line)
        if self.stateful and len(changed_names) > 0 and (self.infos[i].kind == K_MODIFIES or self.infos[i].kind == K_FRAME):
            for nm in changed_names:
                for k in range(len(self.live)):
                    if self.live_names[k] == nm and k < len(self.live_text):
                        obs += String("\n", nm, " before = ", self.live_text[k])
                        obs += String("\n", nm, " after  = ", self.show(self.live[k].copy(), self.iface))
        elif len(changed_names) > 0 and (self.infos[i].kind == K_MODIFIES or self.infos[i].kind == K_FRAME):
            for q in range(len(self.checked)):
                var pi = self.checked[q]
                for nm in changed_names:
                    if nm == func.params[pi].name:
                        obs += String("\n", nm, " before = ", input_text[pi])
                        obs += String("\n", nm, " after  = ", self.show(args[pi], self.ptypes[pi]))
        d.observation = obs^
        for p in range(len(self.part_class)):
            if self.part_class[p] >= 0:
                d.part_names.append(func.params[func.partitions[p].param].name.copy())
                d.part_classes.append(func.partitions[p].classes[self.part_class[p]].name.copy())
        var kind = self.infos[i].kind
        if kind == K_COND:
            var pairs = explain(spec, self.infos[i].clause, env, self.host)
            for q in pairs:
                d.expl_source.append(q[0])
                d.expl_value.append(q[1])
        elif kind == K_INVARIANT:
            d.expl_source = self.inv_source.copy()
            d.expl_value = self.inv_value.copy()
        elif kind == K_RAISES or kind == K_ANY_RAISES:
            for k in range(len(self.cond_clauses)):
                ref cl = spec.clauses[self.cond_clauses[k]]
                d.expl_source.append(String(cl.kind, " ", cl.error, " when ", source_text(spec, cl.expr) if cl.expr != 0 else String("true")))
                d.expl_value.append(String("true") if conds[k] == 1 else (String("false") if conds[k] == 0 else String("error: ", cond_msg[k])))
            d.expl_source.append("errors that must be raised (R)")
            d.expl_value.append(names_text(must))
            d.expl_source.append("errors that may be raised (M)")
            d.expl_value.append(names_text(may))
        d.reproduce = String("seed=", self.seed, " decl=", self.decl, " clause=", self.infos[i].id)
        self.details[i].present = True
        self.details[i].cx = d^


    def clause_result(self, i: Int, mode: String, failure: String) raises -> ClauseResult:
        """The counts of clause `i`; the caller adds the counterexample and the duration."""
        ref info = self.infos[i]
        var result = ClauseResult(info.id.copy(), info.text.copy(), info.label.copy(), self.decl.copy())
        result.instantiation_names = self.host.tnames.copy()
        result.instantiation_types = [self.loaded[].spec.types.text(t) for t in self.host.tids]
        result.mode = mode
        result.passed = self.tp[i]
        result.failed = self.tf[i]
        result.skipped = self.ts[i] + self.req_skips + self.unrep_skips
        result.spec_error = self.te[i]
        result.inconclusive = self.tt[i]
        if failure:
            result.spec_error += 1
            result.spec_errors.append(failure.copy())
        var slots = len(self.cov_names)
        result.coverage_names = self.cov_names.copy()
        result.coverage_counts = [self.cov[i * slots + s] for s in range(slots)]
        for q in range(N_CAUSES):
            var count = self.causes[i * N_CAUSES + q]
            count += self.req_skips if q == cause_index("requires") else 0
            count += self.unrep_skips if q == cause_index("unrepresentable") else 0
            if count > 0:
                result.skip_names.append(cause_name(q))
                result.skip_counts.append(count)
        for k in range(len(self.se_pid)):
            if self.se_pid[k] == i:
                result.spec_errors.append(String(self.se_msg[k], "\nexample: ", self.se_input[k]))
        return result^


# The driver of a run


def error_shape(message: String) -> String:
    """`message` with each number (and its minus sign) replaced by `#`, so errors that differ only in values share a shape."""
    var out = String()
    var in_number = False
    var bytes = message.as_bytes()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        if is_digit(b):
            if not in_number:
                out += "#"
            in_number = True
            continue
        var minus = b == ord("-") and not in_number and i + 1 < len(bytes) and is_digit(Int(bytes[i + 1]))
        if minus and (i == 0 or not is_word_char(Int(bytes[i - 1]))):
            continue
        in_number = False
        out += chr(b)
    return out^


def _shrink_spec_errors(
    mut prop: Prop, settings: Settings, seed: UInt64
) raises:
    """Shrinks the first example of each distinct spec error message, as a failure is
    shrunk, and reports the shrunk example and its message in place of the first."""
    var distinct = List[String]()
    for k in range(len(prop.se_msg)):
        if len(prop.se_choices[k].values) > 0 and prop.se_msg[k] not in distinct:
            distinct.append(prop.se_msg[k].copy())
    if len(distinct) == 0:
        return
    var budget = max(settings.max_shrink_steps // len(distinct), 200)
    var shrunk_msg = Dict[String, String]()
    var shrunk_input = Dict[String, String]()
    var keys = List[String]()
    var kept = List[Int]()
    for k in range(len(prop.se_msg)):
        var original = prop.se_msg[k].copy()
        if original not in shrunk_msg:
            shrunk_msg[original] = original.copy()
            shrunk_input[original] = prop.se_input[k].copy()
            if len(prop.se_choices[k].values) > 0:
                prop.target = error_shape(original)
                prop.hit_message = ""
                var first = prop.se_choices[k].copy()
                var shrunk = shrink(prop, first, 0, budget)
                var src = Source(seed, SHRINK_SOURCE)
                src.reset_replay(shrunk.values)
                try:
                    _ = prop.run(src)
                except e:
                    if not src.invalid:
                        prop.target = ""
                        raise e^
                if prop.hit_message:
                    shrunk_msg[original] = prop.hit_message.copy()
                    shrunk_input[original] = prop.hit_input.copy()
                prop.target = ""
        # Spec errors that shrank to one message are reported once.
        var key = String(prop.se_pid[k], "|", shrunk_msg[original])
        if key not in keys:
            keys.append(key^)
            kept.append(k)
    var pids = List[Int]()
    var messages = List[String]()
    var inputs = List[String]()
    for k in kept:
        pids.append(prop.se_pid[k])
        messages.append(shrunk_msg[prop.se_msg[k]].copy())
        inputs.append(shrunk_input[prop.se_msg[k]].copy())
    prop.se_pid = pids^
    prop.se_msg = messages^
    prop.se_input = inputs^
    prop.se_choices = List[Choices]()


def _declaration(spec: Spec, decl: String) raises -> Int:
    for i in range(len(spec.fns)):
        if spec.fns[i].decl_id == decl:
            return i
    for i in range(len(spec.fns)):
        if spec.fns[i].name == decl:
            return i
    raise Error(String("the spec has no declaration ", decl))


def _example_args(mut prop: Prop, ex: Value) raises -> List[Value]:
    """The inputs of an explicit example, read against the parameter types."""
    ref spec = prop.loaded[].spec
    ref func = spec.fns[prop.f]
    if ex.kind != .MAP:
        raise Error("an example is a map from parameter name to value")
    var args = List[Value]()
    var used = 0
    for i in range(len(func.params)):
        var found = -1
        for k in range(ex.count()):
            var key = ex.item(2 * k)
            if key.kind == .STRING and key.text() == func.params[i].name:
                found = k
        if found < 0:
            if func.params[i].default == 0:
                raise Error(String("the example has no value for ", func.params[i].name))
            args.append(default_marker())
            continue
        used += 1
        var v = ex.item(2 * found + 1)
        var shaped: Value
        try:
            shaped = decode(v, prop.ptypes[i], spec.types)
        except:
            shaped = decode(
                coerce_arg(spec.types, v, prop.ptypes[i], String("example ", func.params[i].name)),
                prop.ptypes[i],
                spec.types,
            )
        args.append(coerce_arg(spec.types, shaped, prop.ptypes[i], String("example ", func.params[i].name)))
    if used != ex.count():
        raise Error(String(func.decl_id, " has no parameter named by every key of the example"))
    return args^


def run(
    mut loaded: Loaded,
    decl: String,
    options: RunOptions,
    mut driver: DriverClient,
) raises -> RunResult:
    """Runs the declaration `decl`: all of its clauses in one search."""
    var started = perf_counter_ns()
    var f = _declaration(loaded.spec, decl)
    var prop = Prop(loaded, driver, f, options)
    var result = RunResult(prop.decl.copy())
    var seed = fnv(String(options.seed, ":", prop.decl))
    var settings = Settings()
    settings.seed = seed
    settings.max_examples = options.max_examples
    settings.max_shrink_steps = options.shrink_steps()
    prop.seed = Int(options.seed)
    var n = len(prop.infos)
    var res = SearchResult()
    var failure = String()
    try:
        # Explicit examples are judged first, as given.
        for ex in options.examples:
            var args = _example_args(prop, ex)
            _ = prop.run_fixed(args^)
        if prop.domain > 0:
            result.mode = "exhaustive"
            settings.max_exhaustive = Int(prop.domain)
            res = enumerate_all(prop, Int(prop.domain), settings)
        else:
            if options.store is not None:
                settings.store_dir = options.store.value()
                settings.keys = prop.keys()
            res = search(prop, settings)
        # The shrunk failures, replayed once to show what happened.
        for k in range(len(res.properties)):
            ref pr = res.properties[k]
            if not pr.failed or pr.id < 0 or pr.id >= n:
                continue
            if prop.details[pr.id].present:
                continue
            var src = Source(seed, SHRINK_SOURCE)
            src.reset_replay(pr.choices.values)
            prop.focus = pr.id
            try:
                _ = prop.run(src)
            except e:
                if not src.invalid:
                    raise e^
            prop.focus = -1
        _shrink_spec_errors(prop, settings, seed)
    except e:
        failure = String(e)
    if any(prop.replayed):
        result.mode = "replay"
    result.examples = res.examples
    result.invalid = res.invalid
    var elapsed = Float64(perf_counter_ns() - started) / 1e9
    for i in range(n):
        var c = prop.clause_result(i, "exhaustive" if prop.domain > 0 else "hypothesis", failure)
        if prop.details[i].present:
            c.counterexample = prop.details[i].cx.copy()
            c.failing_inputs = max(1, prop.tf[i])
        elif prop.tf[i] > 0:
            c.failing_inputs = prop.tf[i]
        c.replayed = prop.replayed[i]
        c.duration = elapsed
        result.clauses.append(c^)
    # Aggregate clauses are judged over their sets.
    if not failure:
        ref func = loaded.spec.fns[f]
        for ci in func.clauses:
            if loaded.spec.clauses[ci].kind == .AGGREGATE:
                result.clauses.append(run_aggregate(loaded.spec, loaded.ctx, prop.host, f, ci, options, seed))
    prop.host.release_all()
    result.seconds = Float64(perf_counter_ns() - started) / 1e9
    return result^
