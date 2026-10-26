"""Plans: one example of a function call and the verdict of every item."""

from __future__ import annotations

import textwrap
import time

import pytest

from spectest.generate import DEFAULT, GeneratedModel
from spectest.lang import load_source
from spectest.prelude import floats
from spectest.runtime.binding import ModelBinding, conformance
from spectest.runtime.plans import (
    CallOutcome,
    FunctionPlan,
    PlannedCalls,
    can_time_out,
    decl_label,
    handles_in,
    invoke,
    memo_key,
)
from spectest.types import FixedIntT, ListT, ModelT
from spectest.values import Handle, NotAValue, SkipClause, Unrepresentable

I64 = FixedIntT(64, True)


def spec_of(source: str):
    return load_source(textwrap.dedent(source).lstrip("\n"), "t.spec")


def plan_for(source: str, fn: str, impls: dict, **options) -> FunctionPlan:
    spec = spec_of(source)
    conf = conformance(spec, impls=impls, **options)
    return FunctionPlan(conf, spec.fns[fn], conf.instantiations(fn)[0])


def verdicts(plan: FunctionPlan, **args) -> dict[str, str]:
    return plan.run(args).verdicts


RAISES = """
spec t
error A
error B
error C
fn f(x: i64) -> i64
  raises a: A when x < 0
  raises b: B when x < -10
  may_raise C when x == 0
  ensures same: result == x
"""


class A_(Exception):
    pass


class B_(Exception):
    pass


class C_(Exception):
    pass


ERRORS = {A_: "A", B_: "B", C_: "C"}


def raising(table):
    def f(x):
        exc = table(x)
        if exc is not None:
            raise exc
        return x

    return f


def test_items_of_a_function():
    plan = plan_for(RAISES, "f", {"f": lambda x: x}, errors=ERRORS)
    assert [it.key for it in plan.items] == ["f.a", "f.b", "f.same", "f#type", "f#raises"]
    assert [plan.item_name(it) for it in plan.items] == [
        "f.a",
        "f.b",
        "f.same",
        "f#type",
        "f#raises",
    ]
    assert plan.example_keys() == ["f.a", "f.b", "f.same", "f#type", "f#raises"]


def test_a_correct_implementation_passes_everywhere():
    def f(x):
        if x < 0:
            raise A_()
        if x == 0:
            raise C_()
        return x

    plan = plan_for(RAISES, "f", {"f": f}, errors=ERRORS)
    assert verdicts(plan, x=5) == {
        "f.a": "pass",
        "f.b": "pass",
        "f.same": "pass",
        "f#type": "pass",
        "f#raises": "pass",
    }
    assert verdicts(plan, x=-20) == {
        "f.a": "pass",
        "f.b": "pass",
        "f.same": "skip",
        "f#type": "skip",
        "f#raises": "pass",
    }
    v = verdicts(plan, x=0)
    assert v["f#raises"] == "pass" and v["f.same"] == "skip"


def test_overlapping_conditions_accept_any_due_error():
    plan = plan_for(RAISES, "f", {"f": raising(lambda x: B_() if x < 0 else None)}, errors=ERRORS)
    v = verdicts(plan, x=-20)
    assert v["f.a"] == "pass" and v["f.b"] == "pass" and v["f#raises"] == "pass"


def test_raising_an_error_that_is_not_due():
    plan = plan_for(RAISES, "f", {"f": raising(lambda x: B_() if x < 0 else None)}, errors=ERRORS)
    v = verdicts(plan, x=-5)
    assert v["f.a"] == "fail"
    assert v["f.b"] == "skip"
    assert v["f#raises"] == "pass"


def test_returning_when_an_error_is_due():
    plan = plan_for(RAISES, "f", {"f": lambda x: x}, errors=ERRORS)
    ex = plan.run({"x": -20}, explain=True)
    assert ex.verdicts["f.a"] == "fail" and ex.verdicts["f.b"] == "fail"
    assert "A was due" in ex.notes["f.a"]
    assert ("errors that must be raised (R)", "{A, B}") in ex.explanations["f.a"]
    assert ex.verdicts["f.same"] == "pass"


