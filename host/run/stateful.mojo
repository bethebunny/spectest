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

from bridge.client import DriverClient
from check import types as ty
from eval.api import explain, judge
from eval.env import Env
from eval.text import located, source_text
from gen.models import is_default, is_not_drawn
from mcheck.choices import Choices
from mcheck.property import FAILED, PASSED, SKIPPED, Outcome, Property
from mcheck.search import SearchResult, search
from mcheck.settings import Settings
from mcheck.source import Many, Source
from syntax import ast
from wire.value import ERROR, HANDLE, INT, Value

from .host import RunHost
from .load import Loaded, fnv
from .options import RunOptions
from .results import ClauseResult, Counterexample, RunResult
from .runner import run as run_function
from .runner import (
    K_TYPE,
    KEPT_SPEC_ERRORS,
    SHRINK_SOURCE,
    V_ERROR,
    V_FAIL,
    V_PASS,
    V_SKIP,
    Detail,
    Prop,
)
from .stateful_store import Stored, load_stored, save_stored
from .util import N_CAUSES, cause_index, cause_name

comptime UNSET = -1
comptime MAX_REPLAYS = 600
"""Runs of a sequence that minimizing may spend on one clause."""


struct Step(Copyable, Movable):
    """One call of a program: a constructor (`target` -1) or a method on the object
    the constructor step `target` made. `sid` numbers the steps as generated."""

    var sid: Int
    var callable: Int
    var args: List[Value]
    var target: Int

    def __init__(out self, sid: Int, callable: Int, var args: List[Value], target: Int):
        self.sid = sid
        self.callable = callable
        self.args = args^
        self.target = target


def _without(program: List[Step], sid: Int) -> List[Step]:
    """The program without a step and every step on an object it made."""
    var removed = List[Int]()
    removed.append(sid)
    var out = List[Step]()
    for step in program:
        var gone = False
        for r in removed:
            if r == step.sid or r == step.target:
                gone = True
        if gone:
            removed.append(step.sid)
        else:
            out.append(step.copy())
    return out^


def _with_arg(program: List[Step], sid: Int, index: Int, value: Int) -> List[Step]:
    var out = List[Step]()
    for step in program:
        var copy = step.copy()
        if step.sid == sid:
            copy.args[index] = Value.int(value)
        out.append(copy^)
    return out^


def _toward_zero(v: Int) -> List[Int]:
    """Smaller candidates for a nonzero integer: 0, half of it, one step closer."""
    var out = List[Int]()
    out.append(0)
    var half = v // 2 if v > 0 else -((-v) // 2)
    var near = v - 1 if v > 0 else v + 1
    if half != 0:
        out.append(half)
    if near != 0 and near != half:
        out.append(near)
    return out^


struct InvTally(Movable):
    var clause: Int
    var model: Int
    var id: String
    var text: String
    var tp: Int
    var tf: Int
    var ts: Int
    var te: Int
    var fail_seen: Bool
    var replayed: Bool
    var errors: List[String]
    var detail: Detail

    def __init__(out self, clause: Int, model: Int, var id: String, var text: String):
        self.clause = clause
        self.model = model
        self.id = id^
        self.text = text^
        self.tp = 0
        self.tf = 0
        self.ts = 0
        self.te = 0
        self.fail_seen = False
        self.replayed = False
        self.errors = List[String]()
        self.detail = Detail()


struct Found(Movable):
    """A failing program of one clause: the choices it was generated from and the
    program as shortened."""

    var gid: Int
    var choices: Choices
    var program: List[Step]
    var replayed: Bool

    def __init__(out self, gid: Int, var choices: Choices, var program: List[Step], replayed: Bool):
        self.gid = gid
        self.choices = choices^
        self.program = program^
        self.replayed = replayed


