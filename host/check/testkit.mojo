"""Helpers for the package's tests: check a fragment and read back errors, types and
resolutions."""

from std.testing import assert_true

from syntax import ast

from check.checker import check_source
from check.spec import Spec


def ok(body: String) raises -> Spec:
    """Check `spec t` followed by `body`; raises with the diagnostics on an error."""
    return check_source("spec t\n" + body, "t.spec")


def error_lines(body: String) -> List[String]:
    """The diagnostics of `body`, each as `t.spec:line:col: message`; empty if it checks."""
    var out = List[String]()
    try:
        _ = ok(body)
    except e:
        for line in String(e).split("\n"):
            out.append(String(line))
    return out^


def message_of(line: String) -> String:
    var at = line.find(": ")
    if at < 0:
        return line.copy()
    return String(line[byte = at + 2 :])


def messages(body: String) -> List[String]:
    var out = List[String]()
    for line in error_lines(body):
        out.append(message_of(line))
    return out^


def fails(body: String, fragment: String) raises:
    """`body` has an error whose message contains `fragment`."""
    var msgs = messages(body)
    var shown = String()
    for m in msgs:
        shown += "\n  " + m
        if fragment in m:
            return
    assert_true(False, "no error containing '" + fragment + "' in:" + shown)


def fails2(body: String, a: String, b: String) raises:
    """One error contains both fragments."""
    var msgs = messages(body)
    var shown = String()
    for m in msgs:
        shown += "\n  " + m
        if a in m and b in m:
            return
    assert_true(False, "no error containing '" + a + "' and '" + b + "' in:" + shown)


def fails_at(body: String, expected: String) raises:
    """The diagnostics of `body` include exactly the line `expected`
    (`t.spec:line:col: message`)."""
    var lines = error_lines(body)
    var shown = String()
    for l in lines:
        shown += "\n  " + l
        if l == expected:
            return
    assert_true(False, "no diagnostic '" + expected + "' in:" + shown)


def count_errors(body: String) -> Int:
    return len(error_lines(body))


def clause_expr(spec: Spec, id: String) raises -> Int:
    var ci = spec.clause_named(id)
    assert_true(Bool(ci), "no clause " + id)
    return spec.clauses[ci.value()].expr


def type_text(spec: Spec, node: Int) -> String:
    return spec.types.text(spec.node_types[node])


def ensures_ty(params: String, expr: String, returns: String = "") raises -> String:
    """The type of `expr` in an ensures clause of `fn f(params)`."""
    var arrow = (" -> " + returns) if returns else String()
    var spec = ok(
        "fn f(" + params + ")" + arrow + "\n  ensures e: let v = " + expr + " in true\n"
    )
    var let = clause_expr(spec, "f.e")
    return type_text(spec, spec.ast.kid(let, 0))


def descendants(spec: Spec, root: Int) -> List[Int]:
    """The node and all below it, in source order of their first byte."""
    var out = List[Int]()
    var stack = List[Int]()
    stack.append(root)
    while len(stack) > 0:
        var n = stack.pop()
        out.append(n)
        var kids = spec.ast.nodes[n].kids.copy()
        var i = len(kids) - 1
        while i >= 0:
            stack.append(kids[i])
            i -= 1
    return out^


def nodes_of(spec: Spec, root: Int, kind: UInt8) -> List[Int]:
    var out = List[Int]()
    for n in descendants(spec, root):
        if spec.ast.nodes[n].kind == kind:
            out.append(n)
    return out^


def parents(spec: Spec) -> List[Int]:
    """By node id: the node's parent, 0 for the root."""
    var out = List[Int](length=len(spec.ast.nodes), fill=0)
    for n in range(len(spec.ast.nodes)):
        for k in spec.ast.nodes[n].kids:
            out[k] = n
    return out^


def named(spec: Spec, root: Int, kind: UInt8, text: String) -> List[Int]:
    """The nodes of `kind` with this text below `root`, in source order."""
    var out = List[Int]()
    for n in nodes_of(spec, root, kind):
        if spec.ast.nodes[n].text == text:
            out.append(n)
    return out^