def test_raising_although_the_condition_is_false():
    plan = plan_for(RAISES, "f", {"f": raising(lambda x: A_())}, errors=ERRORS)
    ex = plan.run({"x": 5}, explain=True)
    assert ex.verdicts["f.a"] == "fail"
    assert "although x < 0 is false" in ex.notes["f.a"]
    assert ex.verdicts["f.b"] == "pass"
    assert ex.verdicts["f#raises"] == "pass"
    assert ex.observation == "raised A_ (maps to A)"


def test_may_raise_admits_only_when_its_condition_holds():
    plan = plan_for(RAISES, "f", {"f": raising(lambda x: C_())}, errors=ERRORS)
    assert verdicts(plan, x=0)["f#raises"] == "pass"
    ex = plan.run({"x": 1}, explain=True)
    assert ex.verdicts["f#raises"] == "fail"
    assert ex.notes["f#raises"] == "no raises or may_raise admits C here"
    assert ex.verdicts["f.a"] == "pass"


def test_may_raise_widens_a_raises_clause_of_the_same_error():
    source = """
    spec t
    error A
    fn f(x: i64) -> i64
      raises a: A when x < 0
      may_raise A when x == 0
    """
    impl = raising(lambda x: A_() if x <= 0 else None)
    plan = plan_for(source, "f", {"f": impl}, errors={A_: "A"})
    assert verdicts(plan, x=0) == {"f.a": "pass", "f#type": "skip", "f#raises": "pass"}


def test_unmapped_exceptions_fail_raises():
    plan = plan_for(RAISES, "f", {"f": raising(lambda x: TypeError("boom"))}, errors=ERRORS)
    ex = plan.run({"x": 3}, explain=True)
    assert ex.verdicts["f#raises"] == "fail"
    assert ex.verdicts["f.same"] == "skip"
    assert ex.verdicts["f#type"] == "skip"
    assert ex.observation == "raised TypeError: boom (no spec error maps it)"
    assert (
        ex.notes["f#raises"] == "no spec error maps TypeError, so no raises or may_raise admits it"
    )
    ex = plan.run({"x": -3})
    assert ex.verdicts["f.a"] == "fail"


def test_type_mismatch_fails_type_only():
    plan = plan_for(RAISES, "f", {"f": lambda x: "a"}, errors=ERRORS)
    ex = plan.run({"x": 3}, explain=True)
    assert ex.verdicts == {
        "f.a": "pass",
        "f.b": "pass",
        "f.same": "skip",
        "f#type": "fail",
        "f#raises": "pass",
    }
    assert "expected i64, got str 'a'" in ex.notes["f#type"]
    assert ex.observation == "returned str 'a', which is not i64"


def test_a_type_mismatch_observation_states_the_value_once():
    plan = plan_for(RAISES, "f", {"f": lambda x: 2**70}, errors=ERRORS)
    ex = plan.run({"x": 3}, explain=True)
    assert ex.observation == (
        f"returned int {2**70}, which is not i64 (outside the i64 range {-(2**63)}..{2**63 - 1})"
    )
    source = """
    spec t
    fn g(x: i64) -> list<i64>
    """
    nested = plan_for(source, "g", {"g": lambda x: [1, "a"]})
    ex = nested.run({"x": 0}, explain=True)
    assert ex.observation == (
        "returned list [1, 'a'], which is not list<i64>: at [1]: expected i64, got str 'a'"
    )


def test_out_of_range_integer_is_a_type_mismatch():
    plan = plan_for(RAISES, "f", {"f": lambda x: 2**70}, errors=ERRORS)
    assert verdicts(plan, x=3)["f#type"] == "fail"


def test_ensures_failure_is_explained():
    plan = plan_for(RAISES, "f", {"f": lambda x: x + 1}, errors=ERRORS)
    ex = plan.run({"x": 3}, explain=True)
    assert ex.verdicts["f.same"] == "fail"
    assert ex.explanations["f.same"] == [("result", "4"), ("x", "3")]
    assert ex.observation == "result = 4"


def test_spec_errors_in_clauses():
    source = """
    spec t
    fn f(xs: list<i64>) -> i64
      ensures first: result == xs[0]
    """
    plan = plan_for(source, "f", {"f": lambda xs: 0})
    ex = plan.run({"xs": ()})
    assert ex.verdicts["f.first"] == "spec_error"
    assert "index 0 is out of range" in ex.notes["f.first"]
    assert ex.verdicts["f#type"] == "pass"


