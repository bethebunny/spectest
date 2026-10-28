"""Running one declaration: one search whose properties are all of its clauses.

`Prop` is the mcheck property: it draws the arguments of one example, applies
`requires`, snapshots `old`, calls the code under test through the driver and judges
every clause by the verdict table of docs/language.md. `run` drives it: explicit
examples first, then an exhaustive pass over a small domain or a search that replays
the stored failures, generates, and shrinks each failing clause on its own."""

from std.collections import Set
from std.time import perf_counter_ns

from interpreter.api import (
    Judgment,
    class_holds,
    evaluate,
    explain,
    judge,
    old_calls,
    snapshot_olds,
)
from interpreter.coerce import bits_of_value, coerce_arg
from interpreter.env import Env
from interpreter.text import source_text
from mcheck.choices import Choices
from mcheck.property import FAILED, PASSED, Outcome, Property, run_example
from mcheck.search import SearchResult, enumerate_all, search
from mcheck.settings import Settings
from mcheck.shrink import shrink
from mcheck.source import Source
from spec import types as ty
from spec.spec import Spec
from specfile.chars import is_digit, is_word_char
from value.text import format_value
from value.value import Value

from host.draw.classes import draw_in_classes
from host.draw.domain import product_size, values_at
from host.draw.models import (
    default_marker,
    draw_args,
    draw_model,
    is_default,
    is_not_drawn,
)
from host.draw.value import draw_value

from .aggregate import run_aggregate
from .decode import decode, describe
from .driver import Driver
from .load import Loaded
from .options import RunOptions
from .results import ClauseResult, Counterexample, RunResult
from .run_host import TIMEOUT, RunHost
from .util import (
    collect_models,
    contains_name,
    handles_of,
    invariant_models,
    is_handle,
    names_text,
    norm_name,
    parse_type,
    type_has_model,
)
from .verdict import Cause, Tally, Verdict


comptime SHRINK_SOURCE = 1 << 30
"""mcheck's shrinker replays through a source with this many choices at most; a
source with a smaller limit belongs to the search proper, whose examples are counted."""
comptime KEPT_SPEC_ERRORS = 20
comptime STEER_DRAWS = 8
"""Draws of a value for a predicate class before the last one is kept."""


def _undecided(j: Judgment) -> Bool:
    return j.is_error() or j.is_skip()


__enum Check(Equatable, ImplicitlyCopyable):
    """How the property judges a clause."""

    case CONDITION
    """An ensures or relates clause."""
    case RAISES
    case MODIFIES
    case TYPE
    """The built-in `#type`."""
    case ANY_RAISES
    """The built-in `#raises`."""
    case FRAME
    """The built-in `#frame`."""
    case INVARIANT
    """An invariant of a model the call returns or modifies."""

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()


@fieldwise_init
struct ClauseInfo(Copyable):
    var check: Check
    var clause: Int
    """Position in Spec.clauses, or -1 for a built-in."""
    var id: String
    var text: String
    var kind: String
    """The kind a result names: "ensures", "type", ..."""
    var model: Int
    """An invariant's model, a position in Spec.models."""


struct Plan(Defaultable, Movable):
    """What a run of one callable judges, and what its call may change."""

    var infos: List[ClauseInfo]
    var requires: List[Int]
    var conditions: List[Int]
    """The raises and may_raise clauses."""
    var old_clauses: List[Int]
    """The ensures and relates clauses that read `old`."""
    var modified: List[String]
    var checked: List[Int]
    """The handle parameters the call may not change."""
    var result_has_model: Bool
    var coverage_names: List[String]
    """Each partition class, as `param: class`."""
    var coverage_starts: List[Int]
    """Where each partition's classes start in `coverage_names`."""
    var domain: UInt64
    """The number of inputs when the domain is small enough to run all of them, else 0."""


