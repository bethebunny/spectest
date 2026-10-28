"""Running an interface: generated sequences of constructor and method calls on live
objects, each call judged like a function call, the invariants checked on every live
object after each call.

`Machine` is the mcheck property. One example is a whole step sequence: `generate`
draws it from the choices (a program of `Step`s, which refer to the constructor step
that made their receiver), and `execute` runs it against the code under test. Each
constructor and method has a `Prop` (run/runner.mojo) that judges one call; the
invariants are judged here. A failing clause is shrunk by mcheck on the choices, then
by deleting steps and lowering constructor arguments, as v1 did, and the sequence is
stored for the next run."""

from std.time import perf_counter_ns

from spec import types as ty
from interpreter.api import explain, judge
from interpreter.env import Env
from interpreter.text import source_text
from host.draw.models import is_default, is_not_drawn
from mcheck.choices import Choices
from mcheck import property as mcheck
from mcheck.property import FAILED, PASSED, SKIPPED, Outcome, Property
from mcheck.search import search
from mcheck.source import Many, Source
from value.value import Value

from .driver import Driver
from .run_host import RunHost
from .load import Loaded
from .options import RunOptions
from .results import ClauseResult, Counterexample, RunResult
from .runner import KEPT_SPEC_ERRORS, SHRINK_SOURCE, Live, Prop
from .runner import run as run_function
from .stateful_store import ArgEdit, Stored, load_stored, save_stored
from .verdict import Tally, Verdict

comptime MAX_REPLAYS = 600
"""Runs of a sequence that minimizing may spend on one clause."""


@fieldwise_init
struct Step(Copyable):
    """One call of a program: a constructor (`target` -1) or a method on the object
    the constructor step `target` made. `sid` numbers the steps as generated."""

    var sid: Int
    var callable: Int
    var args: List[Value]
    var target: Int


def _without(program: List[Step], sid: Int) -> List[Step]:
    """The program without a step and every step on an object it made."""
    var removed: List[Int] = [sid]
    var out: List[Step] = []
    for step in program:
        if step.sid in removed or step.target in removed:
            removed.append(step.sid)
        else:
            out.append(step.copy())
    return out^


def _with_arg(program: List[Step], *, sid: Int, index: Int, value: Int) -> List[Step]:
    var out = program.copy()
    for ref step in out:
        if step.sid == sid:
            step.args[index] = Value.int(value)
    return out^


def _toward_zero(v: Int) -> List[Int]:
    """Smaller candidates for a nonzero integer: 0, half of it, one step closer."""
    var half = v // 2 if v > 0 else -((-v) // 2)
    var near = v - 1 if v > 0 else v + 1
    var out: List[Int] = [0]
    if half != 0:
        out.append(half)
    if near != 0 and near != half:
        out.append(near)
    return out^


struct Invariant(Movable):
    """An invariant of the interface, judged on every live object after each step."""

    var clause: Int
    var id: String
    var text: String
    var tally: Tally
    var errors: List[String]
    """The distinct spec errors it raised, at most KEPT_SPEC_ERRORS."""
    var detail: Optional[Counterexample]
    """What its failure showed in the last focus execution."""

    def __init__(out self, clause: Int, var id: String, var text: String):
        self.clause = clause
        self.id = id^
        self.text = text^
        self.tally = Tally()
        self.errors = []
        self.detail = None


@fieldwise_init
struct Found(Movable):
    """A failing program of one clause: the choices it was generated from and the
    program as shortened."""

    var choices: Choices
    var program: List[Step]
    var replayed: Bool


