"""One tree over several files: parse_into, each node's file, spans and locations."""

from std.testing import assert_equal, assert_true, TestSuite

from syntax.ast import Ast, NodeKind
from syntax.parser import parse_into, parse_spec

comptime SPEC = 'spec s\nprelude "m.prelude"\nfn f(x: int) -> int\n  ensures big: twice(x) > x\n'
comptime PRELUDE = "\n\nfn twice(x: int) -> int = x + x\nfn thrice(x: int) -> int = twice(x) + x\n"


def tree() raises -> Ast:
    var ast = parse_spec(SPEC, "dir/s.spec")
    _ = parse_into(ast, PRELUDE, "dir/m.prelude")
    return ast^


def test_a_single_file_tree_has_one_file() raises:
    var ast = parse_spec(SPEC, "s.spec")
    assert_equal(len(ast.files), 1)
    assert_equal(ast.files[0].path, "s.spec")
    assert_equal(ast.files[0].start, 0)
    assert_equal(ast.files[0].root, ast.root())
    assert_equal(ast.nodes[ast.root()].file, 0)
    assert_equal(ast.nodes[0].file, 0)


def test_parse_into_appends_a_file() raises:
    var ast = tree()
    assert_equal(len(ast.files), 2)
    assert_equal(ast.files[1].path, "dir/m.prelude")
    assert_equal(ast.files[1].start, SPEC.byte_length())
    assert_equal(String(ast.source[byte = ast.files[1].start :]), PRELUDE)
    assert_equal(ast.source, String(SPEC, PRELUDE))
    assert_equal(ast.nodes[ast.files[1].root].kind, NodeKind.PRELUDE_FILE)
    assert_equal(ast.nodes[ast.root()].kind, NodeKind.FILE)
    assert_equal(ast.root(), ast.files[0].root)


def test_each_node_names_its_file() raises:
    var ast = tree()
    var seen_prelude = 0
    for n in range(1, len(ast.nodes)):
        var f = ast.nodes[n].file
        if n <= ast.files[0].root:
            assert_equal(f, 0)
        else:
            assert_equal(f, 1)
            seen_prelude += 1
    assert_true(seen_prelude > 10)
    assert_equal(ast.path_of(ast.root()), "dir/s.spec")
    assert_equal(ast.path_of(ast.files[1].root), "dir/m.prelude")


def test_spans_are_offsets_into_the_combined_source() raises:
    var ast = tree()
    var decls = ast.nodes[ast.files[1].root].children.copy()
    assert_equal(len(decls), 2)
    assert_equal(ast.nodes[decls[0]].kind, NodeKind.DEF)
    assert_equal(ast.source_text(decls[0]), "fn twice(x: int) -> int = x + x")
    assert_equal(ast.source_text(decls[1]), "fn thrice(x: int) -> int = twice(x) + x")


def test_lines_and_columns_are_the_files_own() raises:
    var ast = tree()
    var decls = ast.nodes[ast.files[1].root].children.copy()
    assert_equal(ast.nodes[decls[0]].span.line, 3)
    assert_equal(ast.nodes[decls[0]].span.column, 1)
    assert_equal(ast.nodes[decls[1]].span.line, 4)
    assert_equal(ast.location(decls[1]), "dir/m.prelude:4:1")
    var f_ = ast.nodes[ast.root()].children[1]
    assert_equal(ast.nodes[f_].kind, NodeKind.FN)
    assert_equal(ast.location(f_), "dir/s.spec:3:1")


def test_children_of_appended_nodes_stay_inside_the_file() raises:
    var ast = tree()
    for n in range(ast.files[0].root + 1, len(ast.nodes)):
        for k in ast.nodes[n].children:
            assert_true(k == 0 or k > ast.files[0].root)
            assert_true(k < len(ast.nodes))


def test_several_files_and_a_spec_among_them() raises:
    var ast = tree()
    var third = parse_into(ast, "spec other\nerror e.Oops\n", "dir/o.spec")
    assert_equal(third, 2)
    assert_equal(ast.nodes[ast.files[2].root].kind, NodeKind.FILE)
    assert_equal(ast.nodes[ast.files[2].root].text, "other")
    var e = ast.nodes[ast.files[2].root].children[0]
    assert_equal(ast.nodes[e].file, 2)
    assert_equal(ast.source_text(e), "error e.Oops")
    assert_equal(ast.location(e), "dir/o.spec:2:1")


def test_a_syntax_error_names_its_file_and_line() raises:
    var ast = parse_spec(SPEC, "s.spec")
    try:
        _ = parse_into(ast, "fn ok(x: int) -> int = x\nfn bad(\n", "p.prelude")
        assert_true(False, "expected a syntax error")
    except e:
        assert_true(String(e).startswith("p.prelude:2:"), String(e))
    assert_equal(len(ast.files), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
