"""A one-line text form of the tree, for tests and diagnostics.

`(kind op "text" child child ...)`: the op is left out when it is `NO_OP` and the text
when it is empty; an absent part (`EMPTY`) is `_`. Example:
`(binary + (name "x") (num "1"))`.
"""

from syntax.ast import Ast, EMPTY, NO_OP, kind_name, op_name


def _write_quoted(mut out: String, text: String):
    var buf = List[UInt8]()
    buf.append(34)
    for b in text.as_bytes():
        if b == 34 or b == 92:
            buf.append(92)
            buf.append(b)
        elif b == 10:
            buf.append(92)
            buf.append(110)
        elif b == 9:
            buf.append(92)
            buf.append(116)
        elif b == 13:
            buf.append(92)
            buf.append(114)
        else:
            buf.append(b)
    buf.append(34)
    out += String(unsafe_from_utf8=Span(buf))


def _dump_into(ast: Ast, id: Int, mut out: String):
    if id == 0:
        out += "_"
        return
    ref node = ast.nodes[id]
    out += "("
    out += kind_name(node.kind)
    if node.op != NO_OP:
        out += " "
        out += op_name(node.op)
    if node.text.byte_length() > 0:
        out += " "
        _write_quoted(out, node.text)
    for kid in node.kids:
        out += " "
        _dump_into(ast, kid, out)
    out += ")"


def dump(ast: Ast, id: Int) -> String:
    var out = String()
    _dump_into(ast, id, out)
    return out^
