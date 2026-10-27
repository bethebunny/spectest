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
from syntax.chars import is_digit, is_hex, is_alpha, is_alnum, is_space, hex_value

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
    """Names and operators: the text. Strings: the decoded value. Perf: the stripped rest
    of the line. Numbers: the literal."""
    var start: Int
    var end: Int
    var line: Int
    var col: Int
    var end_col: Int

    def span(self) -> SrcSpan:
        return SrcSpan(self.start, self.end, self.line, self.col)

    def is_op(self, op: StaticString) -> Bool:
        return self.kind == T_OP and self.text == op


def syntax_error(path: String, span: SrcSpan, message: String) -> Error:
    """An `Error` whose message is `path:line:col: message`."""
    return Error(String(Diagnostic(path.copy(), span, message.copy())))


def _at(src: Span[Byte, _], i: Int, end: Int) -> Int:
    """The byte at `i`, or 0 at or past `end`."""
    return Int(src[i]) if i < end else 0


def _text(src: Span[Byte, _], a: Int, b: Int) -> String:
    return String(unsafe_from_utf8=src[a:b])


def _char_width(lead: Int) -> Int:
    """The bytes in a UTF-8 character that starts with `lead`."""
    return 4 if lead >= 0xF0 else (3 if lead >= 0xE0 else (2 if lead >= 0xC0 else 1))


def _char_at(src: Span[Byte, _], i: Int, end: Int) -> String:
    return _text(src, i, min(i + _char_width(Int(src[i])), end))


comptime _TWO_CHAR_OPS = "-> == != <= << >= >> // **"
comptime _ONE_CHAR_OPS = "<>=+-*/%|&()[]{},:."
comptime _OPENERS = "fn new method model interface partition"


def _in(c: Int, chars: StaticString) -> Bool:
    return chr(c) in chars


def _digits(src: Span[Byte, _], i: Int, end: Int, *, hex: Bool) -> Int:
    """End of the run `d(_?d)*` of digits starting at `i`, or `i` if it starts with none."""
    var j = i
    while True:
        var c = _at(src, j, end)
        var next = _at(src, j + 1, end)
        if is_hex(c) if hex else is_digit(c):
            j += 1
        elif j > i and c == ord("_") and (is_hex(next) if hex else is_digit(next)):
            j += 1
        else:
            return j


def _exponent(src: Span[Byte, _], i: Int, end: Int, marks: StaticString) -> Int:
    """End of an exponent (a mark, an optional sign and digits) at `i`, or `i` if none."""
    if not _in(_at(src, i, end), marks):
        return i
    var first = i + (2 if _in(_at(src, i + 1, end), "+-") else 1)
    var j = first
    while is_digit(_at(src, j, end)):
        j += 1
    return j if j > first else i


def _opens(src: Span[Byte, _], i: Int, end: Int, word: String) -> Bool:
    """Whether `word` and then a name start at `i`."""
    var j = i + word.byte_length()
    if _text(src, i, min(j, end)) != word or not is_space(_at(src, j, end)):
        return False
    while is_space(_at(src, j, end)):
        j += 1
    return is_alpha(_at(src, j, end))


def _is_opener(src: Span[Byte, _], i: Int, end: Int) -> Bool:
    return any([_opens(src, i, end, String(word)) for word in _OPENERS.split(" ")])


def _is_perf(src: Span[Byte, _], i: Int, end: Int) -> Bool:
    var after = _at(src, i + 4, end)
    var ends_word = i + 4 == end or is_space(after) or after == 13
    return _text(src, i, min(i + 4, end)) == "perf" and ends_word


