from std.pathlib import Path
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.time import perf_counter_ns

from partition.coverage import compile_partitions
from partition.sets import SetContext
from partitions_testing import build_spec


def _fixed_classes(spec_path: String) raises -> Int:
    """Compiles every partition of a spec; returns how many classes are sets."""
    var spec = build_spec(Path(spec_path).read_text(), spec_path)
    var c = SetContext()
    var sets = compile_partitions(c, spec)
    assert_equal(len(sets.warnings), 0)
    var fixed = 0
    for f in range(len(spec.fns)):
        for p in range(len(spec.fns[f].partitions)):
            for k in range(sets.class_count(f, p)):
                if not sets.is_predicate(f, p, k):
                    fixed += 1
                    assert_false(c.is_empty(sets.set_of(f, p, k)))
    return fixed


def test_libm_partitions() raises:
    # cos (7 classes), cos32 (7) and sqrt (6), all over float parameters.
    assert_equal(_fixed_classes("examples/libm/libm.spec"), 20)


def test_bitpattern_partitions() raises:
    # 84 partitions: 132 classes over fixed-width parameters, and 46 predicates.
    assert_equal(_fixed_classes("trials/bitpattern/bitpattern.spec"), 132)


def test_libm_compiles_in_milliseconds() raises:
    var spec = build_spec(Path("examples/libm/libm.spec").read_text(), "libm.spec")
    var best = Int.MAX
    var first = 0
    for round in range(5):
        var c = SetContext()
        var start = perf_counter_ns()
        _ = compile_partitions(c, spec)
        var elapsed = Int(perf_counter_ns() - start)
        if round == 0:
            first = elapsed
        best = min(best, elapsed)
    print(
        "libm.spec partitions: first run",
        Float64(first) / 1e6,
        "ms, best of 5",
        Float64(best) / 1e6,
        "ms",
    )
    assert_true(best < 5_000_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
