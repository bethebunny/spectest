"""Search: replay stored failures, generate examples, shrink each failing property."""

from std.time import perf_counter_ns

from .choices import Choices
from .property import Property, run_example
from .settings import Settings
from .shrink import shrink
from .source import Source
from .store import store_load, store_save


struct PropertyResult(Copyable):
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


struct SearchResult(Copyable, Defaultable):
    var properties: List[PropertyResult]
    var examples: Int
    """Valid examples run."""
    var invalid: Int
    var elapsed_ns: Int

    def _index(mut self, id: Int) -> Int:
        """Where the result for property `id` is, added if it is new."""
        for i in range(len(self.properties)):
            if self.properties[i].id == id:
                return i
        self.properties.append(PropertyResult(id))
        return len(self.properties) - 1

    def all_failed(self) -> Bool:
        return Bool(self.properties) and all([p.failed for p in self.properties])


def _run_one[P: Property](
    mut prop: P, mut src: Source, mut result: SearchResult
) raises -> Bool:
    """Run the example `src` is set up for and tally it. False when invalid."""
    var out = run_example(prop, src)
    if out is None:
        result.invalid += 1
        return False
    result.examples += 1
    for id, verdict in out.value().verdicts:
        ref p = result.properties[result._index(id)]
        match verdict:
            case .Passed:
                p.passes += 1
            case .Failed:
                p.fails += 1
                if not p.failed:
                    p.failed = True
                    p.choices = src.rec.copy()
            case .Skipped:
                p.skips += 1
    return True


def search[P: Property](mut prop: P, settings: Settings) raises -> SearchResult:
    """Replay stored failures, then generate until `max_examples` valid examples.

    Each property keeps its first failure and is then shrunk on its own. Generation
    stops early once every property has failed, and after ten times `max_examples`
    attempts in all (so a generator that rejects most examples cannot run forever).
    """
    var start = perf_counter_ns()
    var result = SearchResult()
    var src = Source(settings.seed, settings.max_choices)
    if case .Some(dir) = settings.store_dir:
        for key in settings.keys:
            if case .Some(stored) = store_load(dir, key):
                src.reset_replay(stored.values)
                _ = _run_one(prop, src, result)
    var attempts = 0
    var valid = 0
    while valid < settings.max_examples and attempts < settings.max_examples * 10 and not result.all_failed():
        attempts += 1
        src.reset_generate()
        if _run_one(prop, src, result):
            valid += 1
    for ref p in result.properties:
        if not p.failed:
            continue
        p.choices = shrink(prop, p.choices, p.id, settings.max_shrink_steps)
        if settings.store_dir is not None and 0 <= p.id < len(settings.keys):
            store_save(settings.store_dir.value(), settings.keys[p.id], p.choices)
    result.elapsed_ns = Int(perf_counter_ns() - start)
    return result^


def enumerate_all[P: Property](
    mut prop: P, n: Int, settings: Settings
) raises -> SearchResult:
    """Run the property once per index in [0, n), the example's first `draw_below(n)`.

    Over `settings.max_exhaustive` indices, a uniform sample of that many indices
    (one random index from each equal stratum, in increasing order). A failure is the
    smallest failing index (not shrunk).
    """
    var start = perf_counter_ns()
    var result = SearchResult()
    var src = Source(settings.seed, settings.max_choices)
    var runs = min(n, settings.max_exhaustive)
    for k in range(runs):
        var lo = k * n // runs
        var index = UInt64(k) if runs == n else UInt64(lo) + src.rng.below(UInt64((k + 1) * n // runs - lo))
        src.reset_forced(index)
        _ = _run_one(prop, src, result)
    result.elapsed_ns = Int(perf_counter_ns() - start)
    return result^