def _plan(spec: Spec, f: Int, param_types: List[Int], result_type: Int, *, stateful: Bool, exhaustive_limit: Int) raises -> Plan:
    ref func = spec.fns[f]
    var plan = Plan()
    var modifies = False
    for c in func.clauses:
        ref cl = spec.clauses[c]
        match cl.kind:
            case .REQUIRES:
                plan.requires.append(c)
            case .ENSURES | .RELATES:
                plan.infos.append(ClauseInfo(.CONDITION, c, cl.id.copy(), source_text(spec, cl.node), String(cl.kind), -1))
                if cl.expr != 0 and old_calls(spec, cl.expr):
                    plan.old_clauses.append(c)
            case .RAISES:
                plan.infos.append(ClauseInfo(.RAISES, c, cl.id.copy(), source_text(spec, cl.node), "raises", -1))
                plan.conditions.append(c)
            case .MAY_RAISE:
                plan.conditions.append(c)
            case .MODIFIES:
                modifies = True
                plan.modified += cl.names.copy()
                plan.infos.append(ClauseInfo(.MODIFIES, c, cl.id.copy(), source_text(spec, cl.node), "modifies", -1))
            case _:
                pass
    var decl = func.decl_id
    plan.infos.append(ClauseInfo(.TYPE, -1, decl + "#type", String("built-in: the result of ", func.name, " reads as ", spec.types.text(result_type)), "type", -1))
    plan.infos.append(ClauseInfo(.ANY_RAISES, -1, decl + "#raises", String("built-in: ", func.name, " raises only what a raises or may_raise admits"), "raises", -1))
    var handles = [i for i, t in enumerate(param_types) if is_handle(spec.types, t)]
    plan.checked = [i for i in handles if func.params[i].name not in plan.modified]
    if (handles or (stateful and func.receiver)) and not modifies:
        var names = "every live object" if stateful else ", ".join([func.params[i].name for i in plan.checked])
        plan.infos.append(ClauseInfo(.FRAME, -1, decl + "#frame", String("built-in: ", func.name, " leaves ", names, " unchanged (no modifies clause)"), "frame", -1))
    # Invariants of the models the function returns or modifies; an interface's are
    # judged after every step instead.
    if not stateful:
        for m in invariant_models(spec, func, param_types, result_type, plan.modified):
            for c in spec.models[m].clauses:
                ref cl = spec.clauses[c]
                if cl.kind == .INVARIANT:
                    plan.infos.append(ClauseInfo(.INVARIANT, c, decl + ":" + cl.id, source_text(spec, cl.node), "invariant", m))
    plan.result_has_model = type_has_model(spec.types, result_type)
    for part in func.partitions:
        plan.coverage_starts.append(len(plan.coverage_names))
        plan.coverage_names += [String(func.params[part.param].name, ": ", cls.name) for cls in part.classes]
    # A receiver is built, not enumerated.
    if not func.receiver:
        plan.domain = product_size(spec.types, param_types, limit=UInt64(exhaustive_limit)).or_else(0)
    return plan^


@fieldwise_init
struct SpecError(Copyable):
    """A spec error one clause raised on an example."""

    var clause: Int
    """Position in the plan's infos."""
    var message: String
    var input: String
    var choices: Choices
    """The choices of the example; empty when not from a search."""


@fieldwise_init
struct Live(Copyable):
    """An object live in a stateful run: its handle, its name in the steps and the step
    that made it."""

    var handle: Value
    var name: String
    var sid: Int


@fieldwise_init
struct Reply(Copyable):
    """What a call returned, and the result it reads as when it does."""

    var value: Value
    var result: Optional[Value]


struct Call(Movable):
    """What one example's call did, and what its raises clauses said of it."""

    var reply: Value
    var raised: Bool
    var mapped: String
    """The spec's name for the error it raised."""
    var result: Value
    var type_error: Optional[String]
    """Why the reply doesn't read as the result type."""
    var conditions: List[Judgment]
    """Whether the `when` of each raises and may_raise clause holds."""
    var must: List[String]
    """The errors of the raises clauses that hold."""
    var may: List[String]
    """The errors of the may_raise clauses that hold."""
    var due_notes: String
    """A note per raise that was due when the call returned."""

    def __init__(out self, var reply: Value, var conditions: List[Judgment]):
        self.raised = reply.kind == .ERROR
        self.reply = reply^
        self.mapped = ""
        self.result = Value.none()
        self.type_error = None
        self.conditions = conditions^
        self.must = []
        self.may = []
        self.due_notes = ""

    def raise_due(self) -> Bool:
        return not self.raised and Bool(self.must)


struct Frame(Defaultable, Movable):
    """The objects a call may not change, digested before it."""

    var params: List[Value]
    """A digest per checked parameter (none for one that is not a handle)."""
    var live: List[Int]
    """The live objects other than a receiver the call may modify."""
    var live_digests: List[Value]
    var error: String
    """Why a digest failed, if one did."""


struct Changes(Copyable, Defaultable):
    """What the call changed that it may not."""

    var names: List[String]
    var error: Optional[String]
    """Why a digest failed, if one did."""


