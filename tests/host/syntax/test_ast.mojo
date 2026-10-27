from std.testing import assert_equal, TestSuite

from syntax.ast import Ast, NodeKind, Op, Span


def test_build_and_names() raises:
    var ast = Ast("x + 1", "t.spec")
    var x = ast.add(.NAME, Span(0, 1, 1, 1), text="x")
    var one = ast.add(.NAME, Span(4, 5, 1, 5), text="1")
    var sum = ast.add(.BINARY, Span(0, 5, 1, 1), op=.ADD, children=[x, one])
    assert_equal(ast.child(sum, 1), one)
    assert_equal(ast.source_text(sum), "x + 1")
    assert_equal(String(ast.node(sum).kind), "binary")
    assert_equal(String(Op.ADD), "+")
    assert_equal(String(Op.REQUIRES), "requires")
    assert_equal(String(NodeKind.CLAUSE), "clause")
    assert_equal(String(NodeKind.EMPTY), "empty")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