def test_requires_filters_every_item():
    source = """
    spec t
    fn f(x: i64) -> i64
      requires pos: x > 0
      ensures r: result == x
    """
    calls = []
    plan = plan_for(source, "f", {"f": lambda x: calls.append(x) or x})
    ex = plan.run({"x": -1})
    assert ex.status == "skipped" and ex.reason == "f.pos is false"
    assert set(ex.verdicts.values()) == {"skip"}
    assert calls == []
    assert plan.run({"x": 2}).verdicts["f.r"] == "pass"


def test_a_requires_that_cannot_be_evaluated_is_a_spec_error():
    source = """
    spec t
    fn f(xs: list<i64>) -> i64
      requires xs[0] > 0
    """
    plan = plan_for(source, "f", {"f": lambda xs: 0})
    ex = plan.run({"xs": ()})
    assert ex.status == "error"
    assert set(ex.verdicts.values()) == {"spec_error"}


def test_only_requested_items_are_judged():
    plan = plan_for(RAISES, "f", {"f": lambda x: x}, errors=ERRORS)
    assert plan.run({"x": 1}, ["f.same"]).verdicts == {"f.same": "pass"}


DEFAULTS = """
spec t
fn h(x: i64, y: i64 = 3, z: i64 = 4) -> i64
  ensures sum: result == x + y + z
"""


def test_default_arguments_are_omitted_and_their_value_is_used():
    seen = []

    def h(x, y=3, z=4):
        seen.append((x, y, z))
        return x + y + z

    plan = plan_for(DEFAULTS, "h", {"h": h})
    assert verdicts(plan, x=1, y=DEFAULT, z=10)["h.sum"] == "pass"
    assert verdicts(plan, x=1, y=DEFAULT, z=DEFAULT)["h.sum"] == "pass"
    assert seen == [(1, 3, 10), (1, 3, 4)]
    assert plan.format_inputs({"x": 1, "y": DEFAULT, "z": 2}) == {
        "x": "1",
        "y": "default (3)",
        "z": "2",
    }


def test_a_wrong_default_fails():
    plan = plan_for(DEFAULTS, "h", {"h": lambda x, y=5, z=4: x + y + z})
    assert verdicts(plan, x=1, y=DEFAULT, z=DEFAULT)["h.sum"] == "fail"
    assert verdicts(plan, x=1, y=3, z=DEFAULT)["h.sum"] == "pass"


BOX = """
spec t
model Box
  observe v: i64
  invariant nonneg: v >= 0
model Pos
  observe v: i64
  invariant positive: v > 0
fn peek(b: Box) -> i64
  ensures r: result == b.v
fn bump(b: Box, c: Box)
  modifies b
  ensures r: b.v == old(b.v) + 1
fn mk(n: i64) -> Box
  ensures r: result.v == n
  ensures fresh: fresh(result)
fn take(p: Pos) -> i64
  ensures r: result == p.v
"""


def box_conf(**impls):
    spec = spec_of(BOX)
    models = {
        "Box": ModelBinding(observers={"v": lambda o: o["v"]}, concretize=lambda f: dict(f)),
        "Pos": ModelBinding(observers={"v": lambda o: o["v"]}, concretize=lambda f: dict(f)),
    }
    return conformance(spec, impls=impls, models=models)


def box(v: int) -> GeneratedModel:
    return GeneratedModel("Box", (), {"v": v})


def test_items_of_functions_with_handles():
    conf = box_conf(peek=lambda b: b["v"], bump=lambda b, c: None, mk=lambda n: {"v": n})
    keys = lambda fn: [it.key for it in FunctionPlan(conf, conf.spec.fns[fn]).items]
    assert keys("peek") == ["peek.r", "peek#type", "peek#raises", "peek#frame"]
    assert keys("bump") == ["bump#1", "bump.r", "bump#type", "bump#raises", "bump:Box.nonneg"]
    assert keys("mk") == ["mk.r", "mk.fresh", "mk#type", "mk#raises", "mk:Box.nonneg"]
    plan = FunctionPlan(conf, conf.spec.fns["mk"])
    assert plan.item_name(plan.item("mk:Box.nonneg")) == "mk:Box.nonneg"


