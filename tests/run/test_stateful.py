"""Interfaces: step sequences on a deque-like class, modeled on examples/deque."""

from __future__ import annotations

import re

import pytest
from support import load

HEAD = """\
spec stateful

error IndexError

interface {cls}<T: Eq>
  observe items: list<T>{items}
  observe maxlen: option<u8>
  invariant within_bound: is_none(maxlen) or len(items) <= unwrap(maxlen)

  new __init__(iterable: list<T>, maxlen: option<u8>) -> {cls}
    ensures maxlen: result.maxlen == maxlen
    ensures bound: is_none(maxlen) or len(result.items) <= unwrap(maxlen)
"""

BOUNDED = """
  new bounded(n: u8) -> {cls}
    ensures items: len(result.items) == 0
    ensures maxlen: result.maxlen == some(n)
"""

METHODS = """
  method append(self, x: T)
    modifies self
    ensures items: let ys = old(self.items) + [x] in
      self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)
                     then ys[len(ys) - unwrap(self.maxlen):len(ys)] else ys)
    ensures maxlen: self.maxlen == old(self.maxlen)

  method appendleft(self, x: T)
    modifies self
    ensures items: let ys = [x] + old(self.items) in
      self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen)
                     then ys[0:unwrap(self.maxlen)] else ys)

  method pop(self) -> T
    raises IndexError when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
    ensures items: self.items == old(self.items)[0:len(old(self.items)) - 1]

  method popleft(self) -> T
    raises IndexError when len(self.items) == 0
    modifies self
    ensures value: result == old(self.items)[0]
    ensures items: self.items == old(self.items)[1:len(old(self.items))]

  method rotate(self, n: i8)
    modifies self
    ensures items: let xs = old(self.items) in
      self.items == (if len(xs) == 0 then xs
                     else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)])
"""

PEEK = """
  method peek(self) -> T
    raises IndexError when len(self.items) == 0
    ensures value: result == old(self.items)[len(old(self.items)) - 1]
"""

# Only the invariant says anything about the items, and appends may not touch the bound.
INVARIANT_ONLY = """
  method append(self, x: T)
    modifies self
    ensures maxlen: self.maxlen == old(self.maxlen)
"""


def spec_text(cls: str, *, items: str = "", extra: str = "", methods: str = METHODS) -> str:
    return (HEAD + BOUNDED + methods + extra).replace("{cls}", cls).replace("{items}", items)


def run(tmp_path, cls: str, text: str | None = None, **options):
    spec = load(tmp_path, text or spec_text(f"stateimpls.{cls}", extra=PEEK))
    try:
        options.setdefault("instantiation", {"T": "i64"})
        return spec.run(f"stateimpls.{cls}", **options)
    finally:
        spec.close()


def steps_of(cx) -> list[str]:
    lines = cx["observation"].split("\n")
    assert lines[0] == "steps:"
    out = []
    for line in lines[1:]:
        head, _, rest = line.partition(". ")
        if not head.isdigit():
            break
        out.append(rest)
    return out


def test_a_correct_class_passes_every_clause(tmp_path):
    r = run(tmp_path, "Deque")
    assert r.passed_all(), r.spec_errors()
    assert r.mode == "search"
    assert r.examples == 100
    ids = set(r.clauses)
    assert {
        "stateimpls.Deque.__init__.maxlen",
        "stateimpls.Deque.bounded.items",
        "stateimpls.Deque.append.items",
        "stateimpls.Deque.append#1",  # modifies self
        "stateimpls.Deque.pop#1",  # raises IndexError
        "stateimpls.Deque.pop#2",  # modifies self
        "stateimpls.Deque.pop.value",
        "stateimpls.Deque.pop#type",
        "stateimpls.Deque.pop#raises",
        "stateimpls.Deque.peek#frame",
        "stateimpls.Deque.within_bound",
    } <= ids
    # No frame item for a method that modifies self.
    assert "stateimpls.Deque.pop#frame" not in ids
    for c in r.clauses.values():
        assert c["mode"] == "stateful"
        assert c["instantiation"] == {"T": "i64"}
        assert c["counterexample"] is None
    # Every constructor and method was called; the invariant is judged after every call.
    assert r.counts("stateimpls.Deque.pop.items")["pass"] > 0
    assert r.counts("stateimpls.Deque.bounded.maxlen")["pass"] > 0
    calls = sum(
        r.counts(c)["pass"] for c in ("stateimpls.Deque.__init__#type", "stateimpls.Deque.bounded#type")
    )
    assert r.counts("stateimpls.Deque.within_bound")["pass"] >= calls
    # pop on an empty deque raises IndexError, which skips the ensures clauses.
    assert r["stateimpls.Deque.pop.value"]["skips"]["raised"] > 0


