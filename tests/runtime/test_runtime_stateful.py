"""Stateful tests of interfaces: rules, the frame rule, invariants and step logs."""

from __future__ import annotations

import textwrap
from pathlib import Path
from typing import ClassVar

import pytest
from budget import budget
from hypothesis import HealthCheck, settings
from hypothesis import seed as hyp_seed
from hypothesis.stateful import invariant, run_state_machine_as_test

from spectest.lang import load, load_source
from spectest.runtime.binding import ConformanceError, InterfaceBinding, conformance
from spectest.runtime.report import render_failure
from spectest.runtime.runner import Runner, RunOptions, collect_items
from spectest.runtime.stateful import (
    MAX_HANDLES,
    STEP_COUNT,
    InterfacePlan,
    Recorder,
    build_machine,
    decode_program,
    encode_program,
    interface_expected,
    interface_outcome,
    minimize,
    replay,
    shorten,
)
from spectest.runtime.store import CounterexampleStore

STACK = """
spec t
error Empty

interface Stack<T: Eq>
  observe items: list<T>
  INVARIANT

  new empty() -> Stack
    ensures blank: len(result.items) == 0

  method push(self, x: T)
    modifies self
    ensures pushed: self.items == old(self.items) + [x]

  method pop(self) -> T
    raises Empty when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
    ensures rest: self.items == old(self.items)[0:len(old(self.items)) - 1]

  method size(self) -> u64
    ensures n: result == len(self.items)
"""


class EmptyError(Exception):
    pass


class Stack:
    def __init__(self):
        self.items = []

    def push(self, x):
        self.items.append(x)

    def pop(self):
        if not self.items:
            raise EmptyError()
        return self.items.pop()

    def size(self):
        return len(self.items)


class PopsFirst(Stack):
    def pop(self):
        if not self.items:
            raise EmptyError()
        return self.items.pop(0)


class SizeTouches(Stack):
    def size(self):
        self.items.append(0)
        return len(self.items)


class Unbounded(Stack):
    pass


class PopFillsWhenEmpty(Stack):
    def pop(self):
        if not self.items:
            self.items.append(7)
            raise EmptyError()
        return self.items.pop()


class PeekFillsWhenEmpty(Stack):
    def peek(self):
        if not self.items:
            self.items.append(7)
            raise EmptyError()
        return self.items[-1]


PEEK = STACK + """
  method peek(self) -> T
    raises Empty when len(self.items) == 0
    ensures top: result == self.items[len(self.items) - 1]
"""


def spec_of(source: str):
    return load_source(textwrap.dedent(source).lstrip("\n"), "t.spec")


def stack_conf(cls, invariant: str = "", **options):
    source = STACK.replace("INVARIANT", invariant or "invariant small: len(items) <= 100")
    return conformance(
        spec_of(source),
        interfaces={"Stack": InterfaceBinding(constructors={"empty": cls})},
        errors={EmptyError: "Empty"},
        instantiate={"T": "i64"},
        **options,
    )


def run(conf, runner=None):
    (item,) = collect_items(conf)
    runner = runner or Runner(RunOptions(max_examples=budget(30, 10)))
    results = runner.run(item, "t::c::Stack", "repro")
    return item, {r.clause_id: r for r in results}


def test_plan_lists_every_tallied_clause():
    conf = stack_conf(Stack)
    (item,) = collect_items(conf)
    assert item.name == "Stack[T=i64]"
    plan: InterfacePlan = item.plan
    assert [k.key for k in plan.keys] == [
        "Stack.empty.blank",
        "Stack.empty#type",
        "Stack.empty#raises",
        "Stack.push#1",
        "Stack.push.pushed",
        "Stack.push#type",
        "Stack.push#raises",
        "Stack.pop#1",
        "Stack.pop#2",
        "Stack.pop.value",
        "Stack.pop.rest",
        "Stack.pop#type",
        "Stack.pop#raises",
        "Stack.size.n",
        "Stack.size#type",
        "Stack.size#raises",
        "Stack.size#frame",
        "Stack.small",
    ]