struct Machine[D: Driver](Property):
    """The property of an interface. Each clause of the run has a slot, the mcheck
    property id: the clauses of each constructor and method in turn, then the
    invariants."""

    var loaded: Pointer[Loaded, MutUntrackedOrigin]
    var name: String
    var prefix: String
    """The first letter of the interface's name, which names its objects in the steps."""
    var props: List[Prop[Self.D]]
    """One per constructor, then one per method."""
    var constructors: Int
    var first_slot: List[Int]
    """The slot of each callable's first clause."""
    var invariant_slot: Int
    """The slot of the first invariant."""
    var invariants: List[Invariant]
    var invariant_host: RunHost[Self.D]
    var steps: Int
    var max_handles: Int
    var seed: Int
    # One execution
    var outcomes: List[mcheck.Verdict]
    """Each slot's outcome over the steps so far: failed at any step, else passed at any."""
    var fail_step: Int
    var log: List[String]
    var replays: Int
    var fail_receiver: String
    var counterexamples: List[Optional[Counterexample]]
    """What each failing slot showed, steps included."""

    def __init__(
        out self,
        mut loaded: Loaded,
        mut client: Self.D,
        iface: Int,
        options: RunOptions,
    ) raises:
        self.loaded = Pointer(to=loaded).unsafe_origin_cast[MutUntrackedOrigin]()
        self.name = loaded.spec.models[iface].name.copy()
        var last = String(self.name[byte = self.name.rfind(".") + 1 :])
        self.prefix = String(last[byte=0:1]).lower() if last else "h"
        self.constructors = len(loaded.spec.models[iface].ctors)
        if self.constructors == 0:
            raise Error(t"{self.name} has no constructor: the run has no way to make an object")
        self.props = []
        self.first_slot = []
        var slots = 0
        for f in loaded.spec.models[iface].ctors + loaded.spec.models[iface].methods.copy():
            self.first_slot.append(slots)
            var prop = Prop(loaded, client, f, options, True)
            slots += len(prop.plan.infos)
            self.props.append(prop^)
        self.invariant_slot = slots
        self.invariants = []
        for c in loaded.spec.models[iface].clauses:
            ref cl = loaded.spec.clauses[c]
            if cl.kind == .INVARIANT:
                self.invariants.append(Invariant(c, cl.id.copy(), source_text(loaded.spec, cl.node)))
        self.invariant_host = RunHost(loaded, client)
        self.invariant_host.instantiation = self.props[0].host.instantiation.copy()
        self.steps = options.steps
        self.max_handles = options.max_handles
        self.seed = Int(options.seed)
        var total = slots + len(self.invariants)
        self.outcomes = List[mcheck.Verdict](length=total, fill=SKIPPED)
        self.fail_step = -1
        self.log = []
        self.replays = 0
        self.fail_receiver = ""
        self.counterexamples = [None for _ in range(total)]

    def slot_count(self) -> Int:
        return len(self.outcomes)

    def slot_id(self, slot: Int) -> String:
        """The id of the clause in `slot`."""
        if slot >= self.invariant_slot:
            return self.invariants[slot - self.invariant_slot].id.copy()
        var c = self._owner(slot)
        return self.props[c].plan.infos[slot - self.first_slot[c]].id.copy()

    def _owner(self, slot: Int) -> Int:
        """The callable whose clauses hold `slot`."""
        for c in reversed(range(len(self.props))):
            if self.first_slot[c] <= slot:
                return c
        return 0

    # Generation

    def generate(mut self, mut src: Source) raises -> List[Step]:
        var program: List[Step] = []
        var recent: List[Int] = []  # steps of the constructors whose objects are live, the one used last first
        var many = Many(1, self.steps, Float64(self.steps) / 2.0)
        var methods = len(self.props) - self.constructors
        while many.more(src):
            var callables: List[Int] = []
            if len(recent) < self.max_handles or methods == 0:
                callables += [c for c in range(self.constructors)]
            if recent:
                callables += [c for c in range(self.constructors, len(self.props))]
            var c = callables[src.draw_choice(len(callables))]
            var sid = len(program)
            var target = -1
            if c >= self.constructors:
                # Mostly the object used last.
                var pick = src.draw_choice(8) if src.draw_below(2) == 1 else 0
                target = recent.pop(pick % len(recent))
                recent.insert(0, target)
            var args = self.props[c].draw_stateful(src)
            self._small_ints(src, c, args)
            if c < self.constructors:
                recent.insert(0, sid)
            program.append(Step(sid, c, args^, target))
        return program^

    def _small_ints(mut self, mut src: Source, c: Int, mut args: List[Value]) raises:
        """An integer argument is 0 to 4 in magnitude three times in four."""
        ref types = self.loaded[].spec.types
        for i in range(len(args)):
            if is_default(args[i]) or is_not_drawn(args[i]):
                continue
            var t = self.props[c].param_types[i]
            var k = types.kind(t)
            if k != .INT and k != .FIXED_INT:
                continue
            if src.draw_below(4) == 3:
                continue
            var low = 0 if k == .FIXED_INT and not types.info(t).signed else -4
            args[i] = Value.int(src.draw_int(low, 4))

    def regenerate(mut self, choices: Choices) -> List[Step]:
        """The program a sequence of choices makes; empty when it no longer fits."""
        var src = Source(0, SHRINK_SOURCE)
        src.reset_replay(choices.values)
        try:
            return self.generate(src)
        except:
            return []

    # The property

    def run(mut self, mut src: Source) raises -> Outcome:
        var counting = src.max_choices < SHRINK_SOURCE
        var program = self.generate(src)
        return self.execute(program, counting=counting, is_replay=counting and not src.extend, focus=-1, want_log=False)

    # Execution

    def execute(
        mut self,
        program: List[Step],
        *,
        counting: Bool,
        is_replay: Bool,
        focus: Int,
        want_log: Bool,
    ) raises -> Outcome:
        """Runs a program. With `focus` (a slot), stops at the first step that fails that
        clause, noting its position in `fail_step`, and captures what the failure
        shows."""
        for ref outcome in self.outcomes:
            outcome = SKIPPED
        self.fail_step = -1
        self.log.clear()
        var focus_owner = self._owner(focus) if 0 <= focus < self.invariant_slot else -1
        for c in range(len(self.props)):
            self.props[c].focus = focus - self.first_slot[c] if c == focus_owner else -1
            if c == focus_owner:
                self.props[c].details[focus - self.first_slot[c]] = None
        if focus >= self.invariant_slot:
            self.invariants[focus - self.invariant_slot].detail = None
        var live: List[Live] = []
        var failure = String()
        try:
            for pos, step in enumerate(program):
                if self._step(step, pos, live, counting=counting, is_replay=is_replay, focus=focus, want_log=want_log):
                    break
        except e:
            failure = String(e)
        self.release()
        for c in range(len(self.props)):
            self.props[c].focus = -1
        if failure:
            raise Error(failure)
        var out = Outcome()
        for slot, outcome in enumerate(self.outcomes):
            out.add(slot, outcome)
        return out^

    def release(mut self):
        for c in range(len(self.props)):
            self.props[c].host.release_all()
        self.invariant_host.release_all()

    def _note(mut self, slot: Int, verdict: Verdict):
        match verdict:
            case .FAIL(_):
                self.outcomes[slot] = FAILED
            case .PASS:
                if self.outcomes[slot] != FAILED:
                    self.outcomes[slot] = PASSED
            case _:
                pass

    def _step(
        mut self,
        step: Step,
        pos: Int,
        mut live: List[Live],
        *,
        counting: Bool,
        is_replay: Bool,
        focus: Int,
        want_log: Bool,
    ) raises -> Bool:
        """Runs and judges one step; True when the run is to stop (a focus failure)."""
        var c = step.callable
        var args = step.args.copy()
        var receiver = String()
        if c >= self.constructors:
            var at = [obj.sid for obj in live].try_index(step.target)
            if at is None:
                return False
            args[0] = live[at.value()].handle.copy()
            receiver = live[at.value()].name.copy()
        self.props[c].live = live.copy()
        self.props[c].receiver = receiver.copy()
        var out = self.props[c].examine(args^, counting=counting, is_replay=is_replay)
        if out.is_invalid:
            return False
        var stop = False
        for i in range(len(self.props[c].plan.infos)):
            var verdict = self.props[c].verdicts[i]
            self._note(self.first_slot[c] + i, verdict)
            stop = stop or (verdict.failed() and focus == self.first_slot[c] + i)
        if self.props[c].timed_out:
            return True
        if self.props[c].last is None:
            return stop
        var reply = self.props[c].last.value().copy()
        var name = String()
        if c < self.constructors and reply.result is not None and reply.result.value().kind == .HANDLE:
            name = String(self.prefix, len(live) + 1)
        if want_log:
            self.log.append(self._call_text(step, receiver, name))
        if name:
            live.append(Live(reply.result.value().copy(), name^, step.sid))
        if self._invariants(live, counting, is_replay, focus):
            stop = True
        if stop:
            self.fail_step = pos
            self.fail_receiver = receiver^
        return stop

    def _call_text(mut self, step: Step, receiver: String, name: String) -> String:
        ref func = self.loaded[].spec.fns[self.props[step.callable].f]
        var shown: List[String] = []
        for i in range(1 if func.receiver else 0, len(step.args)):
            if not is_default(step.args[i]):
                var text = self.props[step.callable].show(step.args[i], self.props[step.callable].param_types[i])
                shown.append(String(func.params[i].name, "=", text))
        var is_ctor = step.callable < self.constructors
        var head: String
        if is_ctor:
            head = self.name.copy() if func.name == "__init__" else func.decl_id.copy()
        else:
            head = String(receiver, ".", func.name)
        var call = String(head, "(", ", ".join(shown), ")")
        var reply = self.props[step.callable].last.value().copy()
        if is_ctor and name:
            return String(name, " = ", call)
        if reply.value.kind == .ERROR:
            return String(call, " raised ", reply.value.error_text())
        ref prop = self.props[step.callable]
        if not is_ctor and reply.result is not None and self.loaded[].spec.types.kind(prop.result_type) != .UNIT:
            return String(call, " -> ", prop.show(reply.result.value(), prop.result_type))
        return call^

    def _invariants(mut self, live: List[Live], counting: Bool, is_replay: Bool, focus: Int) raises -> Bool:
        """Judges every invariant on every live object; True on a focus failure."""
        var stop = False
        for q in range(len(self.invariants)):
            var slot = self.invariant_slot + q
            var verdict = self._invariant(q, live, focus == slot)
            self._note(slot, verdict)
            if counting:
                ref invariant = self.invariants[q]
                invariant.tally.count(verdict, is_replay=is_replay)
                if case .ERROR(message) = verdict:
                    if message not in invariant.errors and len(invariant.errors) < KEPT_SPEC_ERRORS:
                        invariant.errors.append(message)
            stop = stop or (verdict.failed() and focus == slot)
        return stop

    def _invariant(mut self, q: Int, live: List[Live], capture: Bool) -> Verdict:
        if not live:
            return .SKIP(.OTHER)
        ref spec = self.loaded[].spec
        var c = self.invariants[q].clause
        self.invariant_host.begin_example([])
        for k in range(len(live)):
            var env = Env()
            env.set_self(live[k].handle.copy())
            self.invariant_host.bind_types(env)
            var j = judge(spec, c, env, self.invariant_host)
            if j.is_true():
                continue
            if j.is_false():
                if capture:
                    self._capture_invariant(q, live, k, env)
                return .FAIL(String(self.invariants[q].id, " is false on ", live[k].name))
            if j.is_skip():
                return .SKIP(.OTHER)
            var message = j.located_message(spec)
            if self.invariant_host.take_timeout():
                return .TIMEOUT
            return .ERROR(message)
        return .PASS

    def _capture_invariant(mut self, q: Int, live: List[Live], bad: Int, env: Env):
        var d = Counterexample()
        d.seed = self.seed
        for obj in live:
            d.inputs.append((obj.name.copy(), self.props[0].show(obj.handle, self.props[0].iface)))
        ref invariant = self.invariants[q]
        d.observation = String("after the last step, ", invariant.id, " is false on ", live[bad].name)
        d.explanation = explain(self.loaded[].spec, invariant.clause, env, self.invariant_host)
        d.reproduce = String("seed=", self.seed, " decl=", self.name, " clause=", invariant.id)
        self.invariants[q].detail = d^

    # Results

    def capture(mut self, slot: Int):
        """Keeps what the last (focus) execution showed for a failing clause."""
        var d: Counterexample
        var note = String()
        if slot >= self.invariant_slot:
            ref invariant = self.invariants[slot - self.invariant_slot]
            if invariant.detail is None:
                return
            d = invariant.detail.value().copy()
        else:
            var c = self._owner(slot)
            var local = slot - self.first_slot[c]
            ref prop = self.props[c]
            if prop.details[local] is None:
                return
            d = prop.details[local].value().copy()
            if prop.plan.infos[local].check != .TYPE:
                note = prop.verdicts[local].note()
            if c >= self.constructors and d.inputs and d.inputs[0][0] == "self":
                d.inputs[0] = ("self", String(self.fail_receiver, " = ", d.inputs[0][1]))
        var steps = String("steps:")
        for k, line in enumerate(self.log, start=1):
            steps += String("\n", k, ". ", line)
        d.observation = String(steps, "\n", d.observation, "\n" + note if note else String())
        self.counterexamples[slot] = d^

    def fill(self, mut result: RunResult, failure: String, elapsed: Float64):
        """One ClauseResult per clause of every constructor and method, then per
        invariant."""
        for c in range(len(self.props)):
            ref prop = self.props[c]
            for i in range(len(prop.plan.infos)):
                var clause = prop.clause_result(i, "stateful", failure, self.counterexamples[self.first_slot[c] + i].copy())
                clause.duration = elapsed
                result.clauses.append(clause^)
        for q in range(len(self.invariants)):
            ref invariant = self.invariants[q]
            var clause = ClauseResult(invariant.id.copy(), invariant.text.copy(), "invariant", self.name.copy())
            clause.instantiation = self.props[0].host.instantiation_text()
            clause.mode = "stateful"
            invariant.tally.fill(clause, self.counterexamples[self.invariant_slot + q].copy(), failure)
            clause.spec_errors += invariant.errors.copy()
            clause.duration = elapsed
            result.clauses.append(clause^)

    # Shrinking

    def fails(mut self, program: List[Step], slot: Int) raises -> Bool:
        self.replays += 1
        _ = self.execute(program, counting=False, is_replay=False, focus=slot, want_log=False)
        return self.fail_step >= 0

    def trimmed(self, program: List[Step]) -> List[Step]:
        """The program up to the step that failed the clause last executed."""
        return List(program[: self.fail_step + 1])

    def shorten(mut self, var program: List[Step], slot: Int) raises -> List[Step]:
        """Deletes steps, the last first, while the program still fails."""
        var improved = True
        while improved and self.replays < MAX_REPLAYS:
            improved = False
            for k in reversed(range(len(program))):
                var candidate = _without(program, program[k].sid)
                if len(candidate) < len(program) and self.fails(candidate, slot):
                    program = self.trimmed(candidate)
                    improved = True
                    break
        return program^

    def lower(mut self, program: List[Step], slot: Int) raises -> Optional[List[Step]]:
        """A program with one constructor argument smaller (the constructor's object
        may lose one call that filled it) that still fails the clause."""
        for step in program:
            if step.target >= 0:
                continue
            var dependents = [other.sid for other in program if other.target == step.sid]
            for j in range(len(step.args)):
                var small = step.args[j].small_int() if step.args[j].kind == .INT else None
                if small is None or small.value() == 0:
                    continue
                var v = small.value()
                for w in _toward_zero(v):
                    var lowered = _with_arg(program, sid=step.sid, index=j, value=w)
                    var tries: List[List[Step]] = [lowered.copy()]
                    if abs(v - w) == 1:
                        tries += [_without(lowered, d) for d in dependents]
                    for candidate in tries:
                        if self.replays >= MAX_REPLAYS:
                            return None
                        if self.fails(candidate, slot):
                            return self.trimmed(candidate)
        return None

    def minimize(mut self, var program: List[Step], slot: Int) raises -> List[Step]:
        if not self.fails(program, slot):
            return program^
        program = self.trimmed(program)
        program = self.shorten(program^, slot)
        while self.replays < MAX_REPLAYS:
            var lowered = self.lower(program, slot)
            if lowered is None:
                break
            program = self.shorten(lowered.take(), slot)
        return program^

    def stored_form(mut self, found: Found) -> Stored:
        """The edits that turn the program the choices generate into the found one."""
        var out = Stored()
        out.choices = found.choices.copy()
        var kept_sids = [step.sid for step in found.program]
        for step in self.regenerate(found.choices):
            var kept = kept_sids.try_index(step.sid)
            if kept is None:
                out.deleted.append(step.sid)
                continue
            ref args = found.program[kept.value()].args
            for j in range(len(step.args)):
                if args[j] != step.args[j] and args[j].small_int() is not None:
                    out.edits.append(ArgEdit(step.sid, j, args[j].small_int().value()))
        return out^

    def from_stored(mut self, stored: Stored) -> List[Step]:
        var out: List[Step] = []
        for step in self.regenerate(stored.choices):
            if step.sid in stored.deleted:
                continue
            var edited = step.copy()
            for edit in stored.edits:
                if edit.sid == step.sid and edit.index < len(edited.args):
                    edited.args[edit.index] = Value.int(edit.value)
            out.append(edited^)
        return out^