struct Machine(Property):
    var loaded: Pointer[Loaded, MutUntrackedOrigin]
    var iface: Int
    var name: String
    var prefix: String
    var props: List[Prop]
    var n_ctors: Int
    var base: List[Int]
    """The id of each callable's first clause among all the run's clauses."""
    var inv_base: Int
    var invs: List[InvTally]
    var inv_host: RunHost
    var steps: Int
    var max_handles: Int
    var seed: Int
    # Scratch of one execution
    var agg: List[Int]
    var fail_index: Int
    var log: List[String]
    var replays: Int
    var fail_receiver: String
    var cxs: List[Counterexample]
    var has_cx: List[Bool]

    def __init__(
        out self,
        mut loaded: Loaded,
        mut client: DriverClient,
        iface: Int,
        options: RunOptions,
    ) raises:
        self.loaded = Pointer[Loaded, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=loaded))
        )
        self.iface = iface
        self.name = loaded.spec.models[iface].name.copy()
        var last = self.name.copy()
        var parts = self.name.split(".")
        if len(parts) > 0:
            last = String(parts[len(parts) - 1])
        self.prefix = String(last[byte=0:1]).lower() if last.byte_length() > 0 else String("h")
        self.props = List[Prop]()
        self.base = List[Int]()
        var fns = loaded.spec.models[iface].ctors.copy()
        self.n_ctors = len(fns)
        for m in loaded.spec.models[iface].methods:
            fns.append(m)
        if self.n_ctors == 0:
            raise Error(String(self.name, " has no constructor: the run has no way to make an object"))
        var total = 0
        for f in fns:
            self.base.append(total)
            self.props.append(Prop(loaded, client, f, options, True))
            total += len(self.props[len(self.props) - 1].infos)
        self.inv_base = total
        self.invs = List[InvTally]()
        for c in loaded.spec.models[iface].clauses:
            ref cl = loaded.spec.clauses[c]
            if cl.kind == ast.INVARIANT:
                self.invs.append(InvTally(c, iface, cl.id.copy(), source_text(loaded.spec, cl.node)))
        self.inv_host = RunHost(loaded, client)
        for j in range(len(self.props[0].host.tnames)):
            self.inv_host.tnames.append(self.props[0].host.tnames[j].copy())
            self.inv_host.tids.append(self.props[0].host.tids[j])
        self.steps = options.steps
        self.max_handles = options.max_handles
        self.seed = Int(options.seed)
        self.agg = List[Int](length=total + len(self.invs), fill=UNSET)
        self.fail_index = -1
        self.log = List[String]()
        self.replays = 0
        self.fail_receiver = String()
        self.cxs = List[Counterexample]()
        self.has_cx = List[Bool](length=total + len(self.invs), fill=False)
        for _ in range(total + len(self.invs)):
            self.cxs.append(Counterexample())

    def gid_count(self) -> Int:
        return self.inv_base + len(self.invs)

    def gid_id(self, gid: Int) -> String:
        if gid >= self.inv_base:
            return self.invs[gid - self.inv_base].id.copy()
        var c = self._owner(gid)
        return self.props[c].infos[gid - self.base[c]].id.copy()

    def _owner(self, gid: Int) -> Int:
        var c = len(self.props) - 1
        while c > 0 and self.base[c] > gid:
            c -= 1
        return c

    # Generation

    def generate(mut self, mut src: Source) raises -> List[Step]:
        var program = List[Step]()
        var recent = List[Int]()  # steps of the constructors whose objects are live, the one used last first
        var many = Many(1, self.steps, Float64(self.steps) / 2.0)
        var n_methods = len(self.props) - self.n_ctors
        while many.more(src):
            var options = List[Int]()
            if len(recent) < self.max_handles or n_methods == 0:
                for c in range(self.n_ctors):
                    options.append(c)
            if len(recent) > 0:
                for c in range(self.n_ctors, len(self.props)):
                    options.append(c)
            var c = options[src.draw_choice(len(options))]
            var sid = len(program)
            var target = -1
            if c >= self.n_ctors:
                var pick = 0
                if src.draw_below(2) == 1:
                    pick = src.draw_choice(8)
                var at = pick % len(recent)
                target = recent[at]
                _ = recent.pop(at)
                recent.insert(0, target)
            var args = self.props[c].draw_stateful(src)
            self._small_ints(src, c, args)
            if c < self.n_ctors:
                recent.insert(0, sid)
            program.append(Step(sid, c, args^, target))
        return program^

    def _small_ints(mut self, mut src: Source, c: Int, mut args: List[Value]) raises:
        """An integer argument is 0 to 4 in magnitude three times in four."""
        ref types = self.loaded[].spec.types
        for i in range(len(args)):
            if is_default(args[i]) or is_not_drawn(args[i]):
                continue
            var t = self.props[c].ptypes[i]
            var k = types.kind(t)
            if k != ty.INT and k != ty.FIXED_INT:
                continue
            if src.draw_below(4) == 3:
                continue
            var lo = -4
            if k == ty.FIXED_INT and not types.info(t).signed:
                lo = 0
            args[i] = Value.int(src.draw_int(lo, 4))

    def regenerate(mut self, choices: Choices) -> List[Step]:
        """The program a sequence of choices makes; empty when it no longer fits."""
        var src = Source(0, SHRINK_SOURCE)
        src.reset_replay(choices.values)
        try:
            return self.generate(src)
        except:
            return List[Step]()

    # The property

    def run(mut self, mut src: Source) raises -> Outcome:
        var counting = src.max_choices < SHRINK_SOURCE
        var program = self.generate(src)
        return self.execute(program, counting, counting and not src.extend, -1, False)

    # Execution

    def execute(
        mut self,
        program: List[Step],
        counting: Bool,
        is_replay: Bool,
        focus: Int,
        want_log: Bool,
    ) raises -> Outcome:
        """Runs a program. With `focus` (a clause id), stops at the first step that
        fails that clause, noting its position in `fail_index`, and captures what the
        failure shows."""
        for g in range(len(self.agg)):
            self.agg[g] = UNSET
        self.fail_index = -1
        self.log.clear()
        for c in range(len(self.props)):
            self.props[c].focus = -1
            if focus >= 0 and focus < self.inv_base and self._owner(focus) == c:
                self.props[c].focus = focus - self.base[c]
                self.props[c].details[focus - self.base[c]].present = False
        if focus >= self.inv_base:
            self.invs[focus - self.inv_base].detail.present = False
        var live = List[Value]()
        var names = List[String]()
        var made = List[Int]()
        var failure = String()
        try:
            for pos in range(len(program)):
                if self._step(program[pos], pos, live, names, made, counting, is_replay, focus, want_log):
                    break
        except e:
            failure = String(e)
        self._release()
        for c in range(len(self.props)):
            self.props[c].focus = -1
        if failure:
            raise Error(failure)
        var out = Outcome()
        for g in range(len(self.agg)):
            var v = self.agg[g]
            out.add(g, FAILED if v == V_FAIL else (PASSED if v == V_PASS else SKIPPED))
        return out^

    def _release(mut self):
        for c in range(len(self.props)):
            self.props[c].host.release_all()
        self.inv_host.release_all()

    def _note(mut self, gid: Int, verdict: Int):
        var v = self.agg[gid]
        if verdict == V_FAIL:
            self.agg[gid] = V_FAIL
        elif verdict == V_PASS:
            if v != V_FAIL:
                self.agg[gid] = V_PASS
        elif v == UNSET:
            self.agg[gid] = V_SKIP

    def _step(
        mut self,
        step: Step,
        pos: Int,
        mut live: List[Value],
        mut names: List[String],
        mut made: List[Int],
        counting: Bool,
        is_replay: Bool,
        focus: Int,
        want_log: Bool,
    ) raises -> Bool:
        """Runs and judges one step; True when the run is to stop (a focus failure)."""
        var c = step.callable
        var args = step.args.copy()
        var receiver = String()
        if c >= self.n_ctors:
            var at = -1
            for k in range(len(made)):
                if made[k] == step.target:
                    at = k
            if at < 0:
                return False
            args[0] = live[at].copy()
            receiver = names[at].copy()
        self.props[c].live = live.copy()
        self.props[c].live_names = names.copy()
        self.props[c].self_name = receiver.copy()
        self.props[c].last_ran = False
        var out = self.props[c].examine(args^, counting, is_replay)
        if out.is_invalid:
            return False
        var stop = False
        for i in range(len(self.props[c].infos)):
            var v = self.props[c].vkind[i]
            self._note(self.base[c] + i, v)
            if v == V_FAIL and focus == self.base[c] + i:
                stop = True
        if not self.props[c].last_ran:
            return stop
        var name = String()
        if c < self.n_ctors and self.props[c].last_ok and self.props[c].last_result.kind == HANDLE:
            name = String(self.prefix, len(live) + 1)
        if want_log:
            self.log.append(self._call_text(step, receiver, name))
        if name.byte_length() > 0:
            live.append(self.props[c].last_result.copy())
            names.append(name^)
            made.append(step.sid)
        if self._invariants(live, names, counting, is_replay, focus):
            stop = True
        if stop:
            self.fail_index = pos
            self.fail_receiver = receiver^
        return stop

    def _call_text(mut self, step: Step, receiver: String, name: String) -> String:
        ref func = self.loaded[].spec.fns[self.props[step.callable].f]
        var shown = String()
        var first = 1 if func.receiver else 0
        for i in range(first, len(step.args)):
            if is_default(step.args[i]):
                continue
            shown += (", " if shown else "") + func.params[i].name + "=" + self.props[step.callable].show(
                step.args[i], self.props[step.callable].ptypes[i]
            )
        var is_ctor = step.callable < self.n_ctors
        var head = String()
        if is_ctor:
            head = self.name.copy() if func.name == "__init__" else func.decl_id.copy()
        else:
            head = receiver + "." + func.name
        var call = String(head, "(", shown, ")")
        ref prop = self.props[step.callable]
        if is_ctor and name:
            return String(name, " = ", call)
        if prop.last_reply.kind == ERROR:
            return String(call, " raised ", prop.last_reply.name(), ": ", prop.last_reply.text())
        if not is_ctor and prop.last_ok and self.loaded[].spec.types.kind(prop.rtype) != ty.UNIT:
            return String(call, " -> ", prop.show(prop.last_result.copy(), prop.rtype))
        return call^

    def _invariants(
        mut self,
        live: List[Value],
        names: List[String],
        counting: Bool,
        is_replay: Bool,
        focus: Int,
    ) raises -> Bool:
        """Judges every invariant on every live object; True on a focus failure."""
        var stop = False
        for q in range(len(self.invs)):
            var gid = self.inv_base + q
            var note = String()
            var verdict = self._invariant(q, live, names, focus == gid, note)
            self._note(gid, verdict)
            if counting:
                if verdict == V_PASS:
                    self.invs[q].tp += 1
                elif verdict == V_FAIL:
                    self.invs[q].tf += 1
                    if not self.invs[q].fail_seen:
                        self.invs[q].fail_seen = True
                        if is_replay:
                            self.invs[q].replayed = True
                elif verdict == V_SKIP:
                    self.invs[q].ts += 1
                else:
                    self.invs[q].te += 1
                    var seen = False
                    for e in self.invs[q].errors:
                        if e == note:
                            seen = True
                    if not seen and len(self.invs[q].errors) < KEPT_SPEC_ERRORS:
                        self.invs[q].errors.append(note^)
            if verdict == V_FAIL and focus == gid:
                stop = True
        return stop

    def _invariant(
        mut self,
        q: Int,
        live: List[Value],
        names: List[String],
        capture: Bool,
        mut note: String,
    ) raises -> Int:
        ref spec = self.loaded[].spec
        var c = self.invs[q].clause
        if len(live) == 0:
            return V_SKIP
        self.inv_host.begin_example(List[Value]())
        for k in range(len(live)):
            var env = Env()
            env.set_self(live[k].copy())
            for j in range(len(self.inv_host.tnames)):
                env.bind_type(self.inv_host.tnames[j].copy(), self.inv_host.tids[j])
            var j = judge(spec, c, env, self.inv_host)
            if j.is_true():
                continue
            if j.is_false():
                if capture:
                    self._capture_invariant(q, live, names, k, env)
                return V_FAIL
            if j.is_skip():
                return V_SKIP
            note = located(spec, j.node, j.message) if j.node > 0 else j.message.copy()
            return V_ERROR
        return V_PASS

    def _capture_invariant(
        mut self, q: Int, live: List[Value], names: List[String], bad: Int, env: Env
    ) raises:
        ref spec = self.loaded[].spec
        var d = Counterexample()
        d.seed = self.seed
        for k in range(len(live)):
            d.input_names.append(names[k].copy())
            d.input_values.append(self.props[0].show(live[k], self.props[0].iface))
        d.observation = String("after the last step, ", self.invs[q].id, " is false on ", names[bad])
        var pairs = explain(spec, self.invs[q].clause, env, self.inv_host)
        for pair in pairs:
            d.expl_source.append(pair[0])
            d.expl_value.append(pair[1])
        d.reproduce = String("seed=", self.seed, " decl=", self.name, " clause=", self.invs[q].id)
        self.invs[q].detail.present = True
        self.invs[q].detail.cx = d^

    # Results

    def capture(mut self, gid: Int):
        """Keeps what the last (focus) execution showed for a failing clause."""
        var d: Counterexample
        var note = String()
        if gid >= self.inv_base:
            ref inv = self.invs[gid - self.inv_base]
            if not inv.detail.present:
                return
            d = inv.detail.cx.copy()
        else:
            var c = self._owner(gid)
            var local = gid - self.base[c]
            ref prop = self.props[c]
            if not prop.details[local].present:
                return
            d = prop.details[local].cx.copy()
            if prop.infos[local].kind != K_TYPE:
                note = prop.vnote[local].copy()
            if c >= self.n_ctors and len(d.input_names) > 0 and d.input_names[0] == "self":
                d.input_values[0] = String(self.fail_receiver, " = ", d.input_values[0])
        var steps = String("steps:")
        for k in range(len(self.log)):
            steps += String("\n", k + 1, ". ", self.log[k])
        d.observation = String(steps, "\n", d.observation, "\n" + note if note else String())
        self.cxs[gid] = d^
        self.has_cx[gid] = True

    def fill(
        self,
        mut result: RunResult,
        loaded: Loaded,
        options: RunOptions,
        failure: String,
        found: List[Optional[Found]],
        elapsed: Float64,
    ) raises:
        """One ClauseResult per clause of every constructor and method, then per
        invariant."""
        ref spec = loaded.spec
        for c in range(len(self.props)):
            ref prop = self.props[c]
            var slots = len(prop.cov_names)
            for i in range(len(prop.infos)):
                ref info = prop.infos[i]
                var gid = self.base[c] + i
                var cr = ClauseResult(info.id.copy(), info.text.copy(), info.label.copy(), spec.fns[prop.f].decl_id.copy())
                for j in range(len(prop.host.tnames)):
                    cr.instantiation_names.append(prop.host.tnames[j].copy())
                    cr.instantiation_types.append(spec.types.text(prop.host.tids[j]))
                cr.mode = "stateful"
                cr.passed = prop.tp[i]
                cr.failed = prop.tf[i]
                cr.skipped = prop.ts[i] + prop.req_skips + prop.unrep_skips
                cr.spec_error = prop.te[i]
                if failure:
                    cr.spec_error += 1
                    cr.spec_errors.append(failure.copy())
                for s in range(slots):
                    cr.coverage_names.append(prop.cov_names[s].copy())
                    cr.coverage_counts.append(prop.cov[i * slots + s])
                for q in range(N_CAUSES):
                    var count = prop.causes[i * N_CAUSES + q]
                    if q == 0:
                        count += prop.req_skips
                    if q == 4:
                        count += prop.unrep_skips
                    if count > 0:
                        cr.skip_names.append(cause_name(q))
                        cr.skip_counts.append(count)
                for k in range(len(prop.se_pid)):
                    if prop.se_pid[k] == i:
                        cr.spec_errors.append(String(prop.se_msg[k], "\nexample: ", prop.se_input[k]))
                self._finish(cr, gid, prop.tf[i], prop.replayed[i], found, options, elapsed)
                result.clauses.append(cr^)
        for q in range(len(self.invs)):
            ref inv = self.invs[q]
            var cr = ClauseResult(inv.id.copy(), inv.text.copy(), String("invariant"), self.name.copy())
            for j in range(len(self.props[0].host.tnames)):
                cr.instantiation_names.append(self.props[0].host.tnames[j].copy())
                cr.instantiation_types.append(spec.types.text(self.props[0].host.tids[j]))
            cr.mode = "stateful"
            cr.passed = inv.tp
            cr.failed = inv.tf
            cr.skipped = inv.ts
            cr.spec_error = inv.te
            if failure:
                cr.spec_error += 1
                cr.spec_errors.append(failure.copy())
            for e in inv.errors:
                cr.spec_errors.append(e.copy())
            if inv.ts > 0:
                cr.skip_names.append(String("other"))
                cr.skip_counts.append(inv.ts)
            self._finish(cr, self.inv_base + q, inv.tf, inv.replayed, found, options, elapsed)
            result.clauses.append(cr^)

    def _finish(
        self,
        mut cr: ClauseResult,
        gid: Int,
        fails: Int,
        replayed: Bool,
        found: List[Optional[Found]],
        options: RunOptions,
        elapsed: Float64,
    ):
        if self.has_cx[gid]:
            cr.counterexample = self.cxs[gid].copy()
            cr.failing_inputs = max(1, fails)
        elif fails > 0:
            cr.failing_inputs = fails
        cr.replayed = replayed
        cr.duration = elapsed

    # Shrinking

    def fails(mut self, program: List[Step], gid: Int) raises -> Bool:
        self.replays += 1
        _ = self.execute(program, False, False, gid, False)
        return self.fail_index >= 0

    def trimmed(self, program: List[Step]) -> List[Step]:
        """The program up to the step that failed the clause last executed."""
        var out = List[Step]()
        for k in range(len(program)):
            if k > self.fail_index:
                break
            out.append(program[k].copy())
        return out^

    def shorten(mut self, var program: List[Step], gid: Int) raises -> List[Step]:
        var improved = True
        while improved and self.replays < MAX_REPLAYS:
            improved = False
            var k = len(program) - 1
            while k >= 0:
                var candidate = _without(program, program[k].sid)
                if len(candidate) < len(program) and self.fails(candidate, gid):
                    program = self.trimmed(candidate)
                    improved = True
                    break
                k -= 1
        return program^

    def lower(mut self, program: List[Step], gid: Int) raises -> Optional[List[Step]]:
        """A program with one constructor argument smaller (the constructor's object
        may lose one call that filled it) that still fails the clause."""
        for step in program:
            if step.target >= 0:
                continue
            var dependents = List[Int]()
            for other in program:
                if other.target == step.sid:
                    dependents.append(other.sid)
            for j in range(len(step.args)):
                if step.args[j].kind != INT or not step.args[j].small_int():
                    continue
                var v = step.args[j].small_int().value()
                if v == 0:
                    continue
                for w in _toward_zero(v):
                    var lowered = _with_arg(program, step.sid, j, w)
                    var tries = List[List[Step]]()
                    tries.append(lowered.copy())
                    if abs(v - w) == 1:
                        for d in dependents:
                            tries.append(_without(lowered, d))
                    for candidate in tries:
                        if self.replays >= MAX_REPLAYS:
                            return None
                        if self.fails(candidate, gid):
                            return self.trimmed(candidate)
        return None

    def minimize(mut self, var program: List[Step], gid: Int) raises -> List[Step]:
        if not self.fails(program, gid):
            return program^
        program = self.trimmed(program)
        program = self.shorten(program^, gid)
        while self.replays < MAX_REPLAYS:
            var lowered = self.lower(program, gid)
            if not lowered:
                break
            program = self.shorten(lowered.take(), gid)
        return program^

    def stored_form(mut self, found: Found) -> Stored:
        """The edits that turn the program the choices generate into the found one."""
        var orig = self.regenerate(found.choices)
        var out = Stored()
        out.choices = found.choices.copy()
        for step in orig:
            var kept = -1
            for k in range(len(found.program)):
                if found.program[k].sid == step.sid:
                    kept = k
            if kept < 0:
                out.deleted.append(step.sid)
                continue
            for j in range(len(step.args)):
                if found.program[kept].args[j] != step.args[j] and found.program[kept].args[j].small_int():
                    out.arg_sid.append(step.sid)
                    out.arg_index.append(j)
                    out.arg_value.append(found.program[kept].args[j].small_int().value())
        return out^

    def from_stored(mut self, stored: Stored) -> List[Step]:
        var orig = self.regenerate(stored.choices)
        var out = List[Step]()
        for step in orig:
            var gone = False
            for d in stored.deleted:
                if d == step.sid:
                    gone = True
            if gone:
                continue
            var copy = step.copy()
            for i in range(len(stored.arg_sid)):
                if stored.arg_sid[i] == step.sid and stored.arg_index[i] < len(copy.args):
                    copy.args[stored.arg_index[i]] = Value.int(stored.arg_value[i])
            out.append(copy^)
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
    if m and loaded.spec.models[m.value()].is_interface:
        return m
    return None