@pytest.mark.slow
def test_a_correct_implementation_passes_except_the_invariant():
    conf = stack_conf(Stack, "invariant small: len(items) <= 3", expect_fail={"Stack.small"})
    item, results = run(conf)
    failing = {k for k, r in results.items() if r.failed}
    assert failing == {"Stack.small"}
    assert interface_outcome(list(results.values()), item.expected) == "xfailed"
    for key in ("Stack.pop.value", "Stack.pop#1", "Stack.push.pushed", "Stack.size#frame"):
        assert results[key].counts["pass"] > 0, key
    small = results["Stack.small"].counterexample
    steps = small.observation.splitlines()
    assert steps[0] == "steps:"
    assert steps[1] == "1. s1 = Stack.empty()"
    assert len([s for s in steps if ". s1.push(" in s]) == 4


@pytest.mark.slow
def test_seeded_bug_fails_with_a_short_step_log():
    item, results = run(stack_conf(PopsFirst))
    failing = {k for k, r in results.items() if r.failed}
    assert "Stack.pop.value" in failing
    assert interface_outcome(list(results.values()), item.expected) == "failed"
    cx = results["Stack.pop.value"].counterexample
    steps = [line for line in cx.observation.splitlines() if line[:1].isdigit()]
    assert steps[0] == "1. s1 = Stack.empty()"
    assert len(steps) <= 5
    assert steps[-1].startswith(f"{len(steps)}. s1.pop() -> ")
    assert "Stack.pop.value is false" in cx.observation
    assert cx.inputs["self"].startswith("s1 = Stack { items: [")
    assert cx.reproduce == "repro"
    text = render_failure(results["Stack.pop.value"])
    assert "Stack[T=i64].pop.value (ensures) failed" in text
    assert "(stateful)" in text


def test_the_frame_rule_catches_an_observer_method_that_mutates():
    _, results = run(stack_conf(SizeTouches))
    assert {k for k, r in results.items() if r.failed} == {"Stack.size#frame"}
    frame = results["Stack.size#frame"]
    assert frame.failed
    cx = frame.counterexample
    assert "the call changed s1, but it may modify only nothing" in cx.observation
    assert any(e.startswith("s1 before") for e, _ in cx.explanation)


def test_after_a_raise_a_modified_handle_may_be_in_any_state():
    # pop modifies self, so what it leaves behind when it raises Empty is the implementation's.
    _, results = run(stack_conf(PopFillsWhenEmpty))
    assert not [k for k, r in results.items() if r.failed]
    assert results["Stack.pop.rest"].counts["skip"] > 0, "pop raised on some empty stack"


def test_after_a_raise_a_handle_the_method_does_not_modify_is_unchanged():
    conf = conformance(
        spec_of(PEEK.replace("INVARIANT", "")),
        interfaces={"Stack": InterfaceBinding(constructors={"empty": PeekFillsWhenEmpty})},
        errors={EmptyError: "Empty"},
        instantiate={"T": "i64"},
    )
    _, results = run(conf)
    assert {k for k, r in results.items() if r.failed} == {"Stack.peek#frame"}


@pytest.mark.slow
def test_expected_failures_of_an_interface():
    conf = stack_conf(
        Stack, "invariant small: len(items) <= 3", expect_fail={"Stack.small", "Stack.pop.value"}
    )
    (item,) = collect_items(conf)
    assert interface_expected(conf, conf.spec.interfaces["Stack"]) == {
        "Stack.small",
        "Stack.pop.value",
    }
    assert item.expected == {"Stack.small", "Stack.pop.value"}
    _, results = run(conf)
    assert results["Stack.small"].outcome == "xfailed"
    assert results["Stack.pop.value"].outcome == "xpassed"
    # strict per clause: pop.value never failed, so the item is an unexpected pass
    assert interface_outcome(list(results.values()), item.expected) == "xpassed"


def test_an_expected_clause_the_item_never_judges_is_an_unexpected_pass():
    conf = conformance(
        spec_of(STACK.replace("INVARIANT", "") + "  new full() -> Stack\n"),
        interfaces={"Stack": InterfaceBinding(constructors={"empty": Stack})},
        errors={EmptyError: "Empty"},
        instantiate={"T": "i64"},
        expect_fail={"Stack.full#type"},
    )
    item, results = run(conf)
    stub = results["Stack.full#type"]
    assert stub.expected_fail and not stub.failed and stub.outcome == "xpassed"
    assert interface_outcome(list(results.values()), item.expected) == "xpassed"


