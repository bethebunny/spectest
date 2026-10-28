"""Helpers for the syntax tests: parse a fragment and dump the part under test."""

from syntax.lexer import tokens
from spec.ast import Ast
from syntax.parser import Parser, parse_spec
from syntax_dump import dump


def decls(body: String) raises -> String:
    """The dump of each top-level declaration of `spec t` followed by `body`, one per line."""
    var ast = parse_spec(String("spec t\n", body), "t.spec")
    return "\n".join([dump(ast, d) for d in ast.nodes[ast.root()].children])


def expr(source: String) raises -> String:
    """The dump of an expression, parsed as the clause of a function."""
    var ast = parse_spec(String("spec t\nfn f()\n  ensures ", source, "\n"), "t.spec")
    return dump(ast, ast.child(ast.child(ast.child(ast.root(), 0), 3), 0))


def type_(source: String) raises -> String:
    """The dump of a type, parsed as an alias's right side."""
    var ast = parse_spec(String("spec t\ntype T = ", source, "\n"), "t.spec")
    return dump(ast, ast.child(ast.child(ast.root(), 0), 0))


def spec_error(source: String) -> String:
    """The message raised parsing `source` as `t.spec`, or "" if it parses."""
    try:
        _ = parse_spec(source, "t.spec")
    except e:
        return String(e)
    return String()


def _parse_prelude(source: String) raises -> Ast:
    var parser = Parser(tokens(source, "t.prelude"), source.copy(), "t.prelude")
    _ = parser.parse_prelude_file()
    return parser^.into_ast()


def prelude_dump(source: String) raises -> String:
    var ast = _parse_prelude(source)
    return dump(ast, ast.root())


def prelude_error(source: String) -> String:
    try:
        _ = _parse_prelude(source)
    except e:
        return String(e)
    return String()
