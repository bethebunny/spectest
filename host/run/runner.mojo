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
    class_holds,
    collect_olds,
    evaluate,
    explain,
    judge,
    snapshot_olds,
)
from eval.coerce import bits_of_value, coerce_arg
from eval.env import Env
from eval.text import located, source_text
from gen.classes import draw_in_classes
from gen.domain import domain_size, value_at
from gen.models import (
    default_marker,
    draw_args,
    draw_model,
    is_default,
)
from gen.value import draw_value
from mcheck.property import FAILED, PASSED, SKIPPED, Outcome, Property
from mcheck.search import SearchResult, enumerate_all, search
from mcheck.settings import Settings
from mcheck.source import Source
from sets import BitSet
from syntax import ast
from wire.format import format_value
from wire.value import ERROR, HANDLE, LIST, MAP, OPTION, RECORD, STRING, TUPLE, Value

from .aggregate import run_aggregate
from .decode import decode, describe
from .host import RunHost
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


struct Prop(Property):
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
    var causes: List[Int]
    var cov: List[Int]
    var fail_seen: List[Bool]
    var replayed: List[Bool]
    var req_skips: Int
    var unrep_skips: Int
    var se_pid: List[Int]
    var se_msg: List[String]
    var se_input: List[String]
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

    def __init__(
        out self,
        mut loaded: Loaded,
        mut client: DriverClient,
        f: Int,
        options: RunOptions,
    ) raises:
        self.loaded = Pointer[Loaded, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=loaded))
        )
        self.host = RunHost(loaded, client)
        self.f = f
        self.seed = Int(options.seed)
        ref func = loaded.spec.fns[f]
        self.decl = func.decl_id.copy()
        self.tenv = List[Int]()
        # The instantiation.
        for j in range(len(func.tparams)):
            var found = -1
            for k in range(len(options.inst_names)):
                if options.inst_names[k] == func.tparams[j]:
                    found = k
            if found < 0:
                raise Error(
                    String(func.decl_id, " is generic: the run needs a type for ", func.tparams[j])
                )
            var t = parse_type(options.inst_types[found], loaded.spec.types)
            self.tenv.append(t)
            self.host.tnames.append(func.tparams[j])
            self.host.tids.append(t)
        self.ptypes = List[Int]()
        for p in func.params:
            if len(func.tparams) > 0:
                self.ptypes.append(loaded.spec.types.substitute(p.type, func.tparams, self.tenv))
            else:
                self.ptypes.append(p.type)
        if len(func.tparams) > 0:
            self.rtype = loaded.spec.types.substitute(func.result, func.tparams, self.tenv)
        else:
            self.rtype = func.result
        self.infos = List[PropInfo]()
        self.requires = List[Int]()
        self.cond_clauses = List[Int]()
        self.old_clauses = List[Int]()
        self.modified = List[String]()
        self.checked = List[Int]()
        self.errors = loaded.spec.errors.copy()
        self.result_has_model = type_has_model(loaded.spec.types, self.rtype)
        self.domain = 0
        self.cov_start = List[Int]()
        self.cov_names = List[String]()
        self.tp = List[Int]()
        self.tf = List[Int]()
        self.ts = List[Int]()
        self.te = List[Int]()
        self.causes = List[Int]()
        self.cov = List[Int]()
        self.fail_seen = List[Bool]()
        self.replayed = List[Bool]()
        self.req_skips = 0
        self.unrep_skips = 0
        self.se_pid = List[Int]()
        self.se_msg = List[String]()
        self.se_input = List[String]()
        self.vkind = List[Int]()
        self.vnote = List[String]()
        self.part_class = List[Int]()
        self.defaulted = List[Bool]()
        self.explain_all = False
        self.focus = -1
        self.details = List[Detail]()
        self._plan(loaded.spec.fns[f].clauses.copy(), options)

    # Planning

    def _plan(mut self, clauses: List[Int], options: RunOptions) raises:
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var has_modifies = False
        for c in clauses:
            ref cl = spec.clauses[c]
            var k = cl.kind
            if k == ast.REQUIRES:
                self.requires.append(c)
            elif k == ast.ENSURES or k == ast.RELATES:
                self.infos.append(PropInfo(K_COND, c, cl.id.copy(), source_text(spec, cl.node), String(ast.op_name(k)), -1))
                var olds = List[Int]()
                if cl.expr != 0:
                    collect_olds(spec, cl.expr, olds)
                if len(olds) > 0:
                    self.old_clauses.append(c)
            elif k == ast.RAISES:
                self.infos.append(PropInfo(K_RAISES, c, cl.id.copy(), source_text(spec, cl.node), "raises", -1))
                self.cond_clauses.append(c)
            elif k == ast.MAY_RAISE:
                self.cond_clauses.append(c)
            elif k == ast.MODIFIES:
                has_modifies = True
                for n in cl.names:
                    self.modified.append(n)
                self.infos.append(PropInfo(K_MODIFIES, c, cl.id.copy(), source_text(spec, cl.node), "modifies", -1))
        var decl = func.decl_id
        self.infos.append(PropInfo(K_TYPE, -1, decl + "#type", String("built-in: the result of ", func.name, " reads as ", spec.types.text(self.rtype)), "type", -1))
        self.infos.append(PropInfo(K_ANY_RAISES, -1, decl + "#raises", String("built-in: ", func.name, " raises only what a raises or may_raise admits"), "raises", -1))
        # Handle parameters that the call may not change.
        for i in range(len(func.params)):
            ref t = spec.types.info(self.ptypes[i])
            if t.kind == ty.MODEL and not t.signed:
                var listed = False
                for n in self.modified:
                    if n == func.params[i].name:
                        listed = True
                if not listed:
                    self.checked.append(i)
        var handle_params = False
        for i in range(len(func.params)):
            ref t = spec.types.info(self.ptypes[i])
            if t.kind == ty.MODEL and not t.signed:
                handle_params = True
        if handle_params and not has_modifies:
            var names = String()
            for i in self.checked:
                names += (", " if names else "") + func.params[i].name
            self.infos.append(PropInfo(K_FRAME, -1, decl + "#frame", String("built-in: ", func.name, " leaves ", names, " unchanged (no modifies clause)"), "frame", -1))
        # Invariants of the models the function returns or modifies.
        var models = List[String]()
        collect_models(spec.types, self.rtype, models)
        for i in range(len(func.params)):
            for n in self.modified:
                if n == func.params[i].name:
                    collect_models(spec.types, self.ptypes[i], models)
        for name in models:
            var m = spec.model_named(name)
            if not m:
                continue
            for c in spec.models[m.value()].clauses:
                ref cl = spec.clauses[c]
                if cl.kind == ast.INVARIANT:
                    self.infos.append(PropInfo(K_INVARIANT, c, decl + ":" + cl.id, source_text(spec, cl.node), "invariant", m.value()))
        # Tallies.
        var n = len(self.infos)
        for _ in range(n):
            self.tp.append(0)
            self.tf.append(0)
            self.ts.append(0)
            self.te.append(0)
            self.fail_seen.append(False)
            self.replayed.append(False)
            self.vkind.append(V_PASS)
            self.vnote.append(String())
            self.details.append(Detail())
        for _ in range(n * N_CAUSES):
            self.causes.append(0)
        for p in range(len(func.partitions)):
            self.cov_start.append(len(self.cov_names))
            ref part = func.partitions[p]
            for k in range(len(part.classes)):
                self.cov_names.append(String(func.params[part.param].name, ": ", part.classes[k].name))
            self.part_class.append(-1)
        for _ in range(n * len(self.cov_names)):
            self.cov.append(0)
        for _ in range(len(func.params)):
            self.defaulted.append(False)
        # A domain small enough to run every input.
        var size = UInt64(1)
        var small = True
        for i in range(len(func.params)):
            if i == 0 and func.receiver:
                small = False
                break
            var d = domain_size(spec.types, self.ptypes[i])
            if not d:
                small = False
                break
            size *= d.value()
            if size > UInt64(options.exhaustive_limit):
                small = False
                break
        if small and size > 0 and size <= UInt64(options.exhaustive_limit):
            self.domain = size

    def keys(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self.infos)):
            out.append(self.loaded[].hash + "/" + self.infos[i].id)
        return out^

    # Drawing

    def draw(mut self, mut src: Source) raises -> List[Value]:
        ref spec = self.loaded[].spec
        if self.domain > 0:
            var index = src.draw_below(self.domain)
            var n = len(spec.fns[self.f].params)
            var args = List[Value](capacity=n)
            for _ in range(n):
                args.append(Value.none())
            var j = n - 1
            while j >= 0:
                var s = domain_size(spec.types, self.ptypes[j]).value()
                args[j] = value_at(spec.types, self.ptypes[j], index % s)
                index //= s
                j -= 1
            return args^
        var args = draw_args(
            src,
            self.loaded[].spec,
            self.f,
            self.loaded[].sizes,
            self.host,
            self.tenv,
            True,
        )
        if spec.fns[self.f].receiver:
            var m = spec.fns[self.f].owner
            args[0] = draw_model(src, self.loaded[].spec, m, self.host, self.loaded[].sizes)
        for p in range(len(spec.fns[self.f].partitions)):
            self._steer(src, p, args)
        return args^

    def _steer(mut self, mut src: Source, p: Int, mut args: List[Value]) raises:
        ref spec = self.loaded[].spec
        ref part = spec.fns[self.f].partitions[p]
        var i = part.param
        if is_default(args[i]):
            return
        var t = self.ptypes[i]
        var n = len(part.classes)
        if n == 0:
            return
        var predicate = self.loaded[].sets.is_predicate(self.f, p, 0)
        if not predicate:
            var classes = List[BitSet]()
            for k in range(n):
                classes.append(self.loaded[].sets.set_of(self.f, p, k))
            args[i] = draw_in_classes(src, self.loaded[].ctx, spec.types, classes, t)
            return
        if spec.types.kind(t) == ty.MODEL:
            return
        # A predicate class: pick a class (or none), then draw until a value is in it.
        var k = src.draw_choice(n + 1)
        if k >= n:
            return
        for _ in range(8):
            var v = draw_value(src, self.loaded[].spec.types, t, self.loaded[].sizes, 0)
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
        try:
            args = self.draw(src)
        except e:
            if src.invalid and counting and src.extend:
                self.unrep_skips += 1
            raise e^
        return self.examine(args^, counting, counting and not src.extend)

    def run_fixed(mut self, var args: List[Value]) raises -> Outcome:
        """Judges explicit inputs; the counterexamples keep them as given."""
        self.explain_all = True
        var out = self.examine(args^, True, False)
        self.explain_all = False
        return out^

    def _spec_error_all(mut self, message: String, counting: Bool, args: List[Value]) -> Outcome:
        var out = Outcome()
        for i in range(len(self.infos)):
            self.vkind[i] = V_ERROR
            self.vnote[i] = message.copy()
            out.add(i, SKIPPED)
        if counting:
            for i in range(len(self.infos)):
                self.te[i] += 1
                self._note_spec_error(i, message, args)
        return out^

    def _note_spec_error(mut self, i: Int, message: String, args: List[Value]):
        var seen = 0
        for k in range(len(self.se_pid)):
            if self.se_pid[k] == i:
                seen += 1
                if self.se_msg[k] == message:
                    return
        if seen >= KEPT_SPEC_ERRORS:
            return
        self.se_pid.append(i)
        self.se_msg.append(message.copy())
        self.se_input.append(self._inputs_text(args))

    def _inputs_text(mut self, args: List[Value]) -> String:
        var out = String()
        ref func = self.loaded[].spec.fns[self.f]
        for i in range(len(args)):
            out += (", " if out else "") + func.params[i].name + " = " + self.show(args[i], self.ptypes[i])
        return out if out else String("(no inputs)")

    def show(mut self, v: Value, t: Int) -> String:
        """A value for a counterexample: a handle by its observed fields."""
        try:
            if v.kind == HANDLE:
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

    def digest(mut self, v: Value, t: Int) raises -> Value:
        ref spec = self.loaded[].spec
        var m = spec.model_named(spec.types.info(t).name)
        var items = List[Value]()
        if m and v.kind == HANDLE:
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
        var names = List[String]()
        names.append(norm_name(err.name()))
        for i in range(err.item_count()):
            names.append(norm_name(err.item(i).text()))
        ref spec = self.loaded[].spec
        for n in names:
            for c in self.cond_clauses:
                if norm_name(spec.clauses[c].error) == n:
                    return spec.clauses[c].error.copy()
            for e in self.errors:
                if norm_name(e) == n:
                    return e.copy()
        return String()

    def examine(mut self, var args: List[Value], counting: Bool, is_replay: Bool) raises -> Outcome:
        ref spec = self.loaded[].spec
        ref func = spec.fns[self.f]
        var n = len(self.infos)
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
        for j in range(len(self.host.tnames)):
            env.bind_type(self.host.tnames[j].copy(), self.host.tids[j])
        # requires
        for c in self.requires:
            var j = judge(spec, c, env, self.host)
            if j.is_false():
                if counting:
                    self.req_skips += 1
                return Outcome.invalid()
            if not j.is_true():
                return self._spec_error_all(
                    String(spec.clauses[c].id, ": ", located(spec, j.node, j.message) if j.node > 0 else j.message),
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
            if i >= len(args) or args[i].kind != HANDLE:
                before.append(Value.none())
                continue
            try:
                before.append(self.digest(args[i], self.ptypes[i]))
            except e:
                digest_error = String(e)
                before.append(Value.none())
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
                cond_msg.append(located(spec, j.node, j.message) if j.node > 0 else j.message.copy())
        # The call.
        var reply = self.host.call(self.f, args)
        var raised = reply.kind == ERROR
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
                if cl.kind == ast.RAISES:
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
                            if pi >= len(args) or args[pi].kind != HANDLE:
                                continue
                            try:
                                var after = self.digest(args[pi], self.ptypes[pi])
                                if after != before[q]:
                                    changed_names.append(func.params[pi].name.copy())
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
        self.vkind[i] = V_ERROR
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
        if j.is_skip():
            self._skip(i, "planned call")
            return
        if due_ids:
            self._skip(i, "raise due")
            return
        self._error(i, located(spec, j.node, j.message) if j.node > 0 else j.message.copy())

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
    ):
        ref spec = self.loaded[].spec
        var k = 0
        for q in range(len(self.cond_clauses)):
            if self.cond_clauses[q] == c:
                k = q
        ref cl = spec.clauses[c]
        if conds[k] < 0:
            self._error(i, cond_msg[k])
            return
        var did = String("returned")
        if raised:
            did = String("raised ", reply.name(), ": ", reply.text())
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
            self.vnote[i] = String("no raises or may_raise admits ", reply.name(), ": ", reply.text())
            return
        if contains_name(must, mapped) or contains_name(may, mapped):
            return
        for c in self.cond_clauses:
            if spec.clauses[c].kind == ast.RAISES and spec.clauses[c].error == mapped:
                return
        for k in range(len(self.cond_clauses)):
            ref cl = spec.clauses[self.cond_clauses[k]]
            if cl.kind == ast.MAY_RAISE and cl.error == mapped and conds[k] < 0:
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
            if not m:
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
            for q in self.modified:
                if q == func.params[p].name:
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
            for j in range(len(self.host.tnames)):
                env.bind_type(self.host.tnames[j].copy(), self.host.tids[j])
            var j = judge(spec, c, env, self.host)
            if j.is_true():
                continue
            if j.is_false():
                self.vkind[i] = V_FAIL
                self.vnote[i] = String(spec.clauses[c].id, " is false on ", where[q], due_notes)
                return
            if j.is_skip():
                self._skip(i, "planned call")
                return
            if due_ids:
                self._skip(i, "raise due")
                return
            self._error(i, located(spec, j.node, j.message) if j.node > 0 else j.message.copy())
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
            obs = String("raised ", reply.name(), ": ", reply.text())
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
                for q in self.modified:
                    if q == func.params[p].name and args[p].kind == HANDLE:
                        afters += String("\n", q, " after = ", self.show(args[p], self.ptypes[p]))
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
        if len(changed_names) > 0 and (self.infos[i].kind == K_MODIFIES or self.infos[i].kind == K_FRAME):
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
        if kind == K_COND or kind == K_INVARIANT:
            if kind == K_COND:
                var pairs = explain(spec, self.infos[i].clause, env, self.host)
                for q in pairs:
                    d.expl_source.append(q[0])
                    d.expl_value.append(q[1])
        elif kind == K_RAISES or kind == K_ANY_RAISES:
            for k in range(len(self.cond_clauses)):
                ref cl = spec.clauses[self.cond_clauses[k]]
                d.expl_source.append(String(ast.op_name(cl.kind), " ", cl.error, " when ", source_text(spec, cl.expr) if cl.expr != 0 else String("true")))
                d.expl_value.append(String("true") if conds[k] == 1 else (String("false") if conds[k] == 0 else String("error: ", cond_msg[k])))
            d.expl_source.append("errors that must be raised (R)")
            d.expl_value.append(names_text(must))
            d.expl_source.append("errors that may be raised (M)")
            d.expl_value.append(names_text(may))
        d.reproduce = String("seed=", self.seed, " decl=", self.decl, " clause=", self.infos[i].id)
        self.details[i].present = True
        self.details[i].cx = d^