@pytest.mark.slow
def test_raises_in_methods():
    class NeverRaises(Stack):
        def pop(self):
            return self.items.pop() if self.items else 0

    _, results = run(stack_conf(NeverRaises))
    pop = results["Stack.pop#1"]
    assert pop.failed
    assert "Empty was due" in pop.counterexample.observation
    steps = [line for line in pop.counterexample.observation.splitlines() if line[:1].isdigit()]
    assert steps == ["1. s1 = Stack.empty()", "2. s1.pop() -> 0"]


@pytest.mark.slow
def test_interfaces_with_several_handles_check_other_handles_unchanged():
    shared: list[int] = []

    class Shared(Stack):
        def __init__(self):
            self.items = shared

    _, results = run(stack_conf(Shared))
    assert results["Stack.push#1"].failed or results["Stack.empty.blank"].failed


def test_collections_deque_conforms_to_the_deque_example():
    from collections import deque
    from pathlib import Path

    from spectest.lang import load

    spec = load(Path(__file__).resolve().parents[2] / "examples" / "deque" / "deque.spec")
    conf = conformance(
        spec,
        interfaces={
            "Deque": InterfaceBinding(
                constructors={"empty": deque, "bounded": lambda n: deque(maxlen=n)},
                observers={"items": list, "maxlen": lambda d: d.maxlen},
            )
        },
        errors={IndexError: "IndexError"},
        instantiate=[{"T": "i64"}, {"T": "string"}],
    )
    items = collect_items(conf)
    assert [it.name for it in items] == ["Deque[T=i64]", "Deque[T=string]"]
    for item in items:
        results = Runner(RunOptions(max_examples=budget(25, 5))).run(item, f"t::{item.name}", "")
        assert interface_outcome(results, item.expected) == "passed", [
            render_failure(r) for r in results if r.failed or r.has_spec_errors
        ]
        by = {r.clause_id: r for r in results}
        assert by["Deque.pop#1"].counts["pass"] > 0
        assert by["Deque.rotate.items"].counts["pass"] > 0


# -- deeper states: the handle cap, recent handles, small integers, the step count --------


DEQUE_SPEC = Path(__file__).resolve().parents[2] / "examples" / "deque" / "deque.spec"


class ListDeque:
    """A list deque, bounded when maxlen is given."""

    def __init__(self, maxlen=None):
        self.items = []
        self.maxlen = maxlen

    def append(self, x):
        self.items.append(x)
        if self.maxlen is not None and len(self.items) > self.maxlen:
            del self.items[0]

    def appendleft(self, x):
        self.items.insert(0, x)
        if self.maxlen is not None and len(self.items) > self.maxlen:
            del self.items[-1]

    def pop(self):
        if not self.items:
            raise IndexError("pop from an empty deque")
        return self.items.pop()

    def popleft(self):
        if not self.items:
            raise IndexError("pop from an empty deque")
        return self.items.pop(0)

    def rotate(self, n=1):
        if self.items:
            cut = len(self.items) - n % len(self.items)
            self.items[:] = self.items[cut:] + self.items[:cut]


class WrongEnd(ListDeque):
    """appendleft on a full deque drops the item it just added (examples/deque's bug (a))."""

    def appendleft(self, x):
        self.items.insert(0, x)
        if self.maxlen is not None and len(self.items) > self.maxlen:
            del self.items[0]


def deque_conf(cls=ListDeque, constructors=("empty", "bounded"), t="i64", **options):
    ctors = {"empty": lambda: cls(), "bounded": lambda n: cls(maxlen=n)}
    return conformance(
        load(DEQUE_SPEC),
        interfaces={
            "Deque": InterfaceBinding(
                constructors={name: ctors[name] for name in constructors},
                observers={"items": lambda d: list(d.items), "maxlen": lambda d: d.maxlen},
            )
        },
        errors={IndexError: "IndexError"},
        instantiate={"T": t},
        **options,
    )


def machine_of(conf):
    (item,) = collect_items(conf)
    recorder = Recorder(item.plan)
    return item.plan, recorder, build_machine(item.plan, recorder)


def run_machine(machine, max_examples=40, seed=0):
    test = hyp_seed(seed)(machine)
    run_state_machine_as_test(
        test,
        settings=settings(
            max_examples=max_examples,
            deadline=None,
            database=None,
            suppress_health_check=list(HealthCheck),
            stateful_step_count=30,
        ),
    )