def test_frame_catches_a_mutating_implementation():
    def peek(b):
        b["v"] += 1
        return b["v"] - 1

    conf = box_conf(peek=peek)
    plan = FunctionPlan(conf, conf.spec.fns["peek"])
    ex = plan.run({"b": box(2)}, explain=True)
    assert ex.verdicts["peek#frame"] == "fail"
    assert ex.verdicts["peek.r"] == "fail"
    assert ex.notes["peek#frame"] == "the call changed b, but it may modify only nothing"
    assert ex.explanations["peek#frame"] == [
        ("b before", "Box { v: 2 }"),
        ("b after", "Box { v: 3 }"),
    ]
    assert "b before = Box { v: 2 }" in ex.observation
    good_conf = box_conf(peek=lambda b: b["v"])
    good = FunctionPlan(good_conf, good_conf.spec.fns["peek"])
    assert good.run({"b": box(2)}).verdicts["peek#frame"] == "pass"


def test_frame_is_checked_when_the_call_raises():
    def peek(b):
        b["v"] = 9
        raise RuntimeError("no")

    conf = box_conf(peek=peek)
    ex = FunctionPlan(conf, conf.spec.fns["peek"]).run({"b": box(1)})
    assert ex.verdicts["peek#frame"] == "fail"
    assert ex.verdicts["peek#raises"] == "fail"


def test_modifies_allows_only_the_listed_parameters():
    def bump(b, c):
        b["v"] += 1

    def bad(b, c):
        b["v"] += 1
        c["v"] += 1

    good_conf = box_conf(bump=bump)
    good = FunctionPlan(good_conf, good_conf.spec.fns["bump"])
    assert good.run({"b": box(1), "c": box(5)}).verdicts == {
        "bump#1": "pass",
        "bump.r": "pass",
        "bump#type": "pass",
        "bump#raises": "pass",
        "bump:Box.nonneg": "pass",
    }
    bad_conf = box_conf(bump=bad)
    plan = FunctionPlan(bad_conf, bad_conf.spec.fns["bump"])
    ex = plan.run({"b": box(1), "c": box(5)}, explain=True)
    assert ex.verdicts["bump#1"] == "fail"
    assert ex.notes["bump#1"] == "the call changed c, but it may modify only b"


def test_invariants_of_modified_and_returned_handles():
    def bump(b, c):
        b["v"] = -1

    conf = box_conf(bump=bump, mk=lambda n: {"v": n})
    ex = FunctionPlan(conf, conf.spec.fns["bump"]).run({"b": box(1), "c": box(1)}, explain=True)
    assert ex.verdicts["bump:Box.nonneg"] == "fail"
    assert ex.notes["bump:Box.nonneg"] == "Box.nonneg is false on b"
    mk = FunctionPlan(conf, conf.spec.fns["mk"])
    assert mk.run({"n": 3}).verdicts["mk:Box.nonneg"] == "pass"
    ex = mk.run({"n": -3})
    assert ex.verdicts["mk:Box.nonneg"] == "fail"
    assert ex.verdicts["mk.r"] == "pass"


def test_invariant_is_skipped_without_a_handle():
    conf = box_conf(mk=lambda n: (_ for _ in ()).throw(ValueError("x")))
    ex = FunctionPlan(conf, conf.spec.fns["mk"]).run({"n": 3})
    assert ex.verdicts["mk:Box.nonneg"] == "skip"


def test_fresh_compares_implementation_objects():
    shared = {"v": 1}
    conf = box_conf(mk=lambda n: shared)
    plan = FunctionPlan(conf, conf.spec.fns["mk"])
    assert plan.run({"n": 1}).verdicts["mk.fresh"] == "pass"
    source = """
    spec t
    model Box
      observe v: i64
    fn same(b: Box) -> Box
      ensures fresh: fresh(result)
      ensures ident: same_object(result, b)
    """
    spec = spec_of(source)
    binding = ModelBinding(observers={"v": lambda o: o["v"]}, concretize=lambda f: dict(f))
    conf = conformance(spec, impls={"same": lambda b: b}, models={"Box": binding})
    ex = FunctionPlan(conf, spec.fns["same"]).run({"b": box(1)})
    assert ex.verdicts["same.fresh"] == "fail"
    assert ex.verdicts["same.ident"] == "pass"