def apply_targets(mut loaded: Loaded):
    """A constructor named `__init__` calls the interface's class itself."""
    for m in range(len(loaded.spec.models)):
        if not loaded.spec.models[m].is_interface:
            continue
        for f in loaded.spec.models[m].ctors:
            if loaded.spec.fns[f].name == "__init__":
                loaded.spec.fns[f].target = loaded.spec.models[m].name.copy()


def interface_named(loaded: Loaded, decl: String) -> Optional[Int]:
    var m = loaded.spec.model_named(decl)
    return m if m is not None and loaded.spec.models[m.value()].is_interface else None


def run_interface[D: Driver](
    mut loaded: Loaded,
    iface: Int,
    options: RunOptions,
    mut driver: D,
) raises -> RunResult:
    """Runs the interface at position `iface` of the spec: all of its clauses in one
    search over step sequences."""
    var started = perf_counter_ns()
    apply_targets(loaded)
    var name = loaded.spec.models[iface].name.copy()
    var result = RunResult(name.copy())
    var m = Machine(loaded, driver, iface, options)
    var settings = options.settings(name)
    settings.max_choices = 1 << 20
    var n = m.slot_count()
    var found: List[Optional[Found]] = [None for _ in range(n)]
    var failure = String()
    try:
        if options.store is not None:
            for slot in range(n):
                var stored = load_stored(options.store.value(), options.store_key(loaded.hash, m.slot_id(slot)))
                if stored is None:
                    continue
                var program = m.from_stored(stored.value())
                if not program:
                    continue
                _ = m.execute(program, counting=True, is_replay=True, focus=-1, want_log=False)
                if m.outcomes[slot] == FAILED:
                    found[slot] = Found(stored.value().choices.copy(), program^, True)
                    result.mode = "replay"
        var res = search(m, settings)
        result.examples = res.examples
        result.invalid = res.invalid
        for pr in res.properties:
            if not pr.failed or not (0 <= pr.id < n) or found[pr.id] is not None:
                continue
            m.replays = 0
            var program = m.minimize(m.regenerate(pr.choices), pr.id)
            found[pr.id] = Found(pr.choices.copy(), program^, False)
            if options.store is not None:
                try:
                    save_stored(
                        options.store.value(),
                        options.store_key(loaded.hash, m.slot_id(pr.id)),
                        m.stored_form(found[pr.id].value()),
                    )
                except:
                    pass
        # What each failure shows.
        for slot in range(n):
            if found[slot] is not None:
                _ = m.execute(found[slot].value().program, counting=False, is_replay=False, focus=slot, want_log=True)
                m.capture(slot)
    except e:
        failure = String(e)
    m.fill(result, failure, Float64(perf_counter_ns() - started) / 1e9)
    m.release()
    result.seconds = Float64(perf_counter_ns() - started) / 1e9
    return result^


def run_declaration[D: Driver](
    mut loaded: Loaded,
    decl: String,
    options: RunOptions,
    mut driver: D,
) raises -> RunResult:
    """Runs a function, or an interface by its name: the entry point of the host API's
    `run`."""
    var iface = interface_named(loaded, decl)
    if iface is not None:
        return run_interface(loaded, iface.value(), options, driver)
    return run_function(loaded, decl, options, driver)
