"""Shrinking: reduce a failing choice sequence while it keeps failing the same property."""

from std.builtin.sort import sort

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
    var pid: Int

    def __init__(out self, var best: Choices, pid: Int, budget: Int):
        self.best = best^
        self.src = Source(0, 1 << 30)
        self.steps = 0
        self.budget = budget
        self.pid = pid

    def exhausted(self) -> Bool:
        return self.steps >= self.budget


def _attempt[P: Property](mut prop: P, mut st: _State, cand: List[UInt64]) raises -> Bool:
    """Replay `cand`; keep it when valid, failing the same property, and smaller."""
    if st.exhausted() or not smaller(cand, st.best.values):
        return False
    st.steps += 1
    st.src.reset_replay(cand)
    var out = run_example(prop, st.src)
    if out is None or not out.value().failed(st.pid) or not smaller(st.src.rec.values, st.best.values):
        return False
    st.best = st.src.rec.copy()
    return True


def _without(values: List[UInt64], start: Int, end: Int) -> List[UInt64]:
    return List(values[:start]) + List(values[end:])


def _longer(a: Span, b: Span) -> Bool:
    return a.length() > b.length()


def _pass_delete_spans[P: Property](mut prop: P, mut st: _State) raises:
    var i = 0
    while not st.exhausted():
        var spans = st.best.spans.copy()
        sort[stable=True](spans, _longer)
        if i >= len(spans):
            return
        if not _attempt(prop, st, _without(st.best.values, spans[i].start, spans[i].end)):
            i += 1


def _pass_delete_single[P: Property](mut prop: P, mut st: _State) raises:
    var i = len(st.best.values) - 1
    while i >= 0 and not st.exhausted():
        if i < len(st.best.values):
            _ = _attempt(prop, st, _without(st.best.values, i, i + 1))
        i -= 1


def _pass_zero[P: Property](mut prop: P, mut st: _State) raises:
    var i = 0
    while i < len(st.best.values) and not st.exhausted():
        if st.best.values[i] != 0:
            var cand = st.best.values.copy()
            cand[i] = 0
            _ = _attempt(prop, st, cand)
        i += 1


def _lower[P: Property](mut prop: P, mut st: _State, at: List[Int]) raises:
    """Lower the choices at `at` together, by the largest powers of two that keep failing."""
    for k in reversed(range(64)):
        var step = UInt64(1) << UInt64(k)
        while all([p < len(st.best.values) and st.best.values[p] >= step for p in at]):
            var cand = st.best.values.copy()
            for p in at:
                cand[p] -= step
            if not _attempt(prop, st, cand):
                break


def _pass_minimize[P: Property](mut prop: P, mut st: _State) raises:
    var i = 0
    while i < len(st.best.values) and not st.exhausted():
        _lower(prop, st, [i])
        i += 1


def _pass_redistribute[P: Property](mut prop: P, mut st: _State) raises:
    """Lower one choice while raising a later one."""
    var i = 0
    while i < len(st.best.values) and not st.exhausted():
        var j = i + 1
        while j < len(st.best.values) and j <= i + 16 and not st.exhausted():
            var vi = st.best.values[i]
            if vi == 0:
                break
            var room = st.best.bounds[j] - st.best.values[j]
            for d in [vi, vi // 2, UInt64(1)]:
                if d == 0 or d > room:
                    continue
                var cand = st.best.values.copy()
                cand[i] -= d
                cand[j] += d
                if _attempt(prop, st, cand):
                    break
            j += 1
        i += 1


def _pass_equal_values[P: Property](mut prop: P, mut st: _State) raises:
    """Lower every choice holding one value together, by the largest steps that keep failing."""
    var seen = List[UInt64]()
    var i = 0
    while i < len(st.best.values) and not st.exhausted():
        var v = st.best.values[i]
        i += 1
        if v == 0 or v in seen:
            continue
        seen.append(v)
        var at = [p for p in range(len(st.best.values)) if st.best.values[p] == v]
        if len(at) < 2:
            continue
        var k = 63
        while k >= 0 and not st.exhausted():
            var step = UInt64(1) << UInt64(k)
            while v >= step:
                var cand = st.best.values.copy()
                for p in at:
                    cand[p] -= step
                if not _attempt(prop, st, cand):
                    break
                # the failure changed shape, so the positions are stale
                if len(st.best.values) != len(cand) or st.best.values[at[0]] != v - step:
                    k = -1
                    break
                v -= step
            k -= 1


def _pass_pairs[P: Property](mut prop: P, mut st: _State) raises:
    """Lower two nearby choices by the same amount."""
    var i = 0
    while i < len(st.best.values) and not st.exhausted():
        var j = i + 1
        while j < len(st.best.values) and j <= i + 8 and not st.exhausted():
            _lower(prop, st, [i, j])
            j += 1
        i += 1


def shrink[P: Property](
    mut prop: P, choices: Choices, property_id: Int, budget: Int
) raises -> Choices:
    """The smallest sequence found that still fails `property_id`, in at most `budget` replays."""
    var st = _State(choices.copy(), property_id, budget)
    while not st.exhausted():
        var before = st.best.values.copy()
        _pass_delete_spans(prop, st)
        _pass_delete_single(prop, st)
        _pass_zero(prop, st)
        _pass_minimize(prop, st)
        _pass_redistribute(prop, st)
        _pass_equal_values(prop, st)
        _pass_pairs(prop, st)
        if not smaller(st.best.values, before):
            break
    return st.best.copy()