def test_constructors_run_only_while_fewer_than_max_handles_are_live():
    for cap in (1, 2, 3):
        _, _, machine = machine_of(deque_conf(max_handles=cap))

        class Counted(machine):  # type: ignore[valid-type, misc]
            seen: ClassVar[list[int]] = []

            @invariant()
            def live_handles(self):
                self.seen.append(len(self.live))

        run_machine(Counted, max_examples=budget(40, 3))
        assert max(Counted.seen) == cap, cap


def test_the_default_cap_is_two_handles():
    plan, _, _ = machine_of(deque_conf())
    assert plan.max_handles == MAX_HANDLES == 2
    assert plan.steps == STEP_COUNT == 30


@pytest.mark.slow
def test_methods_prefer_the_handle_used_last():
    _, _, machine = machine_of(deque_conf(max_handles=2))
    same: list[bool] = []

    class Watched(machine):  # type: ignore[valid-type, misc]
        def step(self, cp, args, h):
            if h is not None and len(self.live) == 2:
                same.append(h is self.recent[0])
            super().step(cp, args, h)

    run_machine(Watched)
    assert len(same) > 200
    assert sum(same) / len(same) > 0.65


def test_integer_arguments_are_small_three_times_in_four():
    plan, _, machine = machine_of(deque_conf())
    small = {cp.decl.name: cp.small for cp in [*plan.ctors, *plan.methods]}
    assert small["bounded"] == {"n": (0, 1, 2, 3, 4)}
    assert small["rotate"] == {"n": (0, 1, -1, 2, -2, 3, -3, 4, -4)}
    # x: T is a T, not a declared integer, even when T = i64
    assert small["append"] == {} and small["empty"] == {}
    sizes: list[int] = []
    turns: list[int] = []

    class Watched(machine):  # type: ignore[valid-type, misc]
        def step(self, cp, args, h):
            if cp.decl.name == "bounded":
                sizes.append(args["n"])
            if cp.decl.name == "rotate":
                turns.append(args["n"])
            super().step(cp, args, h)

    run_machine(Watched, max_examples=budget(60, 10))
    assert sum(n <= 4 for n in sizes) / len(sizes) > 0.65
    assert sum(-4 <= n < 0 for n in turns) / len(turns) > 0.2


def test_small_values_stay_inside_what_requires_admits():
    conf = conformance(
        spec_of(
            STACK.replace("INVARIANT", "")
            + "  new sized(n: u8) -> Stack\n    requires n >= 2\n    ensures blank: len(result.items) == 0\n"
        ),
        interfaces={"Stack": InterfaceBinding(constructors={"sized": lambda n: Stack()})},
        errors={EmptyError: "Empty"},
        instantiate={"T": "i64"},
    )
    plan, _, _ = machine_of(conf)
    (sized,) = plan.ctors
    assert sized.small == {"n": (2, 3, 4)}


COUNTER = """
spec counter
interface Counter
  observe value: i64
  new zero() -> Counter
    ensures z: result.value == 0
  method inc(self)
    modifies self
    ensures up: self.value == old(self.value) + 1
"""


class Jumps:
    """Counts up by one, but by two from 3 on: the bug needs four increments."""

    def __init__(self):
        self.value = 0

    def inc(self):
        self.value += 1 if self.value < 3 else 2


def counter_conf(cls=Jumps, **options):
    return conformance(
        spec_of(COUNTER),
        interfaces={"Counter": InterfaceBinding(constructors={"zero": cls})},
        **options,
    )


@pytest.mark.slow
def test_steps_bounds_each_step_sequence():
    _, short = run(counter_conf(steps=4))
    assert not any(r.failed for r in short.values())
    assert short["Counter.inc.up"].counts["pass"] > 0
    _, long = run(counter_conf())
    cx = long["Counter.inc.up"].counterexample
    assert [s for s in cx.observation.splitlines() if s[:1].isdigit()][-1] == "5. c1.inc()"


def test_steps_and_max_handles_are_validated():
    with pytest.raises(ConformanceError) as caught:
        counter_conf(steps=0, max_handles="2")
    text = str(caught.value)
    assert "steps must be a positive integer, got 0" in text
    assert "max_handles must be a positive integer, got '2'" in text


# -- coverage, verdict counts ---------------------------------------------------------------


PARTITIONED = """
spec counter
interface Counter
  observe value: i64
  new zero() -> Counter
    ensures z: result.value == 0
  method add(self, n: i8)
    partition n
      negative = i8.range(none, 0)
      zero     = {0}
      positive = i8.range(1, none)
    modifies self
    ensures up: self.value == old(self.value) + n
  method extend(self, xs: list<i64>)
    partition xs
      empty = len(xs) == 0
      some  = len(xs) > 0
    modifies self
    ensures up: self.value == old(self.value) + len(xs)
"""


