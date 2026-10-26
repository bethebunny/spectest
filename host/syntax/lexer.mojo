"""Tokens and the layout rule.

Blocks are indentation-based. A logical line starts at the beginning of a physical
line outside brackets. A line whose first word is a block opener (`fn`, `new`,
`method`, `model`, `interface`, `partition`, followed by a name) opens a block when
the next line is indented deeper: the lexer emits INDENT, and DEDENT when the
indentation returns. Following lines indented deeper than any other line continue
it. Newlines inside `()`, `[]` and `{}` are ignored, as are blank and comment-only
lines. `perf` takes the rest of its line raw.
"""

from syntax.ast import Span as SrcSpan, Diagnostic

comptime T_NAME: UInt8 = 0
comptime T_NUMBER: UInt8 = 1
comptime T_STRING: UInt8 = 2
comptime T_OP: UInt8 = 3
comptime T_PERF: UInt8 = 4
comptime T_NEWLINE: UInt8 = 5
comptime T_INDENT: UInt8 = 6
comptime T_DEDENT: UInt8 = 7
comptime T_EOF: UInt8 = 8


@fieldwise_init
struct Token(Copyable, Movable):
    var kind: UInt8
    var text: String
    """Names and operators: the text. Strings: the decoded value. Perf: the stripped
    rest of the line. Numbers: the literal."""
    var start: Int
    var end: Int
    var line: Int
    var col: Int
    var end_col: Int

    def span(self) -> SrcSpan:
        return SrcSpan(self.start, self.end, self.line, self.col)


def syntax_error(path: String, span: SrcSpan, message: String) -> Error:
    """An `Error` whose message is the diagnostic text `path:line:col: message`."""
    return Error(String(Diagnostic(path.copy(), span, message.copy())))


def _is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def _is_hex(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)


def _is_alpha(c: Int) -> Bool:
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95


def _is_alnum(c: Int) -> Bool:
    return _is_alpha(c) or _is_digit(c)


def _is_space(c: Int) -> Bool:
    return c == 32 or c == 9 or c == 11 or c == 12


def _hex_value(c: Int) -> Int:
    if c >= 97:
        return c - 87
    if c >= 65:
        return c - 55
    return c - 48


def _starts_with(src: Span[Byte, _], i: Int, end: Int, word: StaticString) -> Bool:
    var w = word.as_bytes()
    if i + len(w) > end:
        return False
    for k in range(len(w)):
        if src[i + k] != w[k]:
            return False
    return True


struct _Bracket(Copyable, Movable):
    var open: Int
    var line: Int
    var col: Int
    var start: Int

    def __init__(out self, open: Int, line: Int, col: Int, start: Int):
        self.open = open
        self.line = line
        self.col = col
        self.start = start


