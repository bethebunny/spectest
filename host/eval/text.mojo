"""Source text and locations, as errors and explanations quote them."""

from check.spec import Spec


def normalize(text: String) -> String:
    """Drops comments and collapses whitespace outside string literals."""
    var out = String()
    var in_str = False
    var escaped = False
    var in_comment = False
    var pending_space = False
    for cp in text.codepoints():
        var ch = String(cp)
        if in_comment:
            if ch == "\n":
                in_comment = False
                pending_space = True
            continue
        if in_str:
            out += ch
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == "#":
            in_comment = True
            continue
        if ch in " \n\t\r":
            pending_space = True
            continue
        if pending_space and out.byte_length() > 0:
            out += " "
        pending_space = False
        out += ch
        if ch == '"':
            in_str = True
    return out^


def source_text(spec: Spec, node: Int) -> String:
    """The source text of a node, comments dropped and whitespace collapsed."""
    var text = normalize(spec.ast.source_text(node))
    if text.byte_length() == 0:
        return String("<", Int(spec.ast.nodes[node].kind), ">")
    return text^


def short(text: String, limit: Int) -> String:
    if text.byte_length() <= limit:
        return text.copy()
    var cut = limit - 3
    var bytes = text.as_bytes()
    while cut > 0 and (Int(bytes[cut]) & 0xC0) == 0x80:
        cut -= 1
    return String(text[byte = 0 : cut], "...")


def located(spec: Spec, node: Int, message: String) -> String:
    """`message (at path:line:col: source text)`."""
    return String(
        message,
        " (at ",
        spec.ast.location(node),
        ": ",
        short(source_text(spec, node), 100),
        ")",
    )
