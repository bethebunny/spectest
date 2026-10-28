from std.testing import assert_equal, assert_true, TestSuite
from std.time import perf_counter_ns

from spec.ast import Ast, NodeKind
from syntax_dump import dump
from specfile.parser import parse_spec
from syntax_testkit import spec_error


def read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def test_examples_parse() raises:
    var paths = [
        "examples/binary/binary.spec",
        "examples/deque/deque.spec",
        "examples/frames/frames.spec",
        "examples/libm/explore.spec",
        "examples/libm/libm.spec",
        "examples/sorting/sorting.spec",
        "trials/bitpattern/bitpattern.spec",
    ]
    for path in paths:
        var ast = parse_spec(read(path), path)
        ref file = ast.nodes[ast.root()]
        assert_equal(file.kind, NodeKind.FILE)
        assert_true(len(file.children) > 0, path)
        # The file's span covers the whole text up to its last token.
        assert_equal(file.span.start, 0)


def test_example_declaration_counts() raises:
    var ast = parse_spec(read("examples/sorting/sorting.spec"), "sorting.spec")
    assert_equal(ast.nodes[ast.root()].text, "sorting")
    var fns = 0
    for d in ast.nodes[ast.root()].children:
        if ast.nodes[d].kind == .FN:
            fns += 1
    assert_true(fns > 0)


def test_sample_spec_dumps_as_expected() raises:
    var ast = parse_spec(read("tests/host/syntax/data/sample.spec"), "sample.spec")
    var expected = read("tests/host/syntax/data/sample.dump")
    var lines = expected.split("\n")
    var decls = ast.nodes[ast.root()].children.copy()
    var n = 0
    for line in lines:
        if line.byte_length() == 0:
            continue
        assert_true(n < len(decls), "more expected lines than declarations")
        assert_equal(dump(ast, decls[n]), String(line))
        n += 1
    assert_equal(n, len(decls))
    assert_equal(ast.nodes[ast.root()].text, "bitpattern")


def test_clause_span_covers_its_continuation_lines() raises:
    var source = String(
        "spec s\nfn f(x: int)\n  ensures x > 0 and\n    x < 9\n  requires true  # c\n"
    )
    var ast = parse_spec(source, "s.spec")
    var fn_id = ast.child(ast.root(), 0)
    var ensures = ast.child(fn_id, 3)
    var requires = ast.child(fn_id, 4)
    assert_equal(ast.nodes[ensures].kind, NodeKind.CLAUSE)
    assert_equal(ast.source_text(ensures), "ensures x > 0 and\n    x < 9")
    assert_equal(ast.nodes[ensures].span.line, 3)
    assert_equal(ast.nodes[ensures].span.column, 3)
    assert_equal(ast.source_text(requires), "requires true")
    assert_equal(ast.source_text(fn_id), "fn f(x: int)\n  ensures x > 0 and\n    x < 9\n  requires true")
    assert_equal(ast.source_text(ast.child(ensures, 0)), "x > 0 and\n    x < 9")


def test_node_spans_quote_the_source() raises:
    var ast = parse_spec(
        "spec s\nfn f(a: int) -> list<int>\n  ensures (a + 1) * f(a, k=2)[0]\n", "s.spec"
    )
    var fn_id = ast.child(ast.root(), 0)
    assert_equal(ast.source_text(ast.child(fn_id, 1)), "(a: int)")
    assert_equal(ast.source_text(ast.child(fn_id, 2)), "list<int>")
    var expr = ast.child(ast.child(fn_id, 3), 0)
    assert_equal(ast.source_text(expr), "(a + 1) * f(a, k=2)[0]")
    var rhs = ast.child(expr, 1)
    assert_equal(ast.source_text(rhs), "f(a, k=2)[0]")
    var call = ast.child(rhs, 0)
    assert_equal(ast.source_text(call), "f(a, k=2)")
    assert_equal(ast.source_text(ast.child(call, 3)), "k=2")


def test_parsing_bitpattern_is_fast() raises:
    var source = read("trials/bitpattern/bitpattern.spec")
    var best = Int.MAX
    var nodes = 0
    for _ in range(5):
        var t0 = perf_counter_ns()
        var ast = parse_spec(source, "bitpattern.spec")
        var elapsed = Int(perf_counter_ns() - t0)
        nodes = len(ast.nodes)
        if elapsed < best:
            best = elapsed
    print("parse bitpattern.spec:", Float64(best) / 1e6, "ms,", nodes, "nodes")
    assert_true(best < 200_000_000, "parsing bitpattern.spec took over 200 ms")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