class Adder:
    def __init__(self):
        self.value = 0

    def add(self, n):
        self.value += n

    def extend(self, xs):
        self.value += len(xs)


@pytest.mark.slow
def test_interface_items_record_partition_coverage_of_method_parameters():
    conf = conformance(
        spec_of(PARTITIONED), interfaces={"Counter": InterfaceBinding(constructors={"zero": Adder})}
    )
    _, results = run(conf, Runner(RunOptions(max_examples=budget(40, 15))))
    add = results["Counter.add.up"]
    assert list(add.coverage) == ["n: negative", "n: zero", "n: positive"]
    assert all(n > 0 for n in add.coverage.values()), add.coverage
    assert sum(add.coverage.values()) == add.counts["pass"]
    extend = results["Counter.extend.up"]
    assert list(extend.coverage) == ["xs: empty", "xs: some"]
    assert all(n > 0 for n in extend.coverage.values()), extend.coverage
    assert list(results["Counter.add#type"].coverage) == list(add.coverage)
    assert results["Counter.zero.z"].coverage == {}


class TwoBugs(Stack):
    def pop(self):
        return self.items.pop() if self.items else 0

    def size(self):
        return len(self.items) + 1


def test_each_failing_clause_counts_verdicts_up_to_its_first_failure():
    _, results = run(stack_conf(TwoBugs))
    failing = {k for k, r in results.items() if r.failed}
    assert {"Stack.pop#1", "Stack.size.n"} <= failing
    for key in failing:
        assert results[key].counts["fail"] == 1, (key, results[key].counts)


# -- shrinking ------------------------------------------------------------------------------


def test_minimize_lowers_a_constructor_argument_with_the_steps_that_fill_it():
    """bounded(n=12), twelve appends and appendleft: making n smaller alone, or deleting one
    append alone, stops the failure; lowering n while deleting an append does not."""
    plan, recorder, machine = machine_of(deque_conf(WrongEnd, ("bounded",), t="string"))
    appends = [("call", "append", 0, {"x": "0" if i == 0 else ""}) for i in range(12)]
    program = decode_program(
        plan,
        [("new", "bounded", None, {"n": 12}), *appends, ("call", "appendleft", 0, {"x": ""})],
    )
    assert program is not None
    found = replay(machine, program, recorder)
    assert found is not None and found.key == "Deque.appendleft.items"
    assert len(found.log) == 14
    assert shorten(machine, found, recorder).log == found.log
    best = minimize(machine, found, recorder)
    assert best.key == "Deque.appendleft.items"
    assert best.log == ["d1 = Deque.bounded(n=1)", 'd1.append(x="0")', 'd1.appendleft(x="")']


@pytest.mark.slow
def test_a_search_finds_the_wrong_end_bug_with_a_minimal_log():
    conf = deque_conf(WrongEnd, ("bounded",), t="string")
    _, results = run(conf, Runner(RunOptions(max_examples=100)))
    cx = results["Deque.appendleft.items"].counterexample
    steps = [s for s in cx.observation.splitlines() if s[:1].isdigit()]
    assert steps[0] == "1. d1 = Deque.bounded(n=1)"
    assert len(steps) == 3


# -- the counterexample store ---------------------------------------------------------------


@pytest.mark.slow
def test_failing_programs_are_stored_and_replayed_first(tmp_path):
    runner = Runner(RunOptions(max_examples=30, store=tmp_path))
    _, first = run(counter_conf(), runner)
    found = first["Counter.inc.up"].counterexample
    assert "replayed" not in found.observation
    assert list((tmp_path / "counterexamples").rglob("*.json"))
    # with two steps per sequence the search cannot reach the bug; the stored program can
    _, again = run(counter_conf(steps=2), Runner(RunOptions(max_examples=30, store=tmp_path)))
    replayed = again["Counter.inc.up"]
    assert replayed.failed
    assert "(replayed from the counterexample store under .spectest/" in (
        replayed.counterexample.observation
    )
    steps = [s for s in found.observation.splitlines() if s[:1].isdigit()]
    assert [s for s in replayed.counterexample.observation.splitlines() if s[:1].isdigit()] == steps
    assert replayed.counts["fail"] == 1
    assert replayed.replayed and not again["Counter.zero.z"].replayed
    assert again["Counter.zero.z"].counts["pass"] > 0
    _, fresh = run(counter_conf(steps=2), Runner(RunOptions(max_examples=30)))
    assert not fresh["Counter.inc.up"].failed