struct Lexer:
    var path: String
    var tokens: List[Token]
    var brackets: List[_Bracket]
    var stack: List[Int]
    # The current logical line.
    var has_cur: Bool
    var cur_indent: Int
    var cur_opener: Bool
    var cur_perf: Bool
    var last_line: Int
    var last_end: Int
    var last_col: Int
    # The current physical line.
    var line_no: Int
    var line_start: Int
    var cp_off: Int
    var cp_col: Int

    def __init__(out self, path: String):
        self.path = path.copy()
        self.tokens = List[Token]()
        self.brackets = List[_Bracket]()
        self.stack = [0]
        self.has_cur = False
        self.cur_indent = 0
        self.cur_opener = False
        self.cur_perf = False
        self.last_line = 1
        self.last_end = 0
        self.last_col = 1
        self.line_no = 0
        self.line_start = 0
        self.cp_off = 0
        self.cp_col = 1

    def col_at(mut self, src: Span[Byte, _], pos: Int) -> Int:
        """1-based column, in code points, of byte offset `pos` on the current line.
        Offsets are asked in increasing order within a line."""
        if pos < self.cp_off:
            self.cp_off = self.line_start
            self.cp_col = 1
        var col = self.cp_col
        for i in range(self.cp_off, pos):
            if (Int(src[i]) & 0xC0) != 0x80:
                col += 1
        self.cp_off = pos
        self.cp_col = col
        return col

    def error(self, line: Int, col: Int, start: Int, message: String) -> Error:
        return syntax_error(self.path, SrcSpan(start, start + 1, line, col), message)

    def emit(mut self, kind: UInt8, var text: String, start: Int, end: Int, col: Int, end_col: Int):
        self.tokens.append(Token(kind, text^, start, end, self.line_no, col, end_col))
        if self.has_cur:
            self.last_line = self.line_no
            self.last_end = end
            self.last_col = end_col

    def emit_layout(mut self, kind: UInt8, text: String, offset: Int, line: Int, col: Int):
        self.tokens.append(Token(kind, text.copy(), offset, offset, line, col, col))

    def run(mut self, src: Span[Byte, _]) raises -> List[Token]:
        var n = len(src)
        var pos = 0
        var last_line_start: Int
        var last_line_end: Int
        var ln = 0
        while True:
            var end = pos
            while end < n and src[end] != 10:
                end += 1
            ln += 1
            last_line_start = pos
            var stop = end
            if stop > pos and src[stop - 1] == 13:
                stop -= 1
            last_line_end = stop
            self.line_no = ln
            self.line_start = pos
            self.cp_off = pos
            self.cp_col = 1
            self.line(src, pos, stop)
            if end >= n:
                break
            pos = end + 1
        if len(self.brackets) > 0:
            ref b = self.brackets[len(self.brackets) - 1]
            raise self.error(
                b.line, b.col, b.start, "'" + chr(b.open) + "' is never closed"
            )
        self.line_no = ln
        self.line_start = last_line_start
        self.cp_off = last_line_start
        self.cp_col = 1
        var last_col = self.col_at(src, last_line_end)
        if self.has_cur:
            self.emit_layout(T_NEWLINE, "\n", self.last_end, self.last_line, self.last_col)
        while len(self.stack) > 1:
            _ = self.stack.pop()
            self.emit_layout(T_DEDENT, "", last_line_end, ln, last_col)
        self.emit_layout(T_EOF, "", last_line_end, ln, last_col)
        var out = self.tokens^
        self.tokens = List[Token]()
        return out^

    def opens(self, src: Span[Byte, _], i: Int, end: Int, word: StaticString) -> Bool:
        if not _starts_with(src, i, end, word):
            return False
        var j = i + word.byte_length()
        if j < end and _is_space(Int(src[j])):
            while j < end and _is_space(Int(src[j])):
                j += 1
            return j < end and _is_alpha(Int(src[j]))
        return False

    def is_opener(self, src: Span[Byte, _], i: Int, end: Int) -> Bool:
        return (
            self.opens(src, i, end, "fn")
            or self.opens(src, i, end, "new")
            or self.opens(src, i, end, "method")
            or self.opens(src, i, end, "model")
            or self.opens(src, i, end, "interface")
            or self.opens(src, i, end, "partition")
        )

    def is_perf(self, src: Span[Byte, _], i: Int, end: Int) -> Bool:
        if not _starts_with(src, i, end, "perf"):
            return False
        return i + 4 == end or _is_space(Int(src[i + 4])) or Int(src[i + 4]) == 13

    def line(mut self, src: Span[Byte, _], start: Int, end: Int) raises:
        var i = start
        while i < end and (src[i] == 32 or src[i] == 9):
            i += 1
        var indent = i - start
        var blank = i >= end
        if not blank:
            # A tab anywhere in the leading whitespace.
            for k in range(start, i):
                if src[k] == 9:
                    raise self.error(
                        self.line_no, k - start + 1, k,
                        "tab in indentation: indent with spaces",
                    )
        if len(self.brackets) > 0:
            self.scan(src, i, end)
            return
        if blank or src[i] == 35:
            return
        if self.has_cur and not self.cur_opener and indent > self.cur_indent:
            if self.cur_perf:
                self.perf_text(src, i, end)
            else:
                self.scan(src, i, end)
            return
        var col = indent + 1
        if self.has_cur:
            self.emit_layout(T_NEWLINE, "\n", self.last_end, self.last_line, self.last_col)
        if self.has_cur and self.cur_opener and indent > self.stack[len(self.stack) - 1]:
            self.stack.append(indent)
            self.emit_layout(T_INDENT, "", i, self.line_no, col)
        elif indent > self.stack[len(self.stack) - 1]:
            raise self.error(self.line_no, col, i, "unexpected indentation")
        else:
            while indent < self.stack[len(self.stack) - 1]:
                _ = self.stack.pop()
                self.emit_layout(T_DEDENT, "", i, self.line_no, col)
            if indent != self.stack[len(self.stack) - 1]:
                raise self.error(
                    self.line_no, col, i,
                    "indentation does not match any enclosing block",
                )
        var perf = self.is_perf(src, i, end)
        self.has_cur = True
        self.cur_indent = indent
        self.cur_opener = self.is_opener(src, i, end)
        self.cur_perf = perf
        self.last_line = self.line_no
        self.last_end = i
        self.last_col = col
        if perf:
            self.emit(T_NAME, "perf", i, i + 4, col, col + 4)
            self.perf_text(src, i + 4, end)
        else:
            self.scan(src, i, end)

    def perf_text(mut self, src: Span[Byte, _], start: Int, end: Int) raises:
        var a = start
        while a < end and _is_space(Int(src[a])):
            a += 1
        var b = end
        while b > a and _is_space(Int(src[b - 1])):
            b -= 1
        if a >= b:
            return
        var col = self.col_at(src, a)
        var end_col = self.col_at(src, b)
        self.emit(T_PERF, _text(src, a, b), a, b, col, end_col)

    def scan(mut self, src: Span[Byte, _], begin: Int, end: Int) raises:
        var i = begin
        while i < end:
            var c = Int(src[i])
            if c == 32 or c == 9:
                i += 1
                continue
            if c == 35:
                return
            if c == 34:
                i = self.string(src, i, end)
                continue
            if _is_digit(c):
                i = self.number(src, i, end)
                continue
            if _is_alpha(c):
                var j = i + 1
                while j < end and _is_alnum(Int(src[j])):
                    j += 1
                var col = self.col_at(src, i)
                self.emit(T_NAME, _text(src, i, j), i, j, col, col + (j - i))
                i = j
                continue
            var width = 1
            if i + 1 < end:
                var d = Int(src[i + 1])
                if (
                    (c == 45 and d == 62)
                    or (c == 61 and d == 61)
                    or (c == 33 and d == 61)
                    or (c == 60 and (d == 61 or d == 60))
                    or (c == 62 and (d == 61 or d == 62))
                    or (c == 47 and d == 47)
                    or (c == 42 and d == 42)
                ):
                    width = 2
            if width == 1 and not (
                c == 60 or c == 62 or c == 61 or c == 43 or c == 45 or c == 42
                or c == 47 or c == 37 or c == 124 or c == 38 or c == 40
                or c == 41 or c == 91 or c == 93 or c == 123 or c == 125
                or c == 44 or c == 58 or c == 46
            ):
                var col = self.col_at(src, i)
                var n = 1
                if c >= 0xF0:
                    n = 4
                elif c >= 0xE0:
                    n = 3
                elif c >= 0xC0:
                    n = 2
                var shown = _text(src, i, min(i + n, end))
                raise self.error(
                    self.line_no, col, i, "unexpected character '" + shown + "'"
                )
            var col = self.col_at(src, i)
            if c == 40 or c == 91 or c == 123:
                self.brackets.append(_Bracket(c, self.line_no, col, i))
            elif c == 41 or c == 93 or c == 125:
                if len(self.brackets) == 0:
                    raise self.error(
                        self.line_no, col, i, "unmatched '" + chr(c) + "'"
                    )
                var opened = self.brackets.pop()
                var want = 40 if c == 41 else (91 if c == 93 else 123)
                if opened.open != want:
                    raise self.error(
                        self.line_no, col, i,
                        "'" + chr(c) + "' does not match '" + chr(opened.open)
                        + "' at " + String(opened.line) + ":" + String(opened.col),
                    )
            self.emit(
                T_OP, _text(src, i, i + width), i, i + width, col, col + width
            )
            i += width

    def digits(self, src: Span[Byte, _], i: Int, end: Int, hex: Bool) -> Int:
        """End of `d(_?d)*` starting at `i` (which holds a digit), or `i` if none."""
        var j = i
        if j >= end:
            return i
        var c = Int(src[j])
        if not (_is_hex(c) if hex else _is_digit(c)):
            return i
        j += 1
        while j < end:
            c = Int(src[j])
            if _is_hex(c) if hex else _is_digit(c):
                j += 1
            elif c == 95 and j + 1 < end and (
                _is_hex(Int(src[j + 1])) if hex else _is_digit(Int(src[j + 1]))
            ):
                j += 2
            else:
                break
        return j

    def number(mut self, src: Span[Byte, _], i: Int, end: Int) raises -> Int:
        var col = self.col_at(src, i)
        var prev_dot = False
        if len(self.tokens) > 0:
            ref prev = self.tokens[len(self.tokens) - 1]
            prev_dot = prev.kind == T_OP and prev.text == "."
        if prev_dot:
            var j = i
            while j < end and _is_digit(Int(src[j])):
                j += 1
            if j < end and (_is_alnum(Int(src[j]))):
                raise self.error(
                    self.line_no, col, i,
                    "a tuple field is a decimal index, e.g. p.0",
                )
            self.emit(T_NUMBER, _text(src, i, j), i, j, col, col + (j - i))
            return j
        var j: Int
        if (
            i + 1 < end
            and src[i] == 48
            and (src[i + 1] == 120 or src[i + 1] == 88)
        ):
            var k = self.digits(src, i + 2, end, True)
            if k == i + 2:
                raise self.error(
                    self.line_no, col, i,
                    "hexadecimal literal needs digits after 0x",
                )
            var dotted = False
            if k < end and src[k] == 46:
                dotted = True
                k += 1
                k = self.digits(src, k, end, True)
            var has_exp = False
            if k < end and (src[k] == 112 or src[k] == 80):
                var e = k + 1
                if e < end and (src[e] == 43 or src[e] == 45):
                    e += 1
                var e2 = e
                while e2 < end and _is_digit(Int(src[e2])):
                    e2 += 1
                if e2 > e:
                    has_exp = True
                    k = e2
            if dotted and not has_exp:
                var text = _text(src, i, k)
                raise self.error(
                    self.line_no, col, i,
                    "hexadecimal float " + text
                    + " needs a binary exponent, e.g. " + text + "p0",
                )
            j = k
        else:
            j = self.digits(src, i, end, False)
            if j < end and src[j] == 46:
                var f = self.digits(src, j + 1, end, False)
                if f > j + 1:
                    j = f
            if j < end and (src[j] == 101 or src[j] == 69):
                var e = j + 1
                if e < end and (src[e] == 43 or src[e] == 45):
                    e += 1
                var e2 = e
                while e2 < end and _is_digit(Int(src[e2])):
                    e2 += 1
                if e2 > e:
                    j = e2
        if j < end and (_is_alnum(Int(src[j]))):
            var stop = j
            while stop < end and (_is_alnum(Int(src[stop])) or src[stop] == 46):
                stop += 1
            raise self.error(
                self.line_no, col, i,
                "invalid numeric literal '" + _text(src, i, stop) + "'",
            )
        self.emit(T_NUMBER, _text(src, i, j), i, j, col, col + (j - i))
        return j

    def string(mut self, src: Span[Byte, _], start: Int, end: Int) raises -> Int:
        var col = self.col_at(src, start)
        var i = start + 1
        var out = List[UInt8]()
        while True:
            if i >= end:
                raise self.error(self.line_no, col, start, "unterminated string")
            var c = Int(src[i])
            if c == 34:
                i += 1
                break
            if c != 92:
                out.append(UInt8(c))
                i += 1
                continue
            if i + 1 >= end:
                raise self.error(self.line_no, col, start, "unterminated string")
            var e = Int(src[i + 1])
            var ecol = self.col_at(src, i)
            if e == 110:
                out.append(10)
                i += 2
            elif e == 116:
                out.append(9)
                i += 2
            elif e == 114:
                out.append(13)
                i += 2
            elif e == 48:
                out.append(0)
                i += 2
            elif e == 92:
                out.append(92)
                i += 2
            elif e == 34:
                out.append(34)
                i += 2
            elif e == 120:
                if not (
                    i + 3 < end and _is_hex(Int(src[i + 2])) and _is_hex(Int(src[i + 3]))
                ):
                    raise self.error(self.line_no, ecol, i, "\\x needs two hex digits")
                var code = _hex_value(Int(src[i + 2])) * 16 + _hex_value(Int(src[i + 3]))
                _append_codepoint(out, code)
                i += 4
            elif e == 117:
                var code = 0
                var next = i + 2
                if next < end and src[next] == 123:
                    var k = next + 1
                    var count = 0
                    while k < end and _is_hex(Int(src[k])) and count < 7:
                        code = code * 16 + _hex_value(Int(src[k]))
                        k += 1
                        count += 1
                    if count < 1 or count > 6 or k >= end or src[k] != 125:
                        raise self.error(
                            self.line_no, ecol, i, "\\u needs {hex} or four hex digits"
                        )
                    next = k + 1
                else:
                    if not (
                        next + 3 < end
                        and _is_hex(Int(src[next]))
                        and _is_hex(Int(src[next + 1]))
                        and _is_hex(Int(src[next + 2]))
                        and _is_hex(Int(src[next + 3]))
                    ):
                        raise self.error(
                            self.line_no, ecol, i, "\\u needs {hex} or four hex digits"
                        )
                    for k in range(4):
                        code = code * 16 + _hex_value(Int(src[next + k]))
                    next += 4
                if code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF):
                    raise self.error(
                        self.line_no, ecol, i,
                        "\\u" + String(hex(code))[byte=2:]
                        + " is not a Unicode scalar value",
                    )
                _append_codepoint(out, code)
                i = next
            else:
                # The escape's character may be multi-byte.
                var n = 1
                if e >= 0xF0:
                    n = 4
                elif e >= 0xE0:
                    n = 3
                elif e >= 0xC0:
                    n = 2
                raise self.error(
                    self.line_no, ecol, i,
                    "unknown escape \\" + _text(src, i + 1, min(i + 1 + n, end)),
                )
        var end_col = self.col_at(src, i)
        self.emit(
            T_STRING, String(unsafe_from_utf8=Span(out)), start, i, col, end_col
        )
        return i


def _text(src: Span[Byte, _], a: Int, b: Int) -> String:
    return String(unsafe_from_utf8=src[a:b])


def _append_codepoint(mut out: List[UInt8], code: Int):
    var s = chr(code)
    for b in s.as_bytes():
        out.append(b)


def tokenize(source: String, path: String) raises -> List[Token]:
    """Tokens of a spec source, with NEWLINE, INDENT and DEDENT from the layout rule."""
    var lexer = Lexer(path)
    return lexer.run(source.as_bytes())
