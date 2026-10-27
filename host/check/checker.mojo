"""The checker: a parsed spec to a `Spec`.

`check` resolves every name, types every expression, gives every clause its id and
enforces the static rules of the language (docs/language.md, docs/v2/syntax.md). It
collects every error; if there are any it raises one `Error` whose message is the
diagnostics, one `path:line:col: message` per line, in source order. Declarations
that fail are skipped, so one mistake reports once.
"""

from syntax import ast as sx
from syntax.ast import Ast, Diagnostic
from syntax.parser import parse_spec

from check.decls import run
from check.files import Files, resolve_files
from check.spec import Spec
from check.state import Checker
from check.types import Types


def check(var ast: Ast) raises -> Spec:
    """Check a spec whose `use` and `prelude` files, if any, are read from the disk."""
    return check_with(ast^, Files())


def check_with(var ast: Ast, files: Files) raises -> Spec:
    """Check a spec, reading the files it names (`use`, `prelude`) through `files`.
    Each file is read once. A file that cannot be read or a cycle of `use` is an
    error."""
    var name = ast.nodes[ast.root].text.copy()
    var diags = List[Diagnostic]()
    var order = resolve_files(ast, files, diags)
    var decls = List[Int]()
    for f in order:
        for d in ast.nodes[ast.files[f].root].kids:
            var k = ast.nodes[d].kind
            if k != sx.USE and k != sx.PRELUDE:
                decls.append(d)
    var c = Checker(Spec(name^, ast^, Types()))
    c.decls = decls^
    c.diags = diags^
    run(c)
    if len(c.diags) > 0:
        raise Error(diagnostics_text(c.diags))
    var spec = c^.into_spec()
    for i in range(len(spec.node_types)):
        if spec.node_types[i] < 0:
            spec.node_types[i] = 0
    return spec^


def check_source(source: String, path: String) raises -> Spec:
    """Parse and check a spec file; the files it names are read from the disk."""
    return check(parse_spec(source, path))


def check_source_with(source: String, path: String, files: Files) raises -> Spec:
    """Parse and check a spec file, reading the files it names through `files`."""
    return check_with(parse_spec(source, path), files)


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
