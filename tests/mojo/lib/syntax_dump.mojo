"""A one-line text form of the tree: `(kind op "text" child child ...)`.

The op is left out when it is `NO_OP` and the text when it is empty. An absent part
(`Empty`) is `_`. Example: `(binary + (name "x") (num "1"))`.
"""

from spec.ast import Ast, NIL


def _quoted(text: String) -> String:
    var escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return String('"', escaped.replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"), '"')


def dump(ast: Ast, id: Int) -> String:
    if id == NIL:
        return "_"
    ref node = ast.nodes[id]
    var parts: List[String] = [String(node.kind)]
    if node.op != .NO_OP:
        parts.append(String(node.op))
    if node.text.byte_length() > 0:
        parts.append(_quoted(node.text))
    for child in node.children:
        parts.append(dump(ast, child))
    return String("(", " ".join(parts), ")")
