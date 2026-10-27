"""Helpers for the checker's tests: check a fragment, read back errors, types and resolutions."""

from std.testing import assert_true

from syntax import ast

from check.checker import check_source
from check.spec import Spec


def ok(body: String) raises -> Spec:
    return check_source("spec t\n" + body, "t.spec")


def error_lines(body: String) -> List[String]:
    """The diagnostics of `body` as `t.spec:line:col: message`; empty if it checks."""
    try:
        _ = ok(body)
    except e:
        return [String(line) for line in String(e).split("\n")]
    return []


def message_of(line: String) -> String:
    var at = line.find(": ")
    return line.copy() if at < 0 else String(line[byte = at + 2 :])


def messages(body: String) -> List[String]:
    return [message_of(line) for line in error_lines(body)]


def _listed(lines: List[String]) -> String:
    return "".join(["\n  " + line for line in lines])


def fails(body: String, fragment: String) raises:
    """`body` has an error whose message contains `fragment`."""
    var msgs = messages(body)
    assert_true(any([fragment in m for m in msgs]), String(t"no error containing '{fragment}' in:", _listed(msgs)))


def fails2(body: String, a: String, b: String) raises:
    """One error contains both fragments."""
    var msgs = messages(body)
    assert_true(any([a in m and b in m for m in msgs]), String(t"no error containing '{a}' and '{b}' in:", _listed(msgs)))


def fails_at(body: String, expected: String) raises:
    """The diagnostics of `body` include exactly the line `expected` (`t.spec:line:col: message`)."""
    var lines = error_lines(body)
    assert_true(expected in lines, String(t"no diagnostic '{expected}' in:", _listed(lines)))


def count_errors(body: String) -> Int:
    return len(error_lines(body))


def clause_expr(spec: Spec, id: String) raises -> Int:
    var ci = spec.clause_named(id)
    assert_true(ci is not None, String(t"no clause {id}"))
    return spec.clauses[ci.value()].expr


def type_text(spec: Spec, node: Int) -> String:
    return spec.types.text(spec.node_types[node])


def ensures_ty(params: String, expr: String, returns: String = "") raises -> String:
    """The type of `expr` in an ensures clause of `fn f(params)`."""
    var arrow = String(" -> ", returns) if returns else String()
    var spec = ok(String(t"fn f({params}){arrow}\n  ensures e: let v = {expr} in true\n"))
    var let = clause_expr(spec, "f.e")
    return type_text(spec, spec.ast.child(let, 0))


def descendants(spec: Spec, root: Int) -> List[Int]:
    """The node and all below it, in source order of their first byte."""
    var out: List[Int] = []
    var stack: List[Int] = [root]
    while stack:
        var n = stack.pop()
        out.append(n)
        for k in reversed(spec.ast.nodes[n].children):
            stack.append(k)
    return out^


def nodes_of(spec: Spec, root: Int, kind: ast.NodeKind) -> List[Int]:
    return [n for n in descendants(spec, root) if spec.ast.nodes[n].kind == kind]


def parents(spec: Spec) -> List[Int]:
    """By node id: the node's parent, 0 for the root."""
    var out = List[Int](length=len(spec.ast.nodes), fill=0)
    for n in range(len(spec.ast.nodes)):
        for k in spec.ast.nodes[n].children:
            out[k] = n
    return out^


def named(spec: Spec, root: Int, kind: ast.NodeKind, text: String) -> List[Int]:
    """The nodes of `kind` with this text below `root`, in source order."""
    return [n for n in nodes_of(spec, root, kind) if spec.ast.nodes[n].text == text]