def test_unrepresentable_models_reject_the_example():
    def concretize(f):
        if f["v"] == 13:
            raise Unrepresentable("unlucky")
        return dict(f)

    spec = spec_of(BOX)
    conf = conformance(
        spec,
        impls={"peek": lambda b: b["v"]},
        models={"Box": ModelBinding(observers={"v": lambda o: o["v"]}, concretize=concretize)},
    )
    plan = FunctionPlan(conf, spec.fns["peek"])
    ex = plan.run({"b": box(13)})
    assert ex.status == "rejected" and "unlucky" in ex.reason
    assert set(ex.verdicts.values()) == {"skip"}
    assert plan.run({"b": box(12)}).verdicts["peek.r"] == "pass"


def test_a_failing_concretizer_is_a_spec_error():
    spec = spec_of(BOX)
    conf = conformance(
        spec,
        impls={"peek": lambda b: 0},
        models={"Box": ModelBinding(concretize=lambda f: 1 / 0)},
    )
    ex = FunctionPlan(conf, spec.fns["peek"]).run({"b": box(1)})
    assert ex.status == "error"
    assert set(ex.verdicts.values()) == {"spec_error"}
    assert "ZeroDivisionError" in ex.notes["peek.r"]


def strict_v(o: dict) -> int:
    """Box.v, refusing an object whose v is not an int (a value of another type)."""
    if not isinstance(o["v"], int):
        raise NotAValue(f"v is a {type(o['v']).__name__}")
    return o["v"]


def test_a_returned_object_the_binding_refuses_fails_type():
    # An observer raising NotAValue on the result charges the implementation: #type
    # fails, and the clauses that read the result skip instead of being spec errors.
    spec = spec_of(BOX)
    binding = ModelBinding(observers={"v": strict_v}, concretize=dict)
    conf = conformance(spec, impls={"mk": lambda n: {"v": str(n)}}, models={"Box": binding})
    plan = FunctionPlan(conf, spec.fns["mk"])
    ex = plan.run({"n": 3}, explain=True)
    assert ex.verdicts == {
        "mk.r": "skip",
        "mk.fresh": "pass",
        "mk#type": "fail",
        "mk#raises": "pass",
        "mk:Box.nonneg": "skip",
    }
    assert ex.notes["mk#type"] == (
        "the result is not Box: observer Box.v says the object is not a Box: v is a str"
    )
    assert ex.notes["mk.r"] == ex.notes["mk:Box.nonneg"] == "the result is not of its declared type"
    assert plan.run({"n": 3}, ["mk#type"]).verdicts == {"mk#type": "fail"}
    good = conformance(spec, impls={"mk": lambda n: {"v": n}}, models={"Box": binding})
    assert set(FunctionPlan(good, spec.fns["mk"]).run({"n": 3}).verdicts.values()) == {"pass"}


def test_a_planned_call_result_the_binding_refuses_skips_the_relation():
    source = """
    spec t
    model Box
      observe v: i64
    fn mk(n: i64) -> Box
    fn get(n: i64) -> i64
      relates r: mk(n).v == result
    """
    spec = spec_of(source)
    binding = ModelBinding(observers={"v": strict_v}, concretize=dict)
    conf = conformance(
        spec, impls={"mk": lambda n: {"v": str(n)}, "get": lambda n: n}, models={"Box": binding}
    )
    ex = FunctionPlan(conf, spec.fns["get"]).run({"n": 3})
    assert ex.verdicts["get.r"] == "skip"
    assert ex.notes["get.r"].startswith("planned call returned an object that is not a value")


def test_other_observer_failures_on_a_result_stay_spec_errors():
    spec = spec_of(BOX)
    binding = ModelBinding(observers={"v": lambda o: o["v"] + 0}, concretize=dict)
    conf = conformance(spec, impls={"mk": lambda n: {"v": str(n)}}, models={"Box": binding})
    ex = FunctionPlan(conf, spec.fns["mk"]).run({"n": 3})
    assert ex.verdicts["mk#type"] == "spec_error"
    assert ex.verdicts["mk.r"] == "spec_error"
    assert ex.verdicts["mk:Box.nonneg"] == "spec_error"
    assert "observer Box.v raised TypeError" in ex.notes["mk#type"]


def test_accepts_refuses_a_returned_object():
    spec = spec_of(BOX)
    binding = ModelBinding(
        observers={"v": lambda o: o["v"]}, concretize=dict, accepts=lambda o: isinstance(o, dict)
    )
    conf = conformance(spec, impls={"mk": lambda n: [n]}, models={"Box": binding})
    ex = FunctionPlan(conf, spec.fns["mk"]).run({"n": 3})
    assert ex.verdicts["mk#type"] == "fail"
    assert ex.verdicts["mk.r"] == ex.verdicts["mk:Box.nonneg"] == "skip"
    assert "the binding refuses this list as a Box: models['Box'].accepts refused it" in (
        ex.notes["mk#type"]
    )