def _key(loaded: Loaded, options: RunOptions, id: String) -> String:
    var key = String(loaded.hash, "/", id)
    for k in range(len(options.inst_names)):
        key += String("[", options.inst_names[k], "=", options.inst_types[k], "]")
    return key^


def run_interface(
    mut loaded: Loaded,
    iface: Int,
    options: RunOptions,
    mut driver: DriverClient,
) raises -> RunResult:
    """Runs the interface at position `iface` of the spec: all of its clauses in one
    search over step sequences."""
    var started = perf_counter_ns()
    apply_targets(loaded)
    var name = loaded.spec.models[iface].name.copy()
    var result = RunResult(name.copy())
    var m = Machine(loaded, driver, iface, options)
    var seed = fnv(String(options.seed, ":", name))
    var settings = Settings()
    settings.seed = seed
    settings.max_examples = options.max_examples
    settings.max_choices = 1 << 20
    settings.max_shrink_steps = options.shrink_steps()
    var n = m.gid_count()
    var found = List[Optional[Found]]()
    for _ in range(n):
        found.append(None)
    var res = SearchResult()
    var failure = String()
    try:
        if options.store:
            for g in range(n):
                var stored = load_stored(options.store.value(), _key(loaded, options, m.gid_id(g)))
                if not stored:
                    continue
                var program = m.from_stored(stored.value())
                if len(program) == 0:
                    continue
                _ = m.execute(program, True, True, -1, False)
                if m.agg[g] == V_FAIL:
                    found[g] = Found(g, stored.take().choices.copy(), program^, True)
                    result.mode = "replay"
        res = search(m, settings)
        result.examples = res.examples
        result.invalid = res.invalid
        for k in range(len(res.properties)):
            ref pr = res.properties[k]
            if not pr.failed or pr.id < 0 or pr.id >= n or Bool(found[pr.id]):
                continue
            m.replays = 0
            var program = m.regenerate(pr.choices)
            program = m.minimize(program^, pr.id)
            found[pr.id] = Found(pr.id, pr.choices.copy(), program^, False)
            if options.store:
                try:
                    save_stored(
                        options.store.value(),
                        _key(loaded, options, m.gid_id(pr.id)),
                        m.stored_form(found[pr.id].value()),
                    )
                except:
                    pass
        # What each failure shows.
        for g in range(n):
            if found[g]:
                _ = m.execute(found[g].value().program, False, False, g, True)
                m.capture(g)
    except e:
        failure = String(e)
    var elapsed = Float64(perf_counter_ns() - started) / 1e9
    m.fill(result, loaded, options, failure, found, elapsed)
    m._release()
    result.seconds = Float64(perf_counter_ns() - started) / 1e9
    return result^


def run_declaration(
    mut loaded: Loaded,
    decl: String,
    options: RunOptions,
    mut driver: DriverClient,
) raises -> RunResult:
    """Runs a function, or an interface by its name: the entry point of the host API's
    `run`."""
    var iface = interface_named(loaded, decl)
    if iface:
        return run_interface(loaded, iface.value(), options, driver)
    return run_function(loaded, decl, options, driver)
