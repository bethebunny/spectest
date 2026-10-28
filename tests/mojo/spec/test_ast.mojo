from std.testing import assert_equal, TestSuite

from spec.ast import Ast, NodeKind, Op, Span


def test_build_and_names() raises:
    var ast = Ast("x + 1", "t.spec")
    var x = ast.add(.Name, Span(start=0, end=1, line=1, column=1), text="x")
    var one = ast.add(.Name, Span(start=4, end=5, line=1, column=5), text="1")
    var sum = ast.add(.Binary, Span(start=0, end=5, line=1, column=1), op=.ADD, children=[x, one])
    assert_equal(ast.child(sum, 1), one)
    assert_equal(ast.source_text(sum), "x + 1")
    assert_equal(String(ast.node(sum).kind), "binary")
    assert_equal(String(Op.ADD), "+")
    assert_equal(String(Op.REQUIRES), "requires")
    assert_equal(String(NodeKind.Clause), "clause")
    assert_equal(String(NodeKind.Empty), "empty")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
