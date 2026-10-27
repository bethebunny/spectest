from std.testing import assert_equal, assert_true, TestSuite

from eval.testkit import *
from wire.value import Value


def test_arith() raises:
    assert_equal(value_text("a: int, b: int", "a + b * 2", two(Value.int(3), Value.int(4))), "11")
    assert_equal(value_text("a: int", "-a", one(Value.int(3))), "-3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
