"""The vendored bitpattern core builds and runs from spectest's include path."""

from std.memory import OpaquePointer
from std.testing import assert_equal, TestSuite

from arena import Arena, ACCEPT, REJECT
from arena.arena import never_pause, PauseStatePointer
from arena.apply import union
from arena.build import interval
from bigint import BigUInt


def _bit(value: UInt64, bit: Int32) -> Bool:
    return (value >> UInt64(bit)) & 1 == 1


def test_interval_count() raises:
    var arena = Arena(never_pause, PauseStatePointer.unsafe_dangling())
    var a = interval[_bit](arena, UInt64(10), UInt64(19), 8)
    var b = interval[_bit](arena, UInt64(15), UInt64(29), 8)
    var both = union(arena, a, b)
    assert_equal(arena.count_narrow(both, 8), UInt128(20))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
