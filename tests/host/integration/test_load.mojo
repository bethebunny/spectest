"""Checking and partition compilation working together on the existing specs."""

from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite

from check.checker import check_source
from partitions.check import compile_partitions
from sets.context import SetContext


def load(path: String) raises -> Tuple[Int, Int, Int]:
    """Functions, set classes and predicate classes of a spec."""
    var spec = check_source(Path(path).read_text(), path)
    var ctx = SetContext()
    var sets = compile_partitions(ctx, spec)
    var set_classes = 0
    var predicates = 0
    for partitions in sets.partitions:
        for part in partitions:
            if part.predicates:
                predicates += len(part.sets)
            else:
                set_classes += len(part.sets)
    return (len(spec.fns), set_classes, predicates)


def test_existing_specs() raises:
    for path in [
        "examples/binary/binary.spec",
        "examples/deque/deque.spec",
        "examples/frames/frames.spec",
        "examples/libm/explore.spec",
        "examples/libm/libm.spec",
        "examples/sorting/sorting.spec",
        "trials/bitpattern/bitpattern.spec",
    ]:
        var counts = load(String(path))
        print(path, "fns", counts[0], "set classes", counts[1], "predicate classes", counts[2])
        assert_true(counts[0] > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