def test_the_items_of_an_interface_are_its_members_clauses(tmp_path):
    spec = load(tmp_path, spec_text("stateimpls.Deque", extra=PEEK))
    try:
        items = spec.items()
    finally:
        spec.close()
    assert {i["decl"] for i in items} == {"stateimpls.Deque"}
    by_id = {i["clause_id"]: i for i in items}
    assert by_id["stateimpls.Deque.pop#1"]["kind"] == "raises"
    assert by_id["stateimpls.Deque.pop#2"]["kind"] == "modifies"
    assert by_id["stateimpls.Deque.peek#frame"]["kind"] == "frame"
    assert by_id["stateimpls.Deque.within_bound"]["kind"] == "invariant"
    assert by_id["stateimpls.Deque.__init__#type"]["kind"] == "type"
    assert by_id["stateimpls.Deque.append.items"]["tparams"] == ["T"]


# -- seeded bugs --------------------------------------------------------------------


def test_a_pop_from_the_wrong_end_fails_the_pop_clauses(tmp_path):
    r = run(tmp_path, "PopWrongEnd")
    assert r.failed() == ["stateimpls.PopWrongEnd.pop.value", "stateimpls.PopWrongEnd.pop.items"]
    cx = r.cx("stateimpls.PopWrongEnd.pop.value")
    steps = steps_of(cx)
    assert len(steps) <= 5
    assert re.fullmatch(r"p1 = stateimpls\.PopWrongEnd(\.bounded)?\(.*\)", steps[0])
    assert steps[-1].startswith("p1.pop() -> ")
    assert "p1 = " in cx["inputs"]["self"]
    assert "result = " in cx["observation"]
    assert any(src == "old(self.items)" for src, _ in cx["explanation"])


def test_a_bounded_append_that_does_not_evict_fails_the_append_clause(tmp_path):
    r = run(tmp_path, "NoEvict")
    assert "stateimpls.NoEvict.append.items" in r.failed()
    assert "stateimpls.NoEvict.rotate.items" not in r.failed()
    cx = r.cx("stateimpls.NoEvict.append.items")
    steps = steps_of(cx)
    assert len(steps) <= 3
    assert steps[0].startswith("n1 = stateimpls.NoEvict.bounded(n=")
    assert steps[-1].startswith("n1.append(x=")
    # The bound is zero, the smallest bound that an append can break.
    assert steps[0].endswith("n=0)")


def test_a_rotate_off_by_one_fails_the_rotate_clause(tmp_path):
    r = run(tmp_path, "RotateOffByOne")
    assert r.failed() == ["stateimpls.RotateOffByOne.rotate.items"]
    steps = steps_of(r.cx("stateimpls.RotateOffByOne.rotate.items"))
    assert len(steps) <= 5
    assert steps[-1].startswith("r1.rotate(n=")


def test_a_failure_is_reproducible(tmp_path):
    a = run(tmp_path, "RotateOffByOne", seed=7)
    b = run(tmp_path, "RotateOffByOne", seed=7)
    clause = "stateimpls.RotateOffByOne.rotate.items"
    assert a.cx(clause)["observation"] == b.cx(clause)["observation"]


# -- invariants -----------------------------------------------------------------------


def test_invariants_are_checked_after_every_call(tmp_path):
    text = spec_text("stateimpls.NoEvict", methods=INVARIANT_ONLY)
    r = run(tmp_path, "NoEvict", text)
    # The append clauses say nothing about the items: only the invariant notices.
    assert r.failed() == ["stateimpls.NoEvict.within_bound"]
    cx = r.cx("stateimpls.NoEvict.within_bound")
    steps = steps_of(cx)
    assert steps[-1].startswith("n1.append(x=")
    assert "within_bound is false on n1" in cx["observation"]
    assert cx["inputs"]["n1"].startswith("stateimpls.NoEvict {")
    assert any(src == "len(items)" for src, _ in cx["explanation"])
    # It was judged after every step of every sequence, and held until the bug.
    assert r.counts("stateimpls.NoEvict.within_bound")["pass"] > 100


def test_invariants_are_checked_on_every_live_object(tmp_path):
    text = spec_text("stateimpls.BreaksOther", methods=INVARIANT_ONLY)
    r = run(tmp_path, "BreaksOther", text)
    assert "stateimpls.BreaksOther.within_bound" in r.failed()
    cx = r.cx("stateimpls.BreaksOther.within_bound")
    steps = steps_of(cx)
    receiver = re.match(r"(b\d)\.append", steps[-1])
    assert receiver
    broken = re.search(r"is false on (b\d)", cx["observation"]).group(1)
    assert broken != receiver.group(1)
    assert len(cx["inputs"]) == 2


# -- modifies and the frame rule -----------------------------------------------------


def test_a_method_that_changes_another_live_object_breaks_modifies(tmp_path):
    r = run(tmp_path, "Leaky")
    assert r.failed() == ["stateimpls.Leaky.pop#2"]
    cx = r.cx("stateimpls.Leaky.pop#2")
    assert re.search(r"the call changed l\d, but it may modify only self \(l\d\)", cx["observation"])
    assert re.search(r"l\d before = ", cx["observation"])
    assert re.search(r"l\d after  = ", cx["observation"])
    assert steps_of(cx)[-1].startswith("l")


