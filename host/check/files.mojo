"""Reading the files of a multi-file spec.

`resolve_files` follows the `use` and `prelude` declarations of the files already in
an `Ast`, relative to the directory of the file that names them, and parses each file
it finds into the same tree, once, however many files name it. It reports a file that
cannot be read, a file of the wrong kind and a cycle of `use` as diagnostics.
"""

from std.collections import Dict
from std.pathlib import Path

from syntax import ast as sx
from syntax.ast import Ast, Diagnostic
from syntax.parser import parse_into


struct Files(Movable):
    """Where files come from: a table of in-memory texts first, then the disk."""

    var memory: Dict[String, String]
    var disk: Bool

    def __init__(out self, disk: Bool = True):
        self.memory = Dict[String, String]()
        self.disk = disk

    def add(mut self, path: String, text: String):
        self.memory[normalize(path)] = text

    def read(self, path: String) raises -> String:
        var found = self.memory.get(path)
        if found:
            return found.value()
        if self.disk:
            return Path(path).read_text()
        raise Error("no such file")


def normalize(path: String) -> String:
    """`path` without leading `./` parts."""
    var p = path.copy()
    while p.startswith("./"):
        var rest = String(p[byte=2:])
        p = rest^
    return p^


def dir_of(path: String) -> String:
    """The directory part of `path` with its trailing slash, or ""."""
    var bytes = path.as_bytes()
    var i = len(bytes) - 1
    while i >= 0:
        if Int(bytes[i]) == ord("/"):
            return String(path[byte = 0 : i + 1])
        i -= 1
    return String()


def join(base_file: String, name: String) -> String:
    """`name` relative to the directory of `base_file`."""
    if name.startswith("/"):
        return name.copy()
    return normalize(dir_of(base_file) + name)


struct _Walk(Movable):
    var keys: List[String]
    """By file index: the normalized path the file was found under."""
    var state: List[Int]
    """By file index: 0 not visited, 1 being visited, 2 done."""
    var stack: List[Int]
    var order: List[Int]
    """The files reached, in the order they were found."""
    var diags: List[Diagnostic]

    def __init__(out self):
        self.keys = List[String]()
        self.state = List[Int]()
        self.stack = List[Int]()
        self.order = List[Int]()
        self.diags = List[Diagnostic]()


def _key_index(w: _Walk, key: String) -> Int:
    for i in range(len(w.keys)):
        if w.keys[i] == key:
            return i
    return -1


def _is_prelude(ast: Ast, file: Int) -> Bool:
    return ast.nodes[ast.files[file].root].kind == sx.PRELUDE_FILE


def _report(mut w: _Walk, ast: Ast, node: Int, message: String):
    w.diags.append(Diagnostic(ast.path_of(node), ast.nodes[node].span, message))


def _visit(mut w: _Walk, mut ast: Ast, files: Files, file: Int) raises:
    w.state[file] = 1
    w.stack.append(file)
    var decls = ast.nodes[ast.files[file].root].kids.copy()
    for d in decls:
        var kind = ast.nodes[d].kind
        if kind != sx.USE and kind != sx.PRELUDE:
            continue
        var name = ast.nodes[d].text.copy()
        var word = "use" if kind == sx.USE else "prelude"
        var key = join(ast.files[file].path, name)
        var target = _key_index(w, key)
        if target < 0:
            var text: String
            try:
                text = files.read(key)
            except:
                _report(w, ast, d, String("cannot read ", word, " file ", name, " (", key, ")"))
                continue
            target = parse_into(ast, text, key)
            w.keys.append(key^)
            w.state.append(0)
        elif w.state[target] == 1:
            var chain = String()
            var from_ = 0
            for i in range(len(w.stack)):
                if w.stack[i] == target:
                    from_ = i
            for i in range(from_, len(w.stack)):
                chain += ast.files[w.stack[i]].path + " -> "
            chain += ast.files[target].path
            _report(w, ast, d, String(word, " cycle: ", chain))
            continue
        var wants_prelude = kind == sx.PRELUDE or _is_prelude(ast, file)
        if _is_prelude(ast, target) != wants_prelude:
            if wants_prelude:
                _report(w, ast, d, String(name, " is a spec, not a prelude file"))
            else:
                _report(w, ast, d, String(name, " is a prelude file, not a spec: attach it with prelude"))
            continue
        if w.state[target] == 0:
            w.order.append(target)
            _visit(w, ast, files, target)
    _ = w.stack.pop()
    w.state[file] = 2


def resolve_files(mut ast: Ast, files: Files, mut diags: List[Diagnostic]) raises -> List[Int]:
    """Load every file the first file names, directly or not, into `ast`. Returns the
    indices in `ast.files` of the files to check, the first included: spec files in
    the order found, then prelude files in the order found. Appends the problems to
    `diags`. Raises on a syntax error in a loaded file."""
    var w = _Walk()
    w.keys.append(normalize(ast.files[0].path))
    w.state.append(0)
    w.order.append(0)
    _visit(w, ast, files, 0)
    for d in w.diags:
        diags.append(d.copy())
    var out = List[Int]()
    for f in w.order:
        if not _is_prelude(ast, f):
            out.append(f)
    for f in w.order:
        if _is_prelude(ast, f):
            out.append(f)
    return out^