struct Prop[D: Driver](Movable, Property):
    """The property of one callable: draws an example's arguments, calls it through the
    driver and judges each clause of its plan."""

    var loaded: Pointer[Loaded, MutUntrackedOrigin]
    var host: RunHost[Self.D]
    var f: Int
    var decl: String
    var seed: Int
    var stateful: Bool
    """A constructor or method of an interface, judged against the objects live at its
    step (run/stateful.mojo)."""
    var iface: Int
    """The handle type of the interface, in a stateful run."""
    var type_args: List[Int]
    """The types of the declaration's type parameters, in order."""
    var param_types: List[Int]
    var result_type: Int
    var plan: Plan
    # Over the run
    var tallies: List[Tally]
    var spec_errors: List[SpecError]
    var details: List[Optional[Counterexample]]
    """What each failing clause showed, captured while a failing example is replayed."""
    var target: Optional[String]
    """While a spec error is shrunk, its shape: an example then fails when it raises that error."""
    var hit: Optional[SpecError]
    """The spec error of the target shape the last example raised."""
    # One example
    var verdicts: List[Verdict]
    var classes: List[Int]
    """The class of each partition the example is in, or -1."""
    var defaulted: List[Bool]
    var invariant_explanation: List[Tuple[String, String]]
    """The explanation of the invariant that failed."""
    var explain_all: Bool
    var focus: Int
    """The clause a replay explains, or -1."""
    # One step of a stateful run
    var live: List[Live]
    var live_before: List[String]
    """The live objects as shown before the call, while explaining."""
    var receiver: String
    """The name of the receiver."""
    var timed_out: Bool
    """Whether the last `examine` ended on a call past its time limit."""
    var last: Optional[Reply]
    """What the last `examine`'s call returned, if it made the call."""

    def __init__(
        out self,
        mut loaded: Loaded,
        mut client: Self.D,
        f: Int,
        options: RunOptions,
        stateful: Bool = False,
    ) raises:
        self.loaded = Pointer(to=loaded).unsafe_origin_cast[MutUntrackedOrigin]()
        self.host = RunHost(loaded, client)
        self.f = f
        self.seed = Int(options.seed)
        self.stateful = stateful
        self.iface = loaded.spec.models[loaded.spec.fns[f].owner].type if stateful else 0
        ref func = loaded.spec.fns[f]
        self.decl = func.decl_id.copy()
        self.type_args = []
        for tparam in func.tparams:
            var arg = options.instantiation.get(tparam)
            if arg is None:
                raise Error(t"{func.decl_id} is generic: the run needs a type for {tparam}")
            var t = parse_type(arg.value(), loaded.spec.types)
            self.type_args.append(t)
            self.host.instantiation[tparam] = t
        ref types = loaded.spec.types
        self.param_types = [types.substitute(p.type, func.tparams, self.type_args) if func.tparams else p.type for p in func.params]
        self.result_type = types.substitute(func.result, func.tparams, self.type_args) if func.tparams else func.result
        self.plan = _plan(loaded.spec, f, self.param_types, self.result_type, stateful=stateful, exhaustive_limit=options.exhaustive_limit)
        var n = len(self.plan.infos)
        self.tallies = [Tally(classes=len(self.plan.coverage_names)) for _ in range(n)]
        self.spec_errors = []
        self.details = [None for _ in range(n)]
        self.target = None
        self.hit = None
        self.verdicts = [Verdict.PASS for _ in range(n)]
        self.classes = [-1 for _ in func.partitions]
        self.defaulted = [False for _ in func.params]
        self.invariant_explanation = []
        self.explain_all = False
        self.focus = -1
        self.live = []
        self.live_before = []
        self.receiver = ""
        self.timed_out = False
        self.last = None

    # Drawing

    def draw(mut self, mut src: Source) raises -> List[Value]:
        if self.plan.domain == 0:
            return self._drawn(src, draw_receiver=True)
        return values_at(self.loaded[].spec.types, self.param_types, src.draw_below(self.plan.domain))

    def draw_stateful(mut self, mut src: Source) raises -> List[Value]:
        """The arguments of a constructor or method of an interface; a receiver is left
        as `not_drawn_marker` for the caller."""
        return self._drawn(src, draw_receiver=False)

    def _drawn(mut self, mut src: Source, *, draw_receiver: Bool) raises -> List[Value]:
        ref spec = self.loaded[].spec
        var args = draw_args(src, spec, self.f, self.loaded[].sizes, self.host, self.type_args, True)
        if draw_receiver and spec.fns[self.f].receiver:
            args[0] = draw_model(src, spec, spec.fns[self.f].owner, self.host, self.loaded[].sizes)
        for p in range(len(spec.fns[self.f].partitions)):
            self._steer(src, p, args)
        return args^

    def _steer(mut self, mut src: Source, p: Int, mut args: List[Value]) raises:
        """Draws the argument of partition `p` again inside one of its classes."""
        ref spec = self.loaded[].spec
        ref part = spec.fns[self.f].partitions[p]
        var i = part.param
        if is_default(args[i]) or is_not_drawn(args[i]) or not part.classes:
            return
        var t = self.param_types[i]
        if not self.loaded[].sets.is_predicate(self.f, p, 0):
            var classes = [self.loaded[].sets.set_of(self.f, p, k) for k in range(len(part.classes))]
            args[i] = draw_in_classes(src, self.loaded[].ctx, spec.types, classes, t)
            return
        if spec.types.kind(t) == .MODEL:
            return
        # A predicate class: pick a class (or none), then draw until a value is in it.
        var k = src.draw_choice(len(part.classes) + 1)
        if k >= len(part.classes):
            return
        for _ in range(STEER_DRAWS):
            var v = draw_value(src, spec.types, t, self.loaded[].sizes, 0)
            var inside: Bool
            try:
                inside = class_holds(spec, part.classes[k].node, v, self.host)
            except:
                inside = False
            args[i] = v^
            if inside:
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
                return self._inconclusive_all(counting, [])
            if src.invalid and counting and src.extend:
                self._skip_all(.UNREPRESENTABLE)
            raise e^
        var noted = len(self.spec_errors)
        if self.target is not None:
            return self._examine_target(args^)
        var out = self.examine(args^, counting=counting, is_replay=counting and not src.extend)
        if counting:
            for k in range(noted, len(self.spec_errors)):
                self.spec_errors[k].choices = src.rec.copy()
        return out^

    def _examine_target(mut self, var args: List[Value]) raises -> Outcome:
        """Judges an example while a spec error is shrunk: it fails when it raises the
        target error (up to the values in its message)."""
        var shown = args.copy()
        var out = self.examine(args^, counting=False, is_replay=False)
        if out.is_invalid:
            return out^
        for i in range(len(self.verdicts)):
            var verdict = self.verdicts[i]
            if case .ERROR(message) = verdict:
                if error_shape(message) == self.target.value():
                    self.hit = SpecError(i, message, self._inputs_text(shown), Choices())
                    return Outcome.single(0, FAILED)
        return Outcome.single(0, PASSED)

    def run_fixed(mut self, var args: List[Value]) raises -> Outcome:
        """Judges explicit inputs; the counterexamples keep them as given."""
        self.explain_all = True
        var out = self.examine(args^, counting=True, is_replay=False)
        self.explain_all = False
        return out^

    def _outcome(self) -> Outcome:
        var out = Outcome()
        for i, verdict in enumerate(self.verdicts):
            out.add(i, verdict.outcome())
        return out^

    def _skip_all(mut self, cause: Cause):
        """Counts a skip of every clause, for an example that judged none."""
        for ref tally in self.tallies:
            tally.count(.SKIP(cause), is_replay=False)

    def _spec_error_all(mut self, message: String, counting: Bool, args: List[Value]) -> Outcome:
        if self.host.take_timeout():
            return self._inconclusive_all(counting, args)
        for ref verdict in self.verdicts:
            verdict = .ERROR(message)
        if counting:
            self._tally(args, False)
        return self._outcome()

    def _inconclusive_all(mut self, counting: Bool, args: List[Value]) -> Outcome:
        """The example judged nothing: a call ran past its time limit."""
        self.timed_out = True
        _ = self.host.take_timeout()
        for ref verdict in self.verdicts:
            verdict = .TIMEOUT
        if counting:
            self._tally(args, False)
        return self._outcome()

    def _note_spec_error(mut self, i: Int, message: String, args: List[Value]):
        var noted = [e.message.copy() for e in self.spec_errors if e.clause == i]
        if message in noted or len(noted) >= KEPT_SPEC_ERRORS:
            return
        self.spec_errors.append(SpecError(i, message, self._inputs_text(args), Choices()))

    def _inputs_text(mut self, args: List[Value]) -> String:
        ref func = self.loaded[].spec.fns[self.f]
        var shown: List[String] = []
        for i in range(len(args)):
            shown.append(String(func.params[i].name, " = ", self.show(args[i], self.param_types[i])))
        return ", ".join(shown) if shown else "(no inputs)"

    def _fields(self, model: Int) -> List[Int]:
        """The observers of `model` that take no arguments."""
        return [i for i, o in enumerate(self.loaded[].spec.models[model].observers) if not o.params]

    def show(mut self, v: Value, t: Int) -> String:
        """A value for a counterexample: a handle by its observed fields."""
        try:
            ref spec = self.loaded[].spec
            if v.kind == .HANDLE and spec.types.kind(t) == .MODEL:
                if case .Some(m) = spec.model_named(spec.types.info(t).name):
                    var fields: List[String] = []
                    for o in self._fields(m):
                        var got = self.host.observe(v, m, o, [])
                        fields.append(String(spec.models[m].observers[o].name, ": ", format_value(got)))
                    if fields:
                        return String(spec.models[m].name, " { ", ", ".join(fields), " }")
            return format_value(v)
        except:
            try:
                return format_value(v)
            except:
                return "?"

    def digest(mut self, v: Value, t: Int) raises -> Value:
        """The observed fields of a handle, to tell whether a call changed it."""
        ref spec = self.loaded[].spec
        var items: List[Value] = []
        if v.kind == .HANDLE:
            if case .Some(m) = spec.model_named(spec.types.info(t).name):
                for o in self._fields(m):
                    items.append(self.host.observe(v, m, o, []))
        return Value.list(items^)

    def classify(mut self, args: List[Value]):
        ref func = self.loaded[].spec.fns[self.f]
        for p in range(len(func.partitions)):
            self.classes[p] = self._class_of(p, args[func.partitions[p].param])

    def _class_of(mut self, p: Int, v: Value) -> Int:
        """The first class of partition `p` that holds `v`, or -1."""
        ref spec = self.loaded[].spec
        ref part = spec.fns[self.f].partitions[p]
        var t = self.param_types[part.param]
        for k in range(len(part.classes)):
            var inside: Bool
            try:
                if self.loaded[].sets.is_predicate(self.f, p, k):
                    inside = class_holds(spec, part.classes[k].node, v, self.host)
                else:
                    inside = self.loaded[].ctx.contains(self.loaded[].sets.set_of(self.f, p, k), bits_of_value(spec.types, t, v))
            except:
                inside = False
            if inside:
                return k
        return -1

    def map_error(self, err: Value) -> String:
        """The spec's name for a raised error: the nearest class of the error, then of
        its bases, that a `raises`, `may_raise` or `error` declaration names."""
        ref spec = self.loaded[].spec
        var names: List[String] = [norm_name(err.name())]
        names += [norm_name(base.text()) for base in err.items()]
        for name in names:
            for c in self.plan.conditions:
                if norm_name(spec.clauses[c].error) == name:
                    return spec.clauses[c].error.copy()
            for error in spec.errors:
                if norm_name(error) == name:
                    return error.copy()
        return ""

    def examine(mut self, var args: List[Value], *, counting: Bool, is_replay: Bool) raises -> Outcome:
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        self.timed_out = False
        self.last = None
        for ref verdict in self.verdicts:
            verdict = .PASS
        self.defaulted = [is_default(a) for a in args]
        for i in range(len(args)):
            if self.defaulted[i]:
                try:
                    args[i] = evaluate(spec, func.params[i].default, Env(), self.host)
                except e:
                    return self._spec_error_all(String("default of ", func.params[i].name, ": ", e), counting, args)
        self.host.begin_example(args)
        var env = Env(args.copy())
        self.host.bind_types(env)
        for c in self.plan.requires:
            var j = judge(spec, c, env, self.host)
            if j.is_false():
                if counting:
                    self._skip_all(.REQUIRES)
                return Outcome.invalid()
            if not j.is_true():
                return self._spec_error_all(String(spec.clauses[c].id, ": ", j.located_message(spec)), counting, args)
        self.classify(args)
        if self.plan.old_clauses:
            snapshot_olds(spec, self.plan.old_clauses, env, self.host)
        var explaining = self.explain_all or self.focus >= 0
        var inputs_before: List[String] = []
        if explaining:
            # The inputs as they were before the call, which may change them.
            for i in range(len(args)):
                inputs_before.append(self.show(args[i], self.param_types[i]))
        var frame = self._frame(args, explaining)
        var conditions: List[Judgment] = []
        for c in self.plan.conditions:
            conditions.append(judge(spec, c, env, self.host))
        var reply = self.host.call(self.f, args)
        if reply.kind == .ERROR and reply.name() == TIMEOUT:
            return self._inconclusive_all(counting, args)
        var call = Call(reply^, conditions^)
        self.last = Reply(call.reply.copy(), None)
        if call.raised:
            call.mapped = self.map_error(call.reply)
        else:
            try:
                var result = decode(call.reply, self.result_type, spec.types)
                if self.plan.result_has_model:
                    self.host.track(result)
                env.set_result(result.copy())
                self.last = Reply(call.reply.copy(), result.copy())
                call.result = result^
            except e:
                call.type_error = String(e)
        for c, j in zip(self.plan.conditions, call.conditions):
            if not j.is_true():
                continue
            ref cl = spec.clauses[c]
            if cl.kind == .RAISES:
                call.must.append(cl.error.copy())
                if not call.raised:
                    call.due_notes += String("\nnote: ", cl.id, " required ", cl.error, " on this input")
            else:
                call.may.append(cl.error.copy())
        # The digests after the call, taken at the first clause that needs them.
        var changes: Optional[Changes] = None
        for i in range(len(self.plan.infos)):
            var verdict = self._verdict(i, args, env, call, frame, changes)
            self.verdicts[i] = verdict^
        var out = self._outcome()
        if counting:
            self._tally(args, is_replay)
        if explaining:
            var changed = changes.value().names.copy() if changes is not None else List[String]()
            for i in range(len(self.plan.infos)):
                if not self.verdicts[i].failed() or not (self.explain_all or self.focus == i):
                    continue
                if self.explain_all and self.details[i] is not None:
                    continue
                self._capture(i, args, env, call, changed, inputs_before)
        return out^

    def _frame(mut self, args: List[Value], explaining: Bool) -> Frame:
        var frame = Frame()
        for i in self.plan.checked:
            var digest = Value.none()
            if i < len(args) and args[i].kind == .HANDLE:
                try:
                    digest = self.digest(args[i], self.param_types[i])
                except e:
                    frame.error = String(e)
            frame.params.append(digest^)
        if not self.stateful:
            return frame^
        # The objects live in a stateful run, which the call may change only if it
        # modifies its receiver, and then only the receiver.
        self.live_before.clear()
        var own = "self" in self.plan.modified
        for k in range(len(self.live)):
            var handle = self.live[k].handle.copy()
            if own and args and args[0].kind == .HANDLE and handle.handle_id() == args[0].handle_id():
                continue
            frame.live.append(k)
            var digest = Value.none()
            try:
                digest = self.digest(handle, self.iface)
            except e:
                frame.error = String(e)
            frame.live_digests.append(digest^)
        if explaining:
            for k in range(len(self.live)):
                self.live_before.append(self.show(self.live[k].handle.copy(), self.iface))
        return frame^

    def _changes(mut self, args: List[Value], frame: Frame) -> Changes:
        var out = Changes()
        if frame.error:
            out.error = frame.error.copy()
            return out^
        ref func = self.loaded[].spec.fns[self.f]
        for i, before in zip(self.plan.checked, frame.params):
            if i >= len(args) or args[i].kind != .HANDLE:
                continue
            try:
                if self.digest(args[i], self.param_types[i]) != before:
                    out.names.append(func.params[i].name.copy())
            except e:
                out.error = String(e)
        for k, before in zip(frame.live, frame.live_digests):
            try:
                if self.digest(self.live[k].handle.copy(), self.iface) != before:
                    out.names.append(self.live[k].name.copy())
            except e:
                out.error = String(e)
        return out^

    def _verdict(
        mut self, i: Int, args: List[Value], env: Env, call: Call, frame: Frame, mut changes: Optional[Changes]
    ) raises -> Verdict:
        var check = self.plan.infos[i].check
        var clause = self.plan.infos[i].clause
        match check:
            case .CONDITION:
                if call.raised:
                    return .SKIP(.RAISED)
                if call.type_error is not None:
                    return .SKIP(.WRONG_TYPE)
                return self._condition(clause, env, call)
            case .RAISES:
                return self._raises(clause, call)
            case .ANY_RAISES:
                return self._any_raises(call)
            case .TYPE:
                return self._type_verdict(call)
            case .MODIFIES | .FRAME:
                if changes is None:
                    changes = self._changes(args, frame)
                return self._frame_verdict(changes.value())
            case .INVARIANT:
                return self._invariant(i, clause, self.plan.infos[i].model, args, call)

    def _error(mut self, message: String) -> Verdict:
        """A spec error, or nothing judged when a call ran past its time limit."""
        if self.host.take_timeout():
            return .TIMEOUT
        return .ERROR(message)

    def _unjudged(mut self, j: Judgment, call: Call) -> Verdict:
        """A clause that is neither true nor false: skipped when a planned call or a due raise explains it."""
        if j.is_skip():
            return .SKIP(.PLANNED_CALL)
        if call.raise_due():
            return .SKIP(.RAISE_DUE)
        return self._error(j.located_message(self.loaded[].spec))

    def _condition(mut self, c: Int, env: Env, call: Call) -> Verdict:
        ref spec = self.loaded[].spec
        var j = judge(spec, c, env, self.host)
        if j.is_true():
            return .PASS
        if j.is_false():
            return .FAIL(String(spec.clauses[c].id, " is false", call.due_notes))
        return self._unjudged(j, call)

    def _raises(mut self, c: Int, call: Call) raises -> Verdict:
        ref spec = self.loaded[].spec
        ref cl = spec.clauses[c]
        ref j = call.conditions[self.plan.conditions.index(c)]
        if _undecided(j):
            return self._error(j.located_message(spec))
        var when = source_text(spec, cl.expr) if cl.expr != 0 else String("always")
        if j.is_true():
            if call.raised and contains_name(call.must, call.mapped):
                return .PASS
            var did = String("raised ", call.reply.error_text()) if call.raised else String("returned")
            return .FAIL(String(cl.error, " was due (", when, " holds), but the call ", did))
        if call.must:
            return .SKIP(.RAISE_DUE)
        if call.raised and call.mapped == cl.error and not contains_name(call.may, call.mapped):
            return .FAIL(String("the call raised ", cl.error, " although ", when, " is false"))
        return .PASS

    def _any_raises(mut self, call: Call) -> Verdict:
        if not call.raised:
            return .PASS
        if call.mapped == "":
            return .FAIL(String("no raises or may_raise admits ", call.reply.error_text()))
        if contains_name(call.must, call.mapped) or contains_name(call.may, call.mapped):
            return .PASS
        ref spec = self.loaded[].spec
        if any([spec.clauses[c].kind == .RAISES and spec.clauses[c].error == call.mapped for c in self.plan.conditions]):
            return .PASS
        for c, j in zip(self.plan.conditions, call.conditions):
            ref cl = spec.clauses[c]
            if cl.kind == .MAY_RAISE and cl.error == call.mapped and _undecided(j):
                return self._error(String(cl.id, ": ", j.located_message(spec)))
        return .FAIL(String("no raises or may_raise admits ", call.mapped, " here"))

    def _type_verdict(mut self, call: Call) -> Verdict:
        ref spec = self.loaded[].spec
        if call.raised:
            return .SKIP(.RAISED)
        if call.type_error is not None:
            return .FAIL(String("the result is not ", spec.types.text(self.result_type), ": ", call.type_error.value()))
        if not self.plan.result_has_model:
            return .PASS
        var models: List[String] = []
        collect_models(spec.types, self.result_type, models)
        for name in models:
            var m = spec.model_named(name)
            if m is None:
                continue
            for handle in handles_of(spec.types, call.result, self.result_type, name):
                for o in self._fields(m.value()):
                    try:
                        _ = self.host.observe(handle, m.value(), o, [])
                    except e:
                        var text = String(e)
                        if "NotAValue" in text:
                            return .FAIL(String("the result is not ", spec.types.text(self.result_type), ": ", text))
                        return self._error(String("reading the result: ", text))
        return .PASS

    def _frame_verdict(mut self, changes: Changes) -> Verdict:
        if changes.error is not None:
            return self._error(String("digest: ", changes.error.value()))
        if not changes.names:
            return .PASS
        var allowed = ", ".join(self.plan.modified)
        if self.stateful:
            allowed = String("self (", self.receiver, ")") if "self" in self.plan.modified else String()
        return .FAIL(String("the call changed ", ", ".join(changes.names), ", but it may modify only ", allowed if allowed else String("nothing")))

    def _invariant(mut self, i: Int, c: Int, model: Int, args: List[Value], call: Call) -> Verdict:
        """Judges an invariant on the handles of its model the call returned or modified."""
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        ref name = spec.models[model].name
        var handles: List[Tuple[Value, String]] = []
        if not call.raised and call.type_error is None:
            for handle in handles_of(spec.types, call.result, self.result_type, name):
                handles.append((handle.copy(), String("result")))
        for p, param in enumerate(func.params):
            if param.name in self.plan.modified:
                for handle in handles_of(spec.types, args[p], self.param_types[p], name):
                    handles.append((handle.copy(), param.name.copy()))
        if not handles:
            return .SKIP(.OTHER)
        for handle, where in handles:
            var env = Env()
            env.set_self(handle.copy())
            self.host.bind_types(env)
            var j = judge(spec, c, env, self.host)
            if j.is_true():
                continue
            if not j.is_false():
                return self._unjudged(j, call)
            if self.explain_all or self.focus == i:
                self.invariant_explanation = [(where.copy(), self.show(handle, spec.models[model].type))]
                self.invariant_explanation += explain(spec, c, env, self.host)
            return .FAIL(String(spec.clauses[c].id, " is false on ", where, call.due_notes))
        return .PASS

    def _tally(mut self, args: List[Value], is_replay: Bool):
        var covered = [self.plan.coverage_starts[p] + k for p, k in enumerate(self.classes) if k >= 0]
        for i in range(len(self.plan.infos)):
            var verdict = self.verdicts[i]
            self.tallies[i].count(verdict, is_replay=is_replay)
            match verdict:
                case .PASS | .FAIL(_):
                    for slot in covered:
                        self.tallies[i].coverage[slot] += 1
                case .ERROR(message):
                    self._note_spec_error(i, message, args)
                case _:
                    pass

    def _capture(
        mut self,
        i: Int,
        args: List[Value],
        env: Env,
        call: Call,
        changed: List[String],
        inputs_before: List[String],
    ):
        """Keeps what the failure of clause `i` on this example shows."""
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var check = self.plan.infos[i].check
        var d = Counterexample()
        d.seed = self.seed
        for p in range(len(args)):
            d.inputs.append((func.params[p].name.copy(), String("default (", inputs_before[p], ")") if self.defaulted[p] else inputs_before[p].copy()))
        # What the call did.
        var observation: String
        if call.raised:
            var maps = String(" (maps to ", call.mapped, ")") if call.mapped else String(" (no spec error maps it)")
            observation = String("raised ", call.reply.error_text(), maps)
        elif call.type_error is not None:
            observation = String("returned ", describe(call.reply), ", which is not ", spec.types.text(self.result_type), ": ", call.type_error.value())
        else:
            observation = String("result = ", self.show(call.result, self.result_type))
        # The state after the call of the handles it may modify.
        var afters = String()
        if not call.raised:
            for p in range(len(func.params)):
                if func.params[p].name in self.plan.modified and args[p].kind == .HANDLE:
                    afters += String("\n", func.params[p].name, " after = ", self.show(args[p], self.param_types[p]))
        if afters:
            if spec.types.kind(self.result_type) == .UNIT:
                observation = String(afters[byte=1:])
            else:
                observation += afters
        match check:
            case .CONDITION | .INVARIANT:
                for line in call.due_notes.split("\n"):
                    if line.startswith("note: "):
                        observation += "\n" + String(line)
            case .MODIFIES | .FRAME:
                if self.stateful:
                    for name in changed:
                        for k in range(min(len(self.live), len(self.live_before))):
                            if self.live[k].name == name:
                                observation += String("\n", name, " before = ", self.live_before[k])
                                observation += String("\n", name, " after  = ", self.show(self.live[k].handle.copy(), self.iface))
                else:
                    for p in self.plan.checked:
                        if func.params[p].name in changed:
                            observation += String("\n", func.params[p].name, " before = ", inputs_before[p])
                            observation += String("\n", func.params[p].name, " after  = ", self.show(args[p], self.param_types[p]))
            case _:
                pass
        d.observation = observation^
        for p, k in enumerate(self.classes):
            if k >= 0:
                ref part = func.partitions[p]
                d.partitions.append((func.params[part.param].name.copy(), part.classes[k].name.copy()))
        match check:
            case .CONDITION:
                d.explanation = explain(spec, self.plan.infos[i].clause, env, self.host)
            case .INVARIANT:
                d.explanation = self.invariant_explanation.copy()
            case .RAISES | .ANY_RAISES:
                for c, j in zip(self.plan.conditions, call.conditions):
                    ref cl = spec.clauses[c]
                    var when = source_text(spec, cl.expr) if cl.expr != 0 else String("true")
                    var holds = String("true") if j.is_true() else String("false") if j.is_false() else String("error: ", j.located_message(spec))
                    d.explanation.append((String(cl.kind, " ", cl.error, " when ", when), holds))
                d.explanation.append(("errors that must be raised (R)", names_text(call.must)))
                d.explanation.append(("errors that may be raised (M)", names_text(call.may)))
            case _:
                pass
        d.reproduce = String("seed=", self.seed, " decl=", self.decl, " clause=", self.plan.infos[i].id)
        self.details[i] = d^

    def clause_result(self, i: Int, mode: String, failure: String, var counterexample: Optional[Counterexample]) -> ClauseResult:
        """The result of clause `i`; the caller adds the duration."""
        ref info = self.plan.infos[i]
        var result = ClauseResult(info.id.copy(), info.text.copy(), info.kind.copy(), self.decl.copy())
        result.instantiation = self.host.instantiation_text()
        result.mode = mode
        self.tallies[i].fill(result, counterexample^, failure)
        result.coverage = [(name.copy(), count) for name, count in zip(self.plan.coverage_names, self.tallies[i].coverage)]
        result.spec_errors += [String(e.message, "\nexample: ", e.input) for e in self.spec_errors if e.clause == i]
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