def test_a_method_with_no_modifies_must_leave_every_object_unchanged(tmp_path):
    r = run(tmp_path, "PeekMutates")
    assert r.failed() == ["stateimpls.PeekMutates.peek#frame"]
    cx = r.cx("stateimpls.PeekMutates.peek#frame")
    assert "may modify only nothing" in cx["observation"]
    assert steps_of(cx)[-1].startswith("p1.peek() -> ")


# -- the handle cap and the step count ------------------------------------------------


def test_the_handle_cap_bounds_the_live_objects(tmp_path):
    # With one object at a time, no call can change another one.
    one = run(tmp_path, "Leaky", max_handles=1)
    assert one.passed_all(), one.spec_errors()
    # With two, it can; and a third is never made.
    two = run(tmp_path, "Leaky", max_handles=2)
    assert two.failed() == ["stateimpls.Leaky.pop#2"]
    log = "\n".join(steps_of(two.cx("stateimpls.Leaky.pop#2")))
    assert "l2 = " in log and "l3" not in log
    three = run(tmp_path, "Leaky", max_handles=3, seed=3)
    assert three.failed() == ["stateimpls.Leaky.pop#2"]


def test_the_step_count_bounds_the_sequence(tmp_path):
    r = run(tmp_path, "PopWrongEnd", steps=2)
    # A deque needs two items before the wrong end shows: no 2-step sequence reaches it
    # unless the constructor is given them, which the sequence may.
    for cid in r.failed():
        assert len(steps_of(r.cx(cid))) <= 2
    one = run(tmp_path, "PopWrongEnd", steps=1)
    assert one.passed_all()
    made = sum(one.counts(f"stateimpls.PopWrongEnd.{c}#type")["pass"] for c in ("__init__", "bounded"))
    assert made == one.examples
    assert one.counts("stateimpls.PopWrongEnd.pop.value")["pass"] == 0


# -- the store ----------------------------------------------------------------------


def test_a_failing_sequence_is_stored_and_replayed_first(tmp_path):
    store = str(tmp_path / "store")
    first = run(tmp_path, "RotateOffByOne", store=store)
    clause = "stateimpls.RotateOffByOne.rotate.items"
    assert first.failed() == [clause]
    assert first.mode == "search"
    assert not first[clause]["replayed"]
    second = run(tmp_path, "RotateOffByOne", store=store)
    assert second.mode == "replay"
    assert second[clause]["replayed"]
    assert second.failed() == [clause]
    assert steps_of(second.cx(clause)) == steps_of(first.cx(clause))
    # A replay needs no luck: a search with no examples still finds the failure.
    only = run(tmp_path, "RotateOffByOne", store=store, max_examples=1)
    assert only.failed() == [clause]
    assert only[clause]["replayed"]


def test_the_store_keeps_each_failing_clause(tmp_path):
    store = str(tmp_path / "store")
    first = run(tmp_path, "NoEvict", store=store)
    second = run(tmp_path, "NoEvict", store=store)
    assert second.failed() == first.failed()
    for cid in first.failed():
        assert second[cid]["replayed"], cid
        assert steps_of(second.cx(cid)) == steps_of(first.cx(cid)), cid


def test_a_correct_class_stores_nothing(tmp_path):
    store = tmp_path / "store"
    r = run(tmp_path, "Deque", store=str(store))
    assert r.passed_all()
    assert not store.exists() or not list(store.iterdir())


# -- collections.deque ----------------------------------------------------------------


def test_collections_deque_satisfies_the_spec(tmp_path):
    text = spec_text("collections.deque", items=" = builtins.list(self)", extra="").replace(
        "\n  new bounded(n: u8) -> collections.deque\n    ensures items: len(result.items) == 0\n"
        "    ensures maxlen: result.maxlen == some(n)\n",
        "",
    )
    spec = load(tmp_path, text)
    try:
        r = spec.run("collections.deque", seed=1, instantiation={"T": "i64"})
        assert r.passed_all(), r.spec_errors()
        assert r.counts("collections.deque.pop.value")["pass"] > 0
        assert r.counts("collections.deque.__init__.bound")["pass"] > 0
        assert r.counts("collections.deque.within_bound")["pass"] > 100
        again = spec.run("collections.deque", seed=2, instantiation={"T": "string"}, max_examples=30)
        assert again.passed_all(), again.spec_errors()
    finally:
        spec.close()


# -- errors in the spec ---------------------------------------------------------------


def test_an_interface_with_no_constructor_cannot_be_run(tmp_path):
    spec = load(
        tmp_path,
        "spec s\n\ninterface stateimpls.Deque\n  observe items: list<i64>\n"
        "  method pop(self) -> i64\n    ensures anything: true\n",
    )
    try:
        with pytest.raises(Exception, match="no constructor"):
            spec.run("stateimpls.Deque")
    finally:
        spec.close()
