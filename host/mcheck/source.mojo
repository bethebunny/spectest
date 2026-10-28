"""Source: what generators draw from. It generates or replays a choice sequence."""

from .choices import Choices, Span
from .rand import Rng


comptime INVALID_MESSAGE = "mcheck: invalid example"
comptime MANY_LABEL = -1


def int_anchor(lo: Int, hi: Int) -> Int:
    """The value encoded as 0: zero if in range, else the bound nearest to zero."""
    if lo <= 0 <= hi:
        return 0
    return lo if lo > 0 else hi


def int_to_index(x: Int, lo: Int, hi: Int) -> UInt64:
    """Encode x in [lo, hi] so that values near the anchor get small indices.

    Indices alternate above and below the anchor (0, +1, -1, +2, ...) until one side
    runs out, then continue along the other side.
    """
    var a = int_anchor(lo, hi)
    var up = UInt64(hi) - UInt64(a)
    var down = UInt64(a) - UInt64(lo)
    var m = min(up, down)
    if x >= a:
        var u = UInt64(x) - UInt64(a)
        if u == 0:
            return 0
        if u <= m:
            return 2 * u - 1
        return 2 * m + (u - m)
    var n = UInt64(a) - UInt64(x)
    if n <= m:
        return 2 * n
    return 2 * m + (n - m)


def index_to_int(i: UInt64, lo: Int, hi: Int) -> Int:
    """The inverse of `int_to_index`."""
    var a = int_anchor(lo, hi)
    var up = UInt64(hi) - UInt64(a)
    var down = UInt64(a) - UInt64(lo)
    var m = min(up, down)
    if i <= 2 * m:
        if i == 0:
            return a
        if i & 1 == 1:
            return Int(UInt64(a) + (i + 1) // 2)
        return Int(UInt64(a) - i // 2)
    var j = i - 2 * m
    if up > down:
        return Int(UInt64(a) + m + j)
    return Int(UInt64(a) - m - j)


struct Source(Movable):
    """Draws choices, recording each one in `rec`.

    A source generates from its generator, or replays `pre` (and, when `extend` is
    set, generates past its end). Running past the end of a replay, past
    `max_choices`, or `reject()` marks the example invalid and raises.
    """

    var rng: Rng
    var rec: Choices
    var pre: List[UInt64]
    var pos: Int
    var extend: Bool
    var max_choices: Int
    var invalid: Bool
    var open_spans: List[Span]
    """Spans started and not yet stopped, each ending where it started."""

    def __init__(out self, seed: UInt64, max_choices: Int = 10000):
        self.rng = Rng(seed)
        self.rec = Choices()
        self.pre = []
        self.pos = 0
        self.extend = True
        self.max_choices = max_choices
        self.invalid = False
        self.open_spans = []

    def _reset(mut self):
        self.rec.clear()
        self.pre.clear()
        self.pos = 0
        self.invalid = False
        self.open_spans.clear()

    def reset_generate(mut self):
        """Start a fresh example drawn from the generator."""
        self._reset()
        self.extend = True

    def reset_replay(mut self, values: List[UInt64]):
        """Start an example that replays `values` and is invalid past their end."""
        self._reset()
        self.pre = values.copy()
        self.extend = False

    def reset_forced(mut self, first: UInt64):
        """Start an example whose first choice is `first`, then generates."""
        self._reset()
        self.pre = [first]
        self.extend = True

    def reject(mut self) raises:
        self.invalid = True
        raise Error(INVALID_MESSAGE)

    def _replayed(mut self, bound: UInt64) raises -> Optional[UInt64]:
        """The next replayed choice, or none when the draw is to be generated."""
        if len(self.rec.values) >= self.max_choices:
            self.reject()
        if self.pos >= len(self.pre):
            if not self.extend:
                self.reject()
            return None
        var v = self.pre[self.pos]
        self.pos += 1
        if v > bound:
            self.reject()
        return v

    def _record(mut self, value: UInt64, bound: UInt64) -> UInt64:
        self.rec.push(value, bound)
        return value

    def draw_bits(mut self, n: Int) raises -> UInt64:
        """n uniform bits (0 to 64)."""
        var bound = UInt64.MAX if n >= 64 else (UInt64(1) << UInt64(n)) - 1
        if case .Some(v) = self._replayed(bound):
            return self._record(v, bound)
        return self._record(self.rng.next() & bound, bound)

    def draw_below(mut self, n: UInt64) raises -> UInt64:
        """Uniform in [0, n). Invalid when n is 0."""
        if n == 0:
            self.reject()
        var bound = n - 1
        if case .Some(v) = self._replayed(bound):
            return self._record(v, bound)
        return self._record(self.rng.below(n) if bound != 0 else 0, bound)

    def draw_choice(mut self, n: Int) raises -> Int:
        """An index in [0, n)."""
        return Int(self.draw_below(UInt64(n)))

    def draw_bool(mut self, p: Float64 = 0.5) raises -> Bool:
        """True with probability p; shrinks toward False."""
        if case .Some(v) = self._replayed(1):
            return self._record(v, 1) == 1
        return self._record(UInt64(1) if self.rng.unit() < p else 0, 1) == 1

    def _generated_int_index(mut self, lo: Int, hi: Int, bound: UInt64) -> UInt64:
        var r = self.rng.next()
        if r & 7 == 0:
            var edge = [lo, hi, 0, 1, -1][(r >> 3) % 5]
            if lo <= edge <= hi:
                return int_to_index(edge, lo, hi)
        return self.rng.next() if bound == UInt64.MAX else self.rng.below(bound + 1)

    def draw_int(mut self, lo: Int, hi: Int) raises -> Int:
        """An Int64 in [lo, hi]; about 1 in 8 draws takes an edge (lo, hi, 0, 1, -1)."""
        if lo > hi:
            self.reject()
        var bound = UInt64(hi) - UInt64(lo)
        if case .Some(v) = self._replayed(bound):
            return index_to_int(self._record(v, bound), lo, hi)
        return index_to_int(self._record(self._generated_int_index(lo, hi, bound), bound), lo, hi)

    def start_span(mut self, label: Int = 0):
        var start = len(self.rec.values)
        self.open_spans.append(Span(start, start, label))

    def stop_span(mut self):
        if not self.open_spans:
            return
        var span = self.open_spans.pop()
        span.end = len(self.rec.values)
        if span.length() > 0:
            self.rec.spans.append(span)


struct Many:
    """Loop helper for collections: `while many.more(src)`.

    Each element (its continue flag and whatever the body draws) is one span, so
    shrinking can delete elements whole.
    """

    var min_size: Int
    var max_size: Int
    var p: Float64
    var count: Int
    var open: Bool

    def __init__(out self, min_size: Int, max_size: Int, average: Float64):
        self.min_size = min_size
        self.max_size = max_size
        self.p = average / (1.0 + average)
        self.count = 0
        self.open = False

    def more(mut self, mut src: Source) raises -> Bool:
        if self.open:
            src.stop_span()
            self.open = False
        if self.count >= self.max_size:
            return False
        src.start_span(MANY_LABEL)
        if self.count >= self.min_size and not src.draw_bool(self.p):
            src.stop_span()
            return False
        self.open = True
        self.count += 1
        return True