# The driver of a run


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
    if ex.kind != MAP:
        raise Error("an example is a map from parameter name to value")
    var args = List[Value]()
    var used = 0
    for i in range(len(func.params)):
        var found = -1
        for k in range(ex.count()):
            var key = ex.item(2 * k)
            if key.kind == STRING and key.text() == func.params[i].name:
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
            if options.store:
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
    except e:
        failure = String(e)
    for k in range(len(prop.replayed)):
        if prop.replayed[k]:
            result.mode = "replay"
    result.examples = res.examples
    result.invalid = res.invalid
    var elapsed = Float64(perf_counter_ns() - started) / 1e9
    var slots = len(prop.cov_names)
    for i in range(n):
        ref info = prop.infos[i]
        var c = ClauseResult(info.id.copy(), info.text.copy(), info.label.copy(), prop.decl.copy())
        for j in range(len(prop.host.tnames)):
            c.instantiation_names.append(prop.host.tnames[j].copy())
            c.instantiation_types.append(loaded.spec.types.text(prop.host.tids[j]))
        c.mode = "exhaustive" if prop.domain > 0 else "hypothesis"
        c.passed = prop.tp[i]
        c.failed = prop.tf[i]
        c.skipped = prop.ts[i] + prop.req_skips + prop.unrep_skips
        c.spec_error = prop.te[i]
        if failure:
            c.spec_error += 1
            c.spec_errors.append(failure.copy())
        for s in range(slots):
            c.coverage_names.append(prop.cov_names[s].copy())
            c.coverage_counts.append(prop.cov[i * slots + s])
        for q in range(N_CAUSES):
            var count = prop.causes[i * N_CAUSES + q]
            if q == 0:
                count += prop.req_skips
            if q == 4:
                count += prop.unrep_skips
            if count > 0:
                c.skip_names.append(cause_name(q))
                c.skip_counts.append(count)
        for k in range(len(prop.se_pid)):
            if prop.se_pid[k] == i:
                c.spec_errors.append(String(prop.se_msg[k], "\nexample: ", prop.se_input[k]))
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
            if loaded.spec.clauses[ci].kind == ast.AGGREGATE:
                result.clauses.append(
                    run_aggregate(loaded.spec, loaded.ctx, prop.host, f, ci, options, seed)
                )
    prop.host.release_all()
    result.seconds = Float64(perf_counter_ns() - started) / 1e9
    return result^
