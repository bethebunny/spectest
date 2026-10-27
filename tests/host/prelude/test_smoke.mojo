from std.testing import assert_equal, assert_true, TestSuite

from check.types import Types
from prelude.api import call, CallArgs
from prelude.names import prelude_id
from numeric.formats import F64
from wire.value import Value


def run(name: String, var args: List[Value]) raises -> Value:
    var types = Types()
    return call(prelude_id(name).value(), CallArgs(args^), types)


def test_len() raises:
    var r = run("len", [Value.list([Value.int(1), Value.int(2)])])
    assert_true(r == Value.int(2))
    assert_true(run("cr.sqrt", [Value.float(F64, 0x4000000000000000)]) == Value.float(F64, 0x3FF6A09E667F3BCD))
    var m = run("mp.sqrt", [Value.int(2)])
    print(m)

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