@fieldwise_init
struct _Bracket(Copyable, Movable):
    var open: Int
    var line: Int
    var col: Int
    var start: Int


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

    def block_indent(self) -> Int:
        return self.stack[len(self.stack) - 1]

    def col_at(mut self, src: Span[Byte, _], pos: Int) -> Int:
        """1-based column, in code points, of byte offset `pos` on the current line."""
        if pos < self.cp_off:  # offsets within a line are asked in increasing order
            self.cp_off = self.line_start
            self.cp_col = 1
        var col = self.cp_col
        for i in range(self.cp_off, pos):
            if (Int(src[i]) & 0xC0) != 0x80:
                col += 1
        self.cp_off = pos
        self.cp_col = col
        return col

    def error(self, line: Int, col: Int, start: Int, message: Some[Writable]) -> Error:
        return syntax_error(self.path, SrcSpan(start, start + 1, line, col), String(message))

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
            while end < n and Int(src[end]) != ord("\n"):
                end += 1
            ln += 1
            last_line_start = pos
            var stop = end - 1 if end > pos and Int(src[end - 1]) == 13 else end
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
            raise self.error(b.line, b.col, b.start, t"'{chr(b.open)}' is never closed")
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

    def line(mut self, src: Span[Byte, _], start: Int, end: Int) raises:
        var i = start
        while _at(src, i, end) == ord(" ") or _at(src, i, end) == ord("\t"):
            i += 1
        var indent = i - start
        var blank = i >= end
        if not blank:
            for k in range(start, i):
                if Int(src[k]) == ord("\t"):
                    raise self.error(
                        self.line_no, k - start + 1, k, "tab in indentation: indent with spaces"
                    )
        if len(self.brackets) > 0:
            self.scan(src, i, end)
            return
        if blank or Int(src[i]) == ord("#"):
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
        if self.has_cur and self.cur_opener and indent > self.block_indent():
            self.stack.append(indent)
            self.emit_layout(T_INDENT, "", i, self.line_no, col)
        elif indent > self.block_indent():
            raise self.error(self.line_no, col, i, "unexpected indentation")
        else:
            while indent < self.block_indent():
                _ = self.stack.pop()
                self.emit_layout(T_DEDENT, "", i, self.line_no, col)
            if indent != self.block_indent():
                raise self.error(
                    self.line_no, col, i, "indentation does not match any enclosing block"
                )
        var perf = _is_perf(src, i, end)
        self.has_cur = True
        self.cur_indent = indent
        self.cur_opener = _is_opener(src, i, end)
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
        while is_space(_at(src, a, end)):
            a += 1
        var b = end
        while b > a and is_space(Int(src[b - 1])):
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
            if c == ord(" ") or c == ord("\t"):
                i += 1
            elif c == ord("#"):
                return
            elif c == ord('"'):
                i = self.string(src, i, end)
            elif is_digit(c):
                i = self.number(src, i, end)
            elif is_alpha(c):
                var j = i + 1
                while is_alnum(_at(src, j, end)):
                    j += 1
                var col = self.col_at(src, i)
                self.emit(T_NAME, _text(src, i, j), i, j, col, col + (j - i))
                i = j
            else:
                i = self.operator(src, i, end)

    def operator(mut self, src: Span[Byte, _], i: Int, end: Int) raises -> Int:
        var c = Int(src[i])
        var col = self.col_at(src, i)
        var pair = _text(src, i, min(i + 2, end))
        var is_pair = pair.byte_length() == 2 and " " not in pair and pair in _TWO_CHAR_OPS
        var width = 2 if is_pair else 1
        if width == 1 and not (c < 128 and _in(c, _ONE_CHAR_OPS)):
            raise self.error(
                self.line_no, col, i, t"unexpected character '{_char_at(src, i, end)}'"
            )
        if _in(c, "([{"):
            self.brackets.append(_Bracket(c, self.line_no, col, i))
        elif _in(c, ")]}"):
            if len(self.brackets) == 0:
                raise self.error(self.line_no, col, i, t"unmatched '{chr(c)}'")
            var opened = self.brackets.pop()
            if String("([{").find(chr(opened.open)) != String(")]}").find(chr(c)):
                raise self.error(
                    self.line_no, col, i,
                    t"'{chr(c)}' does not match '{chr(opened.open)}' at {opened.line}:{opened.col}",
                )
        self.emit(T_OP, _text(src, i, i + width), i, i + width, col, col + width)
        return i + width

    def number(mut self, src: Span[Byte, _], i: Int, end: Int) raises -> Int:
        var col = self.col_at(src, i)
        var j = i
        var after_dot = len(self.tokens) > 0 and self.tokens[len(self.tokens) - 1].is_op(".")
        if after_dot:
            while is_digit(_at(src, j, end)):
                j += 1
            if is_alnum(_at(src, j, end)):
                raise self.error(
                    self.line_no, col, i, "a tuple field is a decimal index, e.g. p.0"
                )
        elif _at(src, i, end) == ord("0") and _in(_at(src, i + 1, end), "xX"):
            j = _digits(src, i + 2, end, hex=True)
            if j == i + 2:
                raise self.error(
                    self.line_no, col, i, "hexadecimal literal needs digits after 0x"
                )
            var dotted = _at(src, j, end) == ord(".")
            if dotted:
                j = _digits(src, j + 1, end, hex=True)
            var with_exponent = _exponent(src, j, end, "pP")
            if dotted and with_exponent == j:
                var text = _text(src, i, j)
                raise self.error(
                    self.line_no, col, i,
                    t"hexadecimal float {text} needs a binary exponent, e.g. {text}p0",
                )
            j = with_exponent
        else:
            j = _digits(src, i, end, hex=False)
            if _at(src, j, end) == ord("."):
                var fraction = _digits(src, j + 1, end, hex=False)
                j = fraction if fraction > j + 1 else j
            j = _exponent(src, j, end, "eE")
        if not after_dot and is_alnum(_at(src, j, end)):
            var stop = j
            while is_alnum(_at(src, stop, end)) or _at(src, stop, end) == ord("."):
                stop += 1
            raise self.error(
                self.line_no, col, i, t"invalid numeric literal '{_text(src, i, stop)}'"
            )
        self.emit(T_NUMBER, _text(src, i, j), i, j, col, col + (j - i))
        return j

    def string(mut self, src: Span[Byte, _], start: Int, end: Int) raises -> Int:
        var col = self.col_at(src, start)
        var i = start + 1
        var out = List[UInt8]()
        var simple = {
            ord("n"): 10, ord("t"): 9, ord("r"): 13, ord("0"): 0, ord("\\"): 92, ord('"'): 34
        }
        while True:
            if i >= end:
                raise self.error(self.line_no, col, start, "unterminated string")
            var c = Int(src[i])
            if c == ord('"'):
                i += 1
                break
            if c != ord("\\"):
                out.append(src[i])
                i += 1
                continue
            if i + 1 >= end:
                raise self.error(self.line_no, col, start, "unterminated string")
            var e = Int(src[i + 1])
            var ecol = self.col_at(src, i)
            if e in simple:
                out.append(UInt8(simple[e]))
                i += 2
            elif e == ord("x"):
                var hi = _at(src, i + 2, end)
                var lo = _at(src, i + 3, end)
                if not (is_hex(hi) and is_hex(lo)):
                    raise self.error(self.line_no, ecol, i, "\\x needs two hex digits")
                _append_codepoint(out, hex_value(hi) * 16 + hex_value(lo))
                i += 4
            elif e == ord("u"):
                var code = 0
                var next = i + 2
                var braced = _at(src, next, end) == ord("{")
                var digits_end = next + 1 if braced else next
                var count = 0
                while is_hex(_at(src, digits_end, end)) and count < (7 if braced else 4):
                    code = code * 16 + hex_value(_at(src, digits_end, end))
                    digits_end += 1
                    count += 1
                if braced:
                    if count < 1 or count > 6 or _at(src, digits_end, end) != ord("}"):
                        raise self.error(
                            self.line_no, ecol, i, "\\u needs {hex} or four hex digits"
                        )
                    digits_end += 1
                elif count < 4:
                    raise self.error(
                        self.line_no, ecol, i, "\\u needs {hex} or four hex digits"
                    )
                if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
                    raise self.error(
                        self.line_no, ecol, i,
                        t"\\u{String(hex(code))[byte=2:]} is not a Unicode scalar value",
                    )
                _append_codepoint(out, code)
                i = digits_end
            else:
                raise self.error(
                    self.line_no, ecol, i, t"unknown escape \\{_char_at(src, i + 1, end)}"
                )
        var end_col = self.col_at(src, i)
        self.emit(T_STRING, String(unsafe_from_utf8=Span(out)), start, i, col, end_col)
        return i


def _append_codepoint(mut out: List[UInt8], code: Int):
    out.extend(chr(code).as_bytes())


def tokenize(source: String, path: String) raises -> List[Token]:
    """Tokens of a spec source, with NEWLINE, INDENT and DEDENT from the layout rule."""
    var lexer = Lexer(path)
    return lexer.run(source.as_bytes())