def _replay(mut prop: Prop[_], choices: Choices, seed: UInt64) raises:
    """Runs the example `choices` make again; one that is no longer valid is passed over."""
    var src = Source(seed, SHRINK_SOURCE)
    src.reset_replay(choices.values)
    _ = run_example(prop, src)


def _shrink_spec_errors(mut prop: Prop[_], settings: Settings) raises:
    """Shrinks the first example of each distinct spec error message, as a failure is
    shrunk, and reports the shrunk example and its message in place of the first."""
    var distinct = len(Set([e.message.copy() for e in prop.spec_errors if e.choices.values]))
    if distinct == 0:
        return
    var budget = max(settings.max_shrink_steps // distinct, 200)
    var shrunk: Dict[String, SpecError] = {}
    for k in range(len(prop.spec_errors)):
        var first = prop.spec_errors[k].copy()
        if first.message in shrunk:
            continue
        if first.choices.values:
            prop.target = error_shape(first.message)
            prop.hit = None
            _replay(prop, shrink(prop, first.choices, 0, budget), settings.seed)
            if prop.hit is not None:
                first = prop.hit.value().copy()
            prop.target = None
        shrunk[prop.spec_errors[k].message] = first^
    # Spec errors that shrank to one message are reported once.
    var reported = Set[String]()
    var kept: List[SpecError] = []
    for e in prop.spec_errors:
        ref s = shrunk[e.message]
        var key = String(e.clause, "|", s.message)
        if key not in reported:
            reported.add(key^)
            kept.append(SpecError(e.clause, s.message.copy(), s.input.copy(), Choices()))
    prop.spec_errors = kept^


def _declaration(spec: Spec, decl: String) raises -> Int:
    for i, func in enumerate(spec.fns):
        if func.decl_id == decl:
            return i
    if case .Some(f) = spec.fn_named(decl):
        return f
    raise Error(t"the spec has no declaration {decl}")


def _given(example: Value, name: String) -> Optional[Value]:
    """The value an example map gives the parameter `name`."""
    for key, value in example.pairs():
        if key.kind == .STRING and key.text() == name:
            return value.copy()
    return None


def _example_args(prop: Prop[_], example: Value) raises -> List[Value]:
    """The inputs of an explicit example, read against the parameter types."""
    ref spec = prop.loaded[].spec
    ref func = spec.fns[prop.f]
    if example.kind != .MAP:
        raise Error("an example is a map from parameter name to value")
    var args: List[Value] = []
    var used = 0
    for param, t in zip(func.params, prop.param_types):
        var given = _given(example, param.name)
        if given is None:
            if param.default == 0:
                raise Error(t"the example has no value for {param.name}")
            args.append(default_marker())
            continue
        used += 1
        var what = String("example ", param.name)
        var shaped: Value
        try:
            shaped = decode(given.value(), t, spec.types)
        except:
            shaped = decode(coerce_arg(spec.types, given.value(), t, what), t, spec.types)
        args.append(coerce_arg(spec.types, shaped, t, what))
    if used != example.count():
        raise Error(t"{func.decl_id} has no parameter named by every key of the example")
    return args^


def run[D: Driver](
    mut loaded: Loaded,
    decl: String,
    options: RunOptions,
    mut driver: D,
) raises -> RunResult:
    """Runs the declaration `decl`: all of its clauses in one search."""
    var started = perf_counter_ns()
    var f = _declaration(loaded.spec, decl)
    var prop = Prop(loaded, driver, f, options)
    var result = RunResult(prop.decl.copy())
    var settings = options.settings(prop.decl)
    var n = len(prop.plan.infos)
    var res = SearchResult()
    var failure = String()
    try:
        # Explicit examples are judged first, as given.
        for example in options.examples:
            _ = prop.run_fixed(_example_args(prop, example))
        if prop.plan.domain > 0:
            result.mode = "exhaustive"
            settings.max_exhaustive = Int(prop.plan.domain)
            res = enumerate_all(prop, Int(prop.plan.domain), settings)
        else:
            if options.store is not None:
                settings.store_dir = options.store.value()
                settings.keys = [options.store_key(loaded.hash, info.id) for info in prop.plan.infos]
            res = search(prop, settings)
        # The shrunk failures, replayed once to show what happened.
        for found in res.properties:
            if not found.failed or not (0 <= found.id < n) or prop.details[found.id] is not None:
                continue
            prop.focus = found.id
            _replay(prop, found.choices, settings.seed)
            prop.focus = -1
        _shrink_spec_errors(prop, settings)
    except e:
        failure = String(e)
    if any([tally.replayed for tally in prop.tallies]):
        result.mode = "replay"
    result.examples = res.examples
    result.invalid = res.invalid
    var elapsed = Float64(perf_counter_ns() - started) / 1e9
    var mode = "exhaustive" if prop.plan.domain > 0 else "hypothesis"
    for i in range(n):
        var clause = prop.clause_result(i, mode, failure, prop.details[i].copy())
        clause.duration = elapsed
        result.clauses.append(clause^)
    # Aggregate clauses are judged over their sets.
    if not failure:
        for c in loaded.spec.fns[f].clauses:
            if loaded.spec.clauses[c].kind == .AGGREGATE:
                result.clauses.append(run_aggregate(loaded.spec, loaded.ctx, prop.host, f, c, options, settings.seed))
    prop.host.release_all()
    result.seconds = Float64(perf_counter_ns() - started) / 1e9
    return result^
