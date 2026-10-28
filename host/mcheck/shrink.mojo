"""Shrinking: reduce a failing choice sequence while it keeps failing the same property."""

from std.collections import Set

from .choices import Choices, Span
from .property import Property, run_example
from .source import Source


def smaller(a: List[UInt64], b: List[UInt64]) -> Bool:
    """The shrink order: shorter first, then lexicographically smaller."""
    if len(a) != len(b):
        return len(a) < len(b)
    for x, y in zip(a, b):
        if x != y:
            return x < y
    return False


struct _State(Movable):
    var best: Choices
    var src: Source
    var steps: Int
    var budget: Int
    var property_id: Int

    def __init__(out self, var best: Choices, property_id: Int, budget: Int):
        self.best = best^
        self.src = Source(0, 1 << 30)
        self.steps = 0
        self.budget = budget
        self.property_id = property_id

    def exhausted(self) -> Bool:
        return self.steps >= self.budget


def _attempt[P: Property](mut prop: P, mut state: _State, candidate: List[UInt64]) raises -> Bool:
    """Replay `candidate`; keep it when valid, failing the same property, and smaller."""
    if state.exhausted() or not smaller(candidate, state.best.values):
        return False
    state.steps += 1
    state.src.reset_replay(candidate)
    var out = run_example(prop, state.src)
    if (
        out is None
        or not out.value().failed(state.property_id)
        or not smaller(state.src.rec.values, state.best.values)
    ):
        return False
    state.best = state.src.rec.copy()
    return True


def _without(values: List[UInt64], start: Int, end: Int) -> List[UInt64]:
    return List(values[:start]) + List(values[end:])


def _pass_delete_spans[P: Property](mut prop: P, mut state: _State) raises:
    var i = 0
    while not state.exhausted():
        var spans = state.best.spans.copy()
        sort[stable=True](spans, lambda (a: Span, b: Span) -> Bool: a.length() > b.length())
        if i >= len(spans):
            return
        if not _attempt(prop, state, _without(state.best.values, spans[i].start, spans[i].end)):
            i += 1


def _pass_delete_single[P: Property](mut prop: P, mut state: _State) raises:
    var i = len(state.best.values) - 1
    while i >= 0 and not state.exhausted():
        if i < len(state.best.values):
            _ = _attempt(prop, state, _without(state.best.values, i, i + 1))
        i -= 1


def _pass_zero[P: Property](mut prop: P, mut state: _State) raises:
    var i = 0
    while i < len(state.best.values) and not state.exhausted():
        if state.best.values[i] != 0:
            var candidate = state.best.values.copy()
            candidate[i] = 0
            _ = _attempt(prop, state, candidate)
        i += 1


def _lower[P: Property](mut prop: P, mut state: _State, at: List[Int]) raises:
    """Lower the choices at `at` together, by the largest powers of two that keep failing."""
    for k in reversed(range(64)):
        var step = UInt64(1) << UInt64(k)
        while all([p < len(state.best.values) and state.best.values[p] >= step for p in at]):
            var candidate = state.best.values.copy()
            for p in at:
                candidate[p] -= step
            if not _attempt(prop, state, candidate):
                break


def _pass_minimize[P: Property](mut prop: P, mut state: _State) raises:
    var i = 0
    while i < len(state.best.values) and not state.exhausted():
        _lower(prop, state, [i])
        i += 1


def _pass_redistribute[P: Property](mut prop: P, mut state: _State) raises:
    """Lower one choice while raising a later one."""
    var i = 0
    while i < len(state.best.values) and not state.exhausted():
        var j = i + 1
        while j < len(state.best.values) and j <= i + 16 and not state.exhausted():
            var vi = state.best.values[i]
            if vi == 0:
                break
            var room = state.best.bounds[j] - state.best.values[j]
            for d in [vi, vi // 2, UInt64(1)]:
                if d == 0 or d > room:
                    continue
                var candidate = state.best.values.copy()
                candidate[i] -= d
                candidate[j] += d
                if _attempt(prop, state, candidate):
                    break
            j += 1
        i += 1


def _lower_equal[P: Property](mut prop: P, mut state: _State, at: List[Int], var value: UInt64) raises:
    """Lower the choices at `at`, which all hold `value`, together by the largest steps
    that keep failing."""
    for k in reversed(range(64)):
        if state.exhausted():
            return
        var step = UInt64(1) << UInt64(k)
        while value >= step:
            var candidate = state.best.values.copy()
            for p in at:
                candidate[p] -= step
            if not _attempt(prop, state, candidate):
                break
            # the failure changed shape, so the positions are stale
            if len(state.best.values) != len(candidate) or state.best.values[at[0]] != value - step:
                return
            value -= step


def _pass_equal_values[P: Property](mut prop: P, mut state: _State) raises:
    """Lower every choice holding one value together."""
    var seen: Set[UInt64] = {}
    var i = 0
    while i < len(state.best.values) and not state.exhausted():
        var v = state.best.values[i]
        i += 1
        if v == 0 or v in seen:
            continue
        seen.add(v)
        var at = [p for p, x in enumerate(state.best.values) if x == v]
        if len(at) >= 2:
            _lower_equal(prop, state, at, v)


def _pass_pairs[P: Property](mut prop: P, mut state: _State) raises:
    """Lower two nearby choices by the same amount."""
    var i = 0
    while i < len(state.best.values) and not state.exhausted():
        var j = i + 1
        while j < len(state.best.values) and j <= i + 8 and not state.exhausted():
            _lower(prop, state, [i, j])
            j += 1
        i += 1


def shrink[P: Property](
    mut prop: P, choices: Choices, property_id: Int, budget: Int
) raises -> Choices:
    """The smallest sequence found that still fails `property_id`, in at most `budget` replays."""
    var state = _State(choices.copy(), property_id, budget)
    while not state.exhausted():
        var before = state.best.values.copy()
        _pass_delete_spans(prop, state)
        _pass_delete_single(prop, state)
        _pass_zero(prop, state)
        _pass_minimize(prop, state)
        _pass_redistribute(prop, state)
        _pass_equal_values(prop, state)
        _pass_pairs(prop, state)
        if not smaller(state.best.values, before):
            break
    return state.best.copy()