def test_stored_programs_round_trip_and_unfit_ones_are_dropped(tmp_path):
    plan, recorder, machine = machine_of(deque_conf(WrongEnd))
    program = decode_program(
        plan,
        [
            ("new", "bounded", None, {"n": 1}),
            ("new", "empty", None, {}),
            ("call", "append", 0, {"x": 5}),
            ("call", "rotate", 1, {"n": -3}),
            ("call", "appendleft", 0, {"x": 6}),
        ],
    )
    assert program is not None
    store = CounterexampleStore(tmp_path)
    store.save("h", "item", {"clause": "c", "steps": encode_program(program)})
    (entry,) = store.load("h", "item", spec=plan.spec)
    decoded = decode_program(plan, entry["steps"])
    assert decoded is not None
    assert [(s.cp, s.args, s.target) for s in decoded] == [
        (s.cp, s.args, s.target) for s in program
    ]
    found = replay(machine, decoded, recorder)
    assert found is not None and found.key == "Deque.appendleft.items"
    assert decode_program(plan, [("call", "nosuch", None, {})]) is None
    assert decode_program(plan, [("new", "empty", None, {"x": 1})]) is None
    assert decode_program(plan, [("call", "pop", 0, {})]) is None
    assert decode_program(plan, "not steps") is None


# -- speed: observations carried from one step to the next ----------------------------------


def test_each_step_observes_the_state_once():
    """The post-state's observations are the next pre-state's, and a method that modifies
    self needs no digest of its receiver."""
    calls = {"items": 0, "digest": 0}

    def items(s):
        calls["items"] += 1
        return list(s.items)

    def digest(s):
        calls["digest"] += 1
        return tuple(s.items)

    conf = conformance(
        spec_of(STACK.replace("INVARIANT", "invariant small: len(items) <= 100")),
        interfaces={
            "Stack": InterfaceBinding(
                constructors={"empty": Stack}, observers={"items": items}, digest=digest
            )
        },
        errors={EmptyError: "Empty"},
        instantiate={"T": "i64"},
    )
    plan, recorder, machine = machine_of(conf)
    program = decode_program(
        plan, [("new", "empty", None, {}), *[("call", "push", 0, {"x": i}) for i in range(5)]]
    )
    assert replay(machine, program, recorder) is None
    assert calls == {"items": 6, "digest": 0}


def test_method_arguments_follow_the_conformances_sizes():
    from spectest.generate import Sizes

    lengths: dict[int, list[int]] = {}
    for max_list in (2, 30):
        conf = conformance(
            spec_of(PARTITIONED),
            interfaces={"Counter": InterfaceBinding(constructors={"zero": Adder})},
            sizes=Sizes(max_list=max_list, long_share=0),
        )
        _, _, machine = machine_of(conf)

        class Watched(machine):  # type: ignore[valid-type, misc]
            seen: ClassVar[list[int]] = []

            def step(self, cp, args, h):
                if cp.decl.name == "extend":
                    self.seen.append(len(args["xs"]))
                super().step(cp, args, h)

        run_machine(Watched, max_examples=budget(30, 4))
        lengths[max_list] = Watched.seen
    assert max(lengths[2]) <= 2
    assert max(lengths[30]) > 8


@pytest.mark.slow
def test_explicit_examples_are_not_replaced_by_small_values(monkeypatch):
    from hypothesis import find
    from hypothesis import strategies as st
    from hypothesis.errors import NoSuchExample

    from spectest.runtime import stateful

    monkeypatch.setattr(stateful, "SMALL_SHARE", st.just(0))
    plan, _, _ = machine_of(deque_conf(examples={"Deque.bounded": [{"n": 200}]}))
    (bounded,) = [cp for cp in plan.ctors if cp.decl.name == "bounded"]
    once = settings(database=None, max_examples=500, suppress_health_check=list(HealthCheck))
    assert find(bounded.strategy, lambda a: a["n"] == 200, settings=once) == {"n": 200}
    with pytest.raises(NoSuchExample):
        find(bounded.strategy, lambda a: a["n"] not in (0, 1, 2, 3, 4, 200), settings=once)
