"""Search: replay stored failures, generate examples, shrink each failing property."""

from std.time import perf_counter_ns

from .choices import Choices
from .property import Property, run_example, FAILED, SKIPPED
from .settings import Settings
from .shrink import shrink
from .source import Source
from .store import store_load, store_save


struct PropertyResult(Copyable, Movable):
    var id: Int
    var passes: Int
    var fails: Int
    var skips: Int
    var failed: Bool
    var choices: Choices
    """The shrunk failure (the first failure, for enumeration); empty unless failed."""

    def __init__(out self, id: Int):
        self.id = id
        self.passes = 0
        self.fails = 0
        self.skips = 0
        self.failed = False
        self.choices = Choices()


struct SearchResult(Copyable, Movable):
    var properties: List[PropertyResult]
    var examples: Int
    """Valid examples run."""
    var invalid: Int
    var elapsed_ns: Int

    def __init__(out self):
        self.properties = []
        self.examples = 0
        self.invalid = 0
        self.elapsed_ns = 0

    def find(self, id: Int) -> Int:
        """Index of the result for property `id`, or -1."""
        for i, p in enumerate(self.properties):
            if p.id == id:
                return i
        return -1

    def _slot(mut self, id: Int) -> Int:
        var i = self.find(id)
        if i < 0:
            self.properties.append(PropertyResult(id))
            i = len(self.properties) - 1
        return i

    def all_failed(self) -> Bool:
        return len(self.properties) > 0 and all([p.failed for p in self.properties])


def _run_one[P: Property](
    mut prop: P, mut src: Source, mut res: SearchResult
) raises -> Bool:
    """Run the example `src` is set up for and tally it. False when invalid."""
    var out = run_example(prop, src)
    if out is None:
        res.invalid += 1
        return False
    res.examples += 1
    for id, result in zip(out.value().ids, out.value().results):
        ref p = res.properties[res._slot(id)]
        if result == FAILED:
            p.fails += 1
            if not p.failed:
                p.failed = True
                p.choices = src.rec.copy()
        elif result == SKIPPED:
            p.skips += 1
        else:
            p.passes += 1
    return True


def search[P: Property](mut prop: P, settings: Settings) raises -> SearchResult:
    """Replay stored failures, then generate until `max_examples` valid examples.

    Each property keeps its first failure and is then shrunk on its own. Generation
    stops early once every property has failed, and after ten times `max_examples`
    attempts in all (so a generator that rejects most examples cannot run forever).
    """
    var t0 = perf_counter_ns()
    var res = SearchResult()
    var src = Source(settings.seed, settings.max_choices)
    if settings.store_dir is not None:
        for key in settings.keys:
            var stored = store_load(settings.store_dir.value(), key)
            if stored is not None:
                src.reset_replay(stored.value().values)
                _ = _run_one(prop, src, res)
    var attempts = 0
    var valid = 0
    while valid < settings.max_examples and attempts < settings.max_examples * 10 and not res.all_failed():
        attempts += 1
        src.reset_generate()
        if _run_one(prop, src, res):
            valid += 1
    for ref p in res.properties:
        if not p.failed:
            continue
        p.choices = shrink(prop, p.choices, p.id, settings.max_shrink_steps)
        if settings.store_dir is not None and 0 <= p.id and p.id < len(settings.keys):
            store_save(settings.store_dir.value(), settings.keys[p.id], p.choices)
    res.elapsed_ns = Int(perf_counter_ns() - t0)
    return res^


def enumerate_all[P: Property](
    mut prop: P, n: Int, settings: Settings
) raises -> SearchResult:
    """Run the property once per index in [0, n), the example's first `draw_below(n)`.

    Over `settings.max_exhaustive` indices, a uniform sample of that many indices
    (one random index from each equal stratum, in increasing order). A failure is the
    smallest failing index (not shrunk).
    """
    var t0 = perf_counter_ns()
    var res = SearchResult()
    var src = Source(settings.seed, settings.max_choices)
    var runs = min(n, settings.max_exhaustive)
    for k in range(runs):
        var lo = k * n // runs
        var index = UInt64(k) if runs == n else UInt64(lo) + src.rng.below(UInt64((k + 1) * n // runs - lo))
        src.reset_forced(index)
        _ = _run_one(prop, src, res)
    res.elapsed_ns = Int(perf_counter_ns() - t0)
    return res^
