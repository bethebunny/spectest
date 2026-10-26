"""Shrinking: reduce a failing choice sequence while it keeps failing the same property."""

from .choices import Choices, Span
from .property import Property, Outcome, FAILED
from .source import Source


def smaller(a: List[UInt64], b: List[UInt64]) -> Bool:
    """The shrink order: shorter first, then lexicographically smaller."""
    if len(a) != len(b):
        return len(a) < len(b)
    for i in range(len(a)):
        if a[i] != b[i]:
            return a[i] < b[i]
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
    var out: Outcome
    try:
        out = prop.run(st.src)
    except e:
        if st.src.invalid:
            return False
        raise e^
    if out.is_invalid:
        return False
    var hit = False
    for k in range(len(out.ids)):
        if out.ids[k] == st.pid and out.results[k] == FAILED:
            hit = True
    if not hit or not smaller(st.src.rec.values, st.best.values):
        return False
    st.best = st.src.rec.copy()
    return True


def _without(values: List[UInt64], start: Int, end: Int) -> List[UInt64]:
    var out = List[UInt64]()
    for i in range(len(values)):
        if i < start or i >= end:
            out.append(values[i])
    return out^


def _pass_delete_spans[P: Property](mut prop: P, mut st: _State) raises:
    var i = 0
    while not st.exhausted():
        var spans = st.best.spans.copy()
        # Larger spans first (insertion sort; span lists are short).
        for a in range(1, len(spans)):
            var s = spans[a]
            var b = a
            while b > 0 and spans[b - 1].length() < s.length():
                spans[b] = spans[b - 1]
                b -= 1
            spans[b] = s
        if i >= len(spans):
            return
        var s = spans[i]
        if not _attempt(prop, st, _without(st.best.values, s.start, s.end)):
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


def _pass_minimize[P: Property](mut prop: P, mut st: _State) raises:
    """Lower each choice by the largest powers of two that keep it failing."""
    var i = 0
    while i < len(st.best.values) and not st.exhausted():
        var k = 63
        while k >= 0 and i < len(st.best.values) and not st.exhausted():
            var step = UInt64(1) << UInt64(k)
            while i < len(st.best.values) and st.best.values[i] >= step:
                var cand = st.best.values.copy()
                cand[i] -= step
                if not _attempt(prop, st, cand):
                    break
            k -= 1
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
            var ds = List[UInt64]()
            ds.append(vi)
            ds.append(vi // 2)
            ds.append(1)
            for d in ds:
                if d == 0 or d > vi or d > room:
                    continue
                var cand = st.best.values.copy()
                cand[i] -= d
                cand[j] += d
                if _attempt(prop, st, cand):
                    break
            j += 1
        i += 1


def shrink[P: Property](
    mut prop: P, choices: Choices, property_id: Int, budget: Int
) raises -> Choices:
    """The smallest sequence found that still fails `property_id`.

    At most `budget` replays. A candidate is kept only when its replay is valid and
    fails the same property.
    """
    var st = _State(choices.copy(), property_id, budget)
    while not st.exhausted():
        var before = st.best.values.copy()
        _pass_delete_spans(prop, st)
        _pass_delete_single(prop, st)
        _pass_zero(prop, st)
        _pass_minimize(prop, st)
        _pass_redistribute(prop, st)
        if not smaller(st.best.values, before):
            break
    return st.best.copy()
