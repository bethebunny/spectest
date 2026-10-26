"""deque conformance: collections.deque and five seeded bugs.

The conformances run as pytest items, one per Deque instantiation (T = i64 and
T = string); each item is a stateful search that judges every clause of the
interface. The plain test functions at the end check, without spectest, what
examples/deque/FINDINGS.md states: each seeded bug's counterexample, replayed
on the buggy class and on collections.deque. explore_deque.py measures which
edge cases the collections.deque search exercised.
"""

from __future__ import annotations

import collections

import deque_impls
import pytest
from deque_bindings import COLLECTIONS_DEQUE, ERRORS, INSTANTIATE, deque_binding

import spectest

spec = spectest.load("deque.spec")

# Both constructors. A step sequence holds at most two deques and calls methods mostly on
# the one used last, and bounded(n) draws n from 0 to 4 three times in four, so bounded
# deques fill up and drop items: explore_deque.py checks that every edge case of
# FINDINGS.md, "What the collections.deque search exercised", runs (at 300 examples for
# every seed tried; 200 missed one at some seeds).
test_collections_deque = spectest.conformance(
    spec,
    interfaces={"Deque": COLLECTIONS_DEQUE},
    errors=ERRORS,
    instantiate=INSTANTIATE,
    max_examples=300,
)

# The seeded bugs, one conformance each so that each failing step log is minimal.
# FINDINGS.md lists each counterexample. Bug (a) needs a full bounded deque and (b) one of
# three or more items; the search finds both at nearly every --spectest-seed (FINDINGS.md,
# "Seed sensitivity"), and a failing step log is replayed from .spectest/ on later runs.

test_seeded_appendleft_wrong_end = spectest.conformance(
    spec,
    interfaces={"Deque": deque_binding(deque_impls.WrongEndDeque)},
    errors=ERRORS,
    instantiate=INSTANTIATE,
    # (a) appendleft on a full bounded deque drops the new item instead of the rightmost.
    expect_fail={"Deque.appendleft.items"},
)

test_seeded_rotate_backwards = spectest.conformance(
    spec,
    interfaces={"Deque": deque_binding(deque_impls.BackwardRotateDeque)},
    errors=ERRORS,
    instantiate=INSTANTIATE,
    # (b) rotate(n) rotates to the left.
    expect_fail={"Deque.rotate.items"},
)

test_seeded_popleft_returns_none = spectest.conformance(
    spec,
    interfaces={"Deque": deque_binding(deque_impls.PopleftNoneDeque)},
    errors=ERRORS,
    instantiate=INSTANTIATE,
    expect_fail={
        # (c) popleft on an empty deque returns instead of raising IndexError ...
        "Deque.popleft#1",
        # ... and what it returns, None, is not a T.
        "Deque.popleft#type",
    },
)

test_seeded_pop_raises_keyerror = spectest.conformance(
    spec,
    interfaces={"Deque": deque_binding(deque_impls.SlotDeque)},
    errors=ERRORS,
    instantiate=INSTANTIATE,
    expect_fail={
        # (d) pop on an empty deque raises KeyError, not the IndexError that is due ...
        "Deque.pop#1",
        # ... and no spec error maps KeyError, so nothing admits it.
        "Deque.pop#raises",
    },
)

test_seeded_rotate_loses_bound = spectest.conformance(
    spec,
    interfaces={"Deque": deque_binding(deque_impls.RebuildingDeque)},
    errors=ERRORS,
    instantiate=INSTANTIATE,
    # (e) rotate rebuilds the deque without its maxlen. The original deque.spec had no
    # clause that keeps maxlen fixed, so this bug passed it (FINDINGS.md, spec changes).
    expect_fail={"Deque.rotate.maxlen"},
)


# ---------------------------------------------------------------------------
# The findings, checked without spectest


@pytest.mark.parametrize(("old", "new"), [(1, 0), ("0", "")], ids=["i64", "string"])
def test_seeded_appendleft_drops_the_new_item(old: object, new: object) -> None:
    """The counterexample: bounded(n=1), append(old), appendleft(new)."""
    bug, real = deque_impls.WrongEndDeque(maxlen=1), collections.deque(maxlen=1)
    for d in (bug, real):
        d.append(old)
        d.appendleft(new)
    assert (list(bug), list(real)) == ([old], [new])
    bug, real = deque_impls.WrongEndDeque(maxlen=2), collections.deque(maxlen=2)
    for d in (bug, real):
        d.append(1)
        d.append(2)
        d.appendleft(0)
    assert (list(bug), list(real)) == ([1, 2], [0, 1])


@pytest.mark.parametrize(
    ("maxlen", "items", "bug_after", "real_after"),
    [
        (None, [0, 0, 1], [0, 1, 0], [1, 0, 0]),
        (3, ["0", "", ""], ["", "", "0"], ["", "0", ""]),
    ],
    ids=["i64", "string"],
)
def test_seeded_rotate_goes_left(
    maxlen: int | None, items: list, bug_after: list, real_after: list
) -> None:
    """The counterexample: empty() (bounded(n=3) for T = string), three appends, rotate(n=1)."""
    bug = deque_impls.BackwardRotateDeque(maxlen=maxlen)
    real = collections.deque(maxlen=maxlen)
    for x in items:
        bug.append(x)
        real.append(x)
    bug.rotate(1)
    real.rotate(1)
    assert (list(bug), list(real)) == (bug_after, real_after)


def test_seeded_popleft_returns_none_on_an_empty_deque() -> None:
    for maxlen in (None, 0):
        assert deque_impls.PopleftNoneDeque(maxlen=maxlen).popleft() is None
        with pytest.raises(IndexError):
            collections.deque(maxlen=maxlen).popleft()


def test_seeded_pop_raises_keyerror_on_an_empty_deque() -> None:
    for maxlen in (None, 0):
        with pytest.raises(KeyError) as caught:
            deque_impls.SlotDeque(maxlen=maxlen).pop()
        assert caught.value.args == (-1,)
        with pytest.raises(IndexError):
            collections.deque(maxlen=maxlen).pop()
    assert not issubclass(KeyError, IndexError)


def test_seeded_rotate_loses_the_bound() -> None:
    bug, real = deque_impls.RebuildingDeque(maxlen=0), collections.deque(maxlen=0)
    bug.rotate(0)
    real.rotate(0)
    assert (bug.maxlen, real.maxlen) == (None, 0)
    bug, real = deque_impls.RebuildingDeque(maxlen=1), collections.deque(maxlen=1)
    for d in (bug, real):
        d.append(1)
        d.rotate(1)
        d.append(2)
    assert (list(bug), list(real)) == ([1, 2], [2])


def test_list_deque_baseline_matches_collections_deque() -> None:
    """The bug classes override one method of ListDeque; it agrees with collections.deque
    on these sequences (the conformances check it in general)."""
    for maxlen in (None, 0, 1, 2, 3):
        mine, real = deque_impls.ListDeque(maxlen=maxlen), collections.deque(maxlen=maxlen)
        for step, x in enumerate([5, 6, 7, 8]):
            for d in (mine, real):
                (d.append if step % 2 else d.appendleft)(x)
            assert list(mine) == list(real)
        for n in (-128, -5, -1, 0, 1, 2, 7, 127):
            mine.rotate(n)
            real.rotate(n)
            assert list(mine) == list(real)
