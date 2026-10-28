"""Reading the files of a multi-file spec.

`resolve_files` follows the `use` and `prelude` declarations of the files already in
an `Ast`, relative to the directory of the file that names them, and parses each file
it finds into the same tree, once, however many files name it. It reports a file that
cannot be read, a file of the wrong kind and a cycle of `use` as diagnostics.
"""

from std.os.path import dirname, join
from std.pathlib import Path

from spec.ast import Ast, Diagnostic

from specfile.checker_state import Visit, cycle_text
from specfile.parser import parse_into


struct Files(Movable):
    """Where files come from: a table of in-memory texts first, then the disk."""

    var memory: Dict[String, String]
    var disk: Bool

    def __init__(out self, disk: Bool = True):
        self.memory = {}
        self.disk = disk

    def add(mut self, path: String, text: String):
        self.memory[normalize(path)] = text

    def read(self, path: String) raises -> String:
        if case .Some(text) = self.memory.get(path):
            return text.copy()
        if self.disk:
            return Path(path).read_text()
        raise Error("no such file")


def normalize(path: String) -> String:
    """`path` without leading `./` parts."""
    var p = path.copy()
    while p.startswith("./"):
        var rest = String(p.removeprefix("./"))
        p = rest^
    return p^


def _relative(base_file: String, name: String) -> String:
    """`name` relative to the directory of `base_file`."""
    return normalize(join(dirname(base_file), name))


struct _Walk(Defaultable, Movable):
    var keys: List[String]
    """By file index: the normalized path the file was found under."""
    var visits: List[Visit]
    """By file index."""
    var stack: List[Int]
    var order: List[Int]
    """The files reached, in the order they were found."""
    var diags: List[Diagnostic]


def _is_prelude(ast: Ast, file: Int) -> Bool:
    return ast.nodes[ast.files[file].root].kind == .PRELUDE_FILE


def _visit(mut w: _Walk, mut ast: Ast, files: Files, file: Int) raises:
    w.visits[file] = .ON_PATH
    w.stack.append(file)
    for d in ast.nodes[ast.files[file].root].children.copy():
        var kind = ast.nodes[d].kind
        if kind != .USE and kind != .PRELUDE:
            continue
        var name = ast.nodes[d].text.copy()
        var word = "use" if kind == .USE else "prelude"
        var key = _relative(ast.files[file].path, name)
        var target = w.keys.try_index(key).or_else(-1)
        if target < 0:
            var text: String
            try:
                text = files.read(key)
            except:
                w.diags.append(ast.diagnostic(d, t"cannot read {word} file {name} ({key})"))
                continue
            target = parse_into(ast, text, key)
            w.keys.append(key^)
            w.visits.append(.UNSEEN)
        elif w.visits[target] == .ON_PATH:
            var cycle = cycle_text([ast.files[f].path.copy() for f in w.stack[w.stack.index(target) :]])
            w.diags.append(ast.diagnostic(d, t"{word} cycle: {cycle}"))
            continue
        var wants_prelude = kind == .PRELUDE or _is_prelude(ast, file)
        if _is_prelude(ast, target) != wants_prelude:
            if wants_prelude:
                w.diags.append(ast.diagnostic(d, t"{name} is a spec, not a prelude file"))
            else:
                w.diags.append(ast.diagnostic(d, t"{name} is a prelude file, not a spec: attach it with prelude"))
            continue
        if w.visits[target] == .UNSEEN:
            w.order.append(target)
            _visit(w, ast, files, target)
    _ = w.stack.pop()
    w.visits[file] = .DONE


def resolve_files(mut ast: Ast, files: Files, mut diags: List[Diagnostic]) raises -> List[Int]:
    """Load every file the first file names, directly or not, into `ast`. Returns the
    indices in `ast.files` of the files to check, the first included: spec files in
    the order found, then prelude files in the order found. Appends the problems to
    `diags`. Raises on a syntax error in a loaded file."""
    var w = _Walk()
    w.keys.append(normalize(ast.files[0].path))
    w.visits.append(.UNSEEN)
    w.order.append(0)
    _visit(w, ast, files, 0)
    diags.extend(w.diags.copy())
    return [f for f in w.order if not _is_prelude(ast, f)] + [f for f in w.order if _is_prelude(ast, f)]
