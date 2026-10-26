"""Helpers for the package's tests: parse a fragment and dump the part under test."""

from syntax.ast import Ast
from syntax.dump import dump
from syntax.parser import parse_spec, parse_prelude


def decls(body: String) raises -> String:
    """The dump of each top-level declaration of `spec t` followed by `body`, one per line."""
    var ast = parse_spec("spec t\n" + body, "t.spec")
    var out = String()
    var first = True
    for d in ast.nodes[ast.root].kids:
        if not first:
            out += "\n"
        first = False
        out += dump(ast, d)
    return out^


def expr(source: String) raises -> String:
    """The dump of an expression, parsed as the clause of a function."""
    var ast = parse_spec("spec t\nfn f()\n  ensures " + source + "\n", "t.spec")
    return dump(ast, ast.kid(ast.kid(ast.kid(ast.root, 0), 3), 0))


def type_(source: String) raises -> String:
    """The dump of a type, parsed as an alias's right side."""
    var ast = parse_spec("spec t\ntype T = " + source + "\n", "t.spec")
    return dump(ast, ast.kid(ast.kid(ast.root, 0), 0))


def spec_error(source: String) -> String:
    """The message raised parsing `source` as `t.spec`, or "" if it parses."""
    try:
        _ = parse_spec(source, "t.spec")
    except e:
        return String(e)
    return String()


def prelude_dump(source: String) raises -> String:
    var ast = parse_prelude(source, "t.prelude")
    return dump(ast, ast.root)


def prelude_error(source: String) -> String:
    try:
        _ = parse_prelude(source, "t.prelude")
    except e:
        return String(e)
    return String()
