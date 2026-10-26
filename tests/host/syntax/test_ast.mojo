from std.testing import assert_equal, TestSuite

from syntax.ast import Ast, Span, NAME, BINARY, ADD, CLAUSE, REQUIRES, kind_name, op_name


def test_build_and_names() raises:
    var ast = Ast("x + 1", "t.spec")
    var x = ast.add(NAME, Span(0, 1, 1, 1), text="x")
    var one = ast.add(NAME, Span(4, 5, 1, 5), text="1")
    var sum = ast.add(BINARY, Span(0, 5, 1, 1), op=ADD, kids=[x, one])
    assert_equal(ast.kid(sum, 1), one)
    assert_equal(ast.source_text(sum), "x + 1")
    assert_equal(kind_name(ast.node(sum).kind), "binary")
    assert_equal(op_name(ADD), "+")
    assert_equal(op_name(REQUIRES), "requires")
    assert_equal(kind_name(CLAUSE), "clause")
    assert_equal(kind_name(0), "empty")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
