"""A one-line text form of the tree: `(kind op "text" child child ...)`.

The op is left out when it is `NO_OP` and the text when it is empty. An absent part
(`EMPTY`) is `_`. Example: `(binary + (name "x") (num "1"))`.
"""

from syntax.ast import Ast, EMPTY, NO_OP, kind_name, op_name


def _quoted(text: String) -> String:
    var escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return String('"', escaped.replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"), '"')


def dump(ast: Ast, id: Int) -> String:
    if id == Int(EMPTY):
        return "_"
    ref node = ast.nodes[id]
    var parts: List[String] = [String(kind_name(node.kind))]
    if node.op != NO_OP:
        parts.append(String(op_name(node.op)))
    if node.text.byte_length() > 0:
        parts.append(_quoted(node.text))
    for kid in node.kids:
        parts.append(dump(ast, kid))
    return String("(", " ".join(parts), ")")