def test_an_input_the_binding_refuses_is_a_spec_error():
    # A concretizer that builds an object its own observers refuse is the binding's fault.
    spec = spec_of(BOX)
    binding = ModelBinding(observers={"v": strict_v}, concretize=lambda f: {"v": str(f["v"])})
    conf = conformance(spec, impls={"peek": lambda b: 0}, models={"Box": binding})
    ex = FunctionPlan(conf, spec.fns["peek"]).run({"b": box(1)})
    assert ex.status == "error"
    assert set(ex.verdicts.values()) == {"spec_error"}
    assert "says the object is not a Box" in ex.notes["peek.r"]


def test_a_concretizer_that_builds_another_input_is_a_spec_error():
    spec = spec_of(BOX)
    binding = ModelBinding(observers={"v": lambda o: o["v"]}, concretize=lambda f: {"v": 0})
    conf = conformance(spec, impls={"peek": lambda b: b["v"]}, models={"Box": binding})
    ex = FunctionPlan(conf, spec.fns["peek"]).run({"b": box(5)})
    assert ex.status == "error"
    assert set(ex.verdicts.values()) == {"spec_error"}
    assert "observes as Box { v: 0 }, not as the generated Box { v: 5 }" in ex.notes["peek.r"]


def test_a_lossy_binding_shows_the_input_as_built():
    spec = spec_of(BOX)
    even = ModelBinding(
        observers={"v": lambda o: o["v"]}, concretize=lambda f: {"v": f["v"] // 2 * 2}, lossy=True
    )
    conf = conformance(spec, impls={"peek": lambda b: b["v"]}, models={"Box": even})
    plan = FunctionPlan(conf, spec.fns["peek"])
    ex = plan.run({"b": box(5)}, explain=True)
    assert ex.verdicts["peek.r"] == "pass"
    assert ex.observation.splitlines() == ["b as built = Box { v: 4 }", "result = 4"]
    assert plan.format_inputs({"b": box(5)}) == {"b": "Box { v: 5 }"}
    assert "as built" not in plan.run({"b": box(4)}, explain=True).observation


def test_residual_invariants_reject_generated_models():
    spec = spec_of(BOX)
    conf = conformance(
        spec,
        impls={"take": lambda p: p["v"]},
        models={"Pos": ModelBinding(observers={"v": lambda o: o["v"]}, concretize=dict)},
    )
    plan = FunctionPlan(conf, spec.fns["take"])
    assert [c.id for c in plan.residuals("Pos")] == ["Pos.positive"]
    ex = plan.run({"p": GeneratedModel("Pos", (), {"v": 0})})
    assert ex.status == "rejected"
    assert plan.run({"p": GeneratedModel("Pos", (), {"v": 4})}).verdicts["take.r"] == "pass"


def test_format_inputs_shows_generated_models_by_field():
    conf = box_conf(peek=lambda b: 0)
    plan = FunctionPlan(conf, conf.spec.fns["peek"])
    assert plan.format_inputs({"b": box(7)}) == {"b": "Box { v: 7 }"}


RELATES = """
spec t
fn g(x: i64) -> i64
  requires x != 7
  relates odd: g(-x) == -result
  relates twice: g(x + 1) == g(x + 1)
"""


def test_relates_calls_the_implementation_again():
    calls = []

    def g(x):
        calls.append(x)
        return x

    plan = plan_for(RELATES, "g", {"g": g})
    assert plan.run({"x": 3}, ["g.odd"]).verdicts == {"g.odd": "pass"}
    assert calls == [3, -3]
    calls.clear()
    assert plan.run({"x": 3}, ["g.twice"]).verdicts == {"g.twice": "pass"}
    assert calls == [3, 4]


def test_relates_skips_when_a_planned_call_raises_or_is_outside_requires():
    def g(x):
        if x == -3:
            raise ValueError("no")
        return x

    plan = plan_for(RELATES, "g", {"g": g})
    ex = plan.run({"x": 3}, ["g.odd"])
    assert ex.verdicts["g.odd"] == "skip"
    assert "planned call g(-3) raised ValueError: no" in ex.notes["g.odd"]
    ex = plan.run({"x": -7}, ["g.odd"])
    assert ex.verdicts["g.odd"] == "skip"
    assert "outside g#1" in ex.notes["g.odd"]


def test_relates_is_skipped_when_the_base_call_raises_and_fails_when_false():
    plan = plan_for(RELATES, "g", {"g": lambda x: abs(x)})
    ex = plan.run({"x": 3}, ["g.odd"], explain=True)
    assert ex.verdicts["g.odd"] == "fail"
    assert ("g(-x)", "3") in ex.explanations["g.odd"]
    plan = plan_for(RELATES, "g", {"g": raising(lambda x: ValueError())})
    assert plan.run({"x": 3}, ["g.odd"]).verdicts["g.odd"] == "skip"


def test_planned_calls_need_a_bound_implementation():
    source = """
    spec t
    fn p(x: i64) -> i64
      relates r: q(result) == x
    fn q(x: i64) -> i64
    """
    plan = plan_for(source, "p", {"p": lambda x: x})
    ex = plan.run({"x": 1}, ["p.r"])
    assert ex.verdicts["p.r"] == "spec_error"
    assert "bind it in impls" in ex.notes["p.r"]


def test_planned_calls_memoize_and_read_results():
    spec = spec_of(RELATES)
    calls = []

    def g(x):
        calls.append(x)
        return "bad" if x == 2 else x

    conf = conformance(spec, impls={"g": g})
    planner = PlannedCalls(conf, spec, {})
    assert planner("g", (1,)) == 1
    assert planner("g", (1,)) == 1
    with pytest.raises(SkipClause, match="returned a value that is not i64"):
        planner("g", (2,))
    with pytest.raises(SkipClause):
        planner("g", (2,))
    assert calls == [1, 2]
    assert planner.calls == 2
    assert memo_key("g", (1,)) == memo_key("g", (1,)) != memo_key("g", (2,))


@pytest.mark.skipif(not can_time_out(), reason="needs SIGALRM on the main thread")
def test_a_timeout_is_inconclusive():
    def slow(x):
        time.sleep(1)
        return x

    plan = plan_for(RAISES, "f", {"f": slow}, errors=ERRORS)
    plan.timeout = 0.05
    started = time.perf_counter()
    ex = plan.run({"x": 1})
    assert time.perf_counter() - started < 0.9
    assert ex.status == "timeout"
    assert set(ex.verdicts.values()) == {"inconclusive"}


def test_invoke_records_warnings_and_keeps_error_filters():
    import warnings

    def noisy():
        warnings.warn("careful", RuntimeWarning, stacklevel=1)
        return 1

    with warnings.catch_warnings():
        warnings.simplefilter("always")
        out = invoke(noisy)
    assert out == CallOutcome("returned", 1, warnings=["RuntimeWarning: careful"])
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        out = invoke(noisy)
    assert out.kind == "raised" and isinstance(out.exc, RuntimeWarning)
    plan = plan_for(RAISES, "f", {"f": lambda x: noisy() and x}, errors=ERRORS)
    with warnings.catch_warnings():
        warnings.simplefilter("always")
        ex = plan.run({"x": 2}, explain=True)
    assert ex.observation == "result = 2\nwarned: RuntimeWarning: careful"


def test_invoke_outcomes():
    assert invoke(lambda: 3) == CallOutcome("returned", 3)
    out = invoke(lambda: 1 / 0)
    assert out.kind == "raised" and isinstance(out.exc, ZeroDivisionError)
    assert invoke(lambda a, b=0: a + b, [1], {"b": 2}, timeout=1.0).value == 3


def test_coverage_of_set_and_predicate_partitions():
    source = """
    spec t
    fn c(x: f64, xs: list<i64>) -> f64
      partition x
        nan  = f64.nan
        rest = f64.all - f64.nan
      partition xs
        empty = len(xs) == 0
        other = len(xs) > 0
    """
    from spectest.generate import partitions

    spec = spec_of(source)
    conf = conformance(spec, impls={"c": lambda x, xs: x})
    plan = FunctionPlan(conf, spec.fns["c"])
    infos = partitions(spec.fns["c"], spec)
    nan = floats.nan("f64")
    ex = plan.run({"x": nan, "xs": ()}, coverage=infos)
    assert ex.coverage == {"x": "nan", "xs": "empty"}
    ex = plan.run({"x": floats.from_python_float(1.0), "xs": (1,)}, coverage=infos)
    assert ex.coverage == {"x": "rest", "xs": "other"}


def test_generic_functions_use_their_instantiation():
    source = """
    spec t
    fn first<T: Eq>(xs: list<T>) -> T
      requires len(xs) > 0
      ensures r: result == xs[0]
    """
    spec = spec_of(source)
    conf = conformance(spec, impls={"first": lambda xs: xs[0]}, instantiate=[{"T": "i64"}])
    plan = FunctionPlan(conf, spec.fns["first"], {"T": I64})
    assert plan.label == "first[T=i64]"
    assert plan.item_name(plan.item("first.r")) == "first[T=i64].r"
    assert plan.types == [ListT(I64)]
    assert plan.run({"xs": (4, 5)}).verdicts["first.r"] == "pass"
    bad = FunctionPlan(
        conformance(spec, impls={"first": lambda xs: "x"}, instantiate=[{"T": "i64"}]),
        spec.fns["first"],
        {"T": I64},
    )
    assert bad.run({"xs": (4,)}).verdicts["first#type"] == "fail"


def test_labels_and_handles_in_values():
    assert decl_label("sort", {}) == "sort"
    assert decl_label("sort", {"T": I64}) == "sort[T=i64]"
    h = Handle(object(), "Box")
    t = ListT(ModelT("Box"))
    assert [x for x, _ in handles_in((h, h), t)] == [h, h]


def test_the_observation_shows_every_handle_the_function_may_modify():
    def bump(b, c):
        b["v"] += 1

    def lazy(b, c):
        copy = dict(b)
        copy["v"] += 1

    def bad(b, c):
        c["v"] += 1

    def run(impl):
        conf = box_conf(bump=impl)
        plan = FunctionPlan(conf, conf.spec.fns["bump"])
        return plan.run({"b": box(1), "c": box(5)}, explain=True)

    assert run(bump).observation == "b after = Box { v: 2 }"
    assert run(lazy).observation == "b after = Box { v: 1 } (unchanged)"
    assert run(bad).observation.splitlines() == [
        "b after = Box { v: 1 } (unchanged)",
        "c before = Box { v: 5 }",
        "c after  = Box { v: 6 }",
    ]

    def raises(b, c):
        raise RuntimeError("no")

    assert run(raises).observation.splitlines() == [
        "raised RuntimeError: no (no spec error maps it)",
        "b after = Box { v: 1 } (unchanged)",
    ]


def test_skip_causes():
    from spectest.runtime.plans import Example, skip_cause

    impl = raising(lambda x: A_() if x < 0 else None)
    plan = plan_for(RAISES, "f", {"f": impl}, errors=ERRORS)
    ex = plan.run({"x": -5})
    assert ex.verdicts["f.same"] == "skip" and skip_cause(ex, "f.same") == "raised"
    assert ex.verdicts["f.b"] == "skip" and skip_cause(ex, "f.b") == "raise due"
    due = Example({}, notes={"g.sign": "raise due (g#1)", "g.x": "planned call g(1) raised E"})
    assert skip_cause(due, "g.sign") == "raise due"
    assert skip_cause(due, "g.x") == "planned call"
    assert skip_cause(due, "g.y") == "other"
    source = """
    spec t
    fn f(x: i64) -> i64
      requires x > 0
      ensures same: result == x
    """
    guarded = plan_for(source, "f", {"f": lambda x: x})
    ex = guarded.run({"x": -1})
    assert skip_cause(ex, "f.same") == "requires"

    def refuse(fields):
        raise Unrepresentable("no such box")

    spec = spec_of(BOX)
    models = {"Box": ModelBinding(observers={"v": lambda o: o["v"]}, concretize=refuse)}
    conf = conformance(spec, impls={"peek": lambda b: 0}, models=models)
    ex = FunctionPlan(conf, spec.fns["peek"]).run({"b": box(1)})
    assert skip_cause(ex, "peek.r") == "unrepresentable"
    pos_conf = box_conf(take=lambda p: p["v"])
    take = FunctionPlan(pos_conf, pos_conf.spec.fns["take"])
    ex = take.run({"p": GeneratedModel("Pos", (), {"v": -1})})
    assert ex.status == "rejected" and skip_cause(ex, "take.r") == "rejected"
