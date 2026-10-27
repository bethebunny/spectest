"""The checker: a parsed spec to a `Spec`.

`check` resolves every name, types every expression, gives every clause its id and
enforces the static rules of the language (docs/language.md, docs/v2/syntax.md). It
collects every error; if there are any it raises one `Error` whose message is the
diagnostics, one `path:line:col: message` per line, in source order. Declarations
that fail are skipped, so one mistake reports once.
"""

from syntax.ast import Ast, Diagnostic
from syntax.parser import parse_spec

from check.decls import run
from check.spec import Spec
from check.state import Checker
from check.types import Types


def check(var ast: Ast) raises -> Spec:
    var name = ast.nodes[ast.root].text.copy()
    var c = Checker(Spec(name^, ast^, Types()))
    run(c)
    if len(c.diags) > 0:
        raise Error(diagnostics_text(c.diags))
    var spec = c^.into_spec()
    for i in range(len(spec.node_types)):
        if spec.node_types[i] < 0:
            spec.node_types[i] = 0
    return spec^


def check_source(source: String, path: String) raises -> Spec:
    """Parse and check a spec file."""
    return check(parse_spec(source, path))


def diagnostics_text(diags: List[Diagnostic]) -> String:
    """The diagnostics in source order, one per line."""
    var order = List[Int]()
    for i in range(len(diags)):
        order.append(i)
    # Stable insertion sort by position: diagnostics are few.
    for i in range(1, len(order)):
        var v = order[i]
        var j = i - 1
        while j >= 0 and diags[order[j]].span.start > diags[v].span.start:
            order[j + 1] = order[j]
            j -= 1
        order[j + 1] = v
    var out = String()
    for i in range(len(order)):
        out += "\n" if i else ""
        out += String(diags[order[i]])
    return out^
