"""Source text and locations, as errors and explanations quote them."""

from spec.spec import Spec


comptime SOURCE_CHARS = 100
"""The most bytes of source text a located message quotes."""


__enum _Scan(ImplicitlyCopyable):
    """Where `normalize` is: in code, in a string literal, just after a backslash in
    one, or in a comment."""

    case CODE
    case STRING
    case ESCAPE
    case COMMENT


def normalize(text: String) -> String:
    """Drops comments and collapses whitespace outside string literals."""
    var out = String()
    var scan = _Scan.CODE
    var pending_space = False
    for cp in text.codepoints():
        var ch = String(cp)
        match scan:
            case .COMMENT:
                if ch == "\n":
                    scan = .CODE
                    pending_space = True
            case .ESCAPE:
                out += ch
                scan = .STRING
            case .STRING:
                out += ch
                if ch == "\\":
                    scan = .ESCAPE
                elif ch == '"':
                    scan = .CODE
            case .CODE:
                if ch == "#":
                    scan = .COMMENT
                elif ch in " \n\t\r":
                    pending_space = True
                else:
                    if pending_space and out:
                        out += " "
                    pending_space = False
                    out += ch
                    if ch == '"':
                        scan = .STRING
    return out^


def source_text(spec: Spec, node: Int) -> String:
    """The source text of a node, comments dropped and whitespace collapsed."""
    var text = normalize(spec.ast.source_text(node))
    if not text:
        return String("<", Int(spec.ast.nodes[node].kind), ">")
    return text^


def short(text: String, limit: Int) -> String:
    """At most `limit` bytes of `text`, cut at a code point and marked with `...`."""
    if text.byte_length() <= limit:
        return text.copy()
    var cut = limit - 3
    while not StringSlice(text).is_codepoint_boundary(cut):
        cut -= 1
    return String(text[byte=0:cut], "...")


def located(spec: Spec, node: Int, message: String) -> String:
    """`message (at path:line:col: source text)`."""
    return String(t"{message} (at {spec.ast.location(node)}: {short(source_text(spec, node), SOURCE_CHARS)})")
