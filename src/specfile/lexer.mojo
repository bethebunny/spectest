"""Tokens and the layout rule.

Blocks are indentation-based. A logical line starts at the beginning of a physical
line outside brackets. A line whose first word is a block opener (`fn`, `new`,
`method`, `model`, `interface`, `partition`, followed by a name) opens a block when
the next line is indented deeper: the lexer emits INDENT, and DEDENT when the
indentation returns. Following lines indented deeper than any other line continue
it. Newlines inside `()`, `[]` and `{}` are ignored, as are blank and comment-only
lines. `perf` takes the rest of its line raw.
"""

from spec.ast import Diagnostic, Span
from specfile.chars import is_digit, is_word_char, is_word_start


__enum TokenKind(Equatable, ImplicitlyCopyable, Writable):
    case NAME
    case NUMBER
    case STRING
    case OP
    case PERF
    case NEWLINE
    case INDENT
    case DEDENT
    case EOF

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()

    def is_layout(self) -> Bool:
        """NEWLINE, INDENT or DEDENT, which the layout rule adds between the words."""
        return self in (Self.NEWLINE, Self.INDENT, Self.DEDENT)


@fieldwise_init
struct Token(Copyable):
    var kind: TokenKind
    var text: String
    """Names and operators: the text. Strings: the decoded value. Perf: the stripped rest
    of the line. Numbers: the literal."""
    var span: Span
    var end_column: Int

    def is_op(self, op: StaticString) -> Bool:
        return self.kind == .OP and self.text == op

    def is_keyword(self, word: StaticString) -> Bool:
        return self.kind == .NAME and self.text == word


def syntax_error(path: String, span: Span, message: String) -> Error:
    """An `Error` whose message is `path:line:column: message`."""
    return Error(String(Diagnostic(path.copy(), span, message.copy())))


def tokens(text: StringSpan, path: String) raises -> List[Token]:
    """Tokens of a spec source, with NEWLINE, INDENT and DEDENT from the layout rule."""
    var lexer = _Lexer(text, path)
    var start = 0
    for number, line in enumerate(text.split("\n"), start=1):
        var end = start + line.removesuffix("\r").byte_length()
        lexer.line = _Line(number=number, start=start, end=end)
        lexer.lex_line()
        start += line.byte_length() + 1
    return lexer.finished()


comptime _SPACES = " \t\x0b\x0c"
comptime _ONE_CHAR_OPS = "<>=+-*/%|&()[]{},:."
comptime _TWO_CHAR_OPS: Array[StaticString, 9] = [
    "->", "==", "!=", "<=", "<<", ">=", ">>", "//", "**"
]
comptime _OPENERS: Array[StaticString, 6] = [
    "fn", "new", "method", "model", "interface", "partition"
]
comptime _ESCAPED: StaticString = 'ntr0\\"'
comptime _ESCAPES: StaticString = '\n\t\r\x00\\"'
"""What each character of `_ESCAPED` stands for after a backslash, by position."""


def _in(c: Int, chars: StaticString) -> Bool:
    return UInt8(c) in chars.as_bytes()


def _closer(open: Int) -> Int:
    return ord(")") if open == ord("(") else (ord("]") if open == ord("[") else ord("}"))


def _first_byte(text: StringSlice) -> Int:
    """The first byte of `text`, or 0 if it is empty."""
    return Int(text.as_bytes()[0]) if text else 0


def _opens(rest: StringSlice, word: StaticString) -> Bool:
    """Whether `rest` starts with `word`, blanks and a name."""
    if not rest.startswith(word):
        return False
    var after = rest[byte = word.byte_length() :]
    var name = after.lstrip(_SPACES)
    return name.byte_length() < after.byte_length() and is_word_start(_first_byte(name))


def _is_perf(rest: StringSlice) -> Bool:
    if not rest.startswith("perf"):
        return False
    var after = rest[byte=4:]
    return not after or _in(_first_byte(after), " \t\x0b\x0c\r")


@fieldwise_init
struct _Bracket(Copyable):
    var open: Int
    var span: Span


struct _Line(Copyable):
    """The physical line being lexed."""

    var number: Int
    var start: Int
    var end: Int
    """Past its last byte, leaving out the newline and one carriage return before it."""
    var counted: Int
    """An offset whose column is known; columns are mostly asked left to right."""
    var column: Int

    def __init__(out self, *, number: Int, start: Int, end: Int):
        self.number = number
        self.start = start
        self.end = end
        self.counted = start
        self.column = 1

    def column_at(mut self, text: StringSlice, offset: Int) -> Int:
        """1-based column, in code points, of byte `offset` on this line."""
        if offset < self.counted:
            self.counted = self.start
            self.column = 1
        self.column += text[byte = self.counted : offset].count_codepoints()
        self.counted = offset
        return self.column


@fieldwise_init
struct _LogicalLine(TrivialRegisterPassable):
    var indent: Int
    var opener: Bool
    """Its first word opens a block, so a deeper line starts one rather than continuing it."""
    var perf: Bool
    """It is a `perf` clause, whose continuation lines are raw text."""
    var end: Span
    """Where its NEWLINE goes: after its last token."""


struct _Lexer[origin: ImmOrigin]:
    var text: StringSlice[Self.origin]
    var path: String
    var tokens: List[Token]
    var brackets: List[_Bracket]
    var indents: List[Int]
    """The indentation of each open block, the top level's 0 first."""
    var line: _Line
    var logical: Optional[_LogicalLine]
    """None before the first logical line."""

    def __init__(out self, text: StringSlice[Self.origin], path: String):
        self.text = text
        self.path = path.copy()
        self.tokens = []
        self.brackets = []
        self.indents = [0]
        self.line = _Line(number=0, start=0, end=0)
        self.logical = None

    def byte(self, i: Int) -> Int:
        """The byte at `i`, or 0 at or past the end of the line."""
        return Int(self.text.as_bytes()[i]) if i < self.line.end else 0

    def rest_of_line(self, i: Int) -> StringSlice[Self.origin]:
        return self.text[byte = i : self.line.end]

    def char_at(self, i: Int) raises -> String:
        """The character that starts at byte `i`."""
        var chars = self.rest_of_line(i).codepoint_slices()
        return String(next(chars))

    def block_indent(self) -> Int:
        return self.indents[len(self.indents) - 1]

    def column_at(mut self, i: Int) -> Int:
        return self.line.column_at(self.text, i)

    def position(mut self, i: Int) -> Span:
        """The empty span at `i` on this line."""
        return Span(start=i, end=i, line=self.line.number, column=self.column_at(i))

    def error_at(self, span: Span, message: Some[Writable]) -> Error:
        return syntax_error(self.path, span, String(message))

    def span_at(mut self, i: Int) -> Span:
        """The span of the byte at `i` on this line."""
        return Span(start=i, end=i + 1, line=self.line.number, column=self.column_at(i))

    def error(mut self, i: Int, message: Some[Writable]) -> Error:
        return self.error_at(self.span_at(i), message)

    def emit(mut self, kind: TokenKind, *, start: Int, end: Int):
        """Appends a token of the source from `start` to `end`."""
        self.emit_text(kind, String(self.text[byte=start:end]), start=start, end=end)

    def emit_text(mut self, kind: TokenKind, var text: String, *, start: Int, end: Int):
        var span = self.position(start)
        span.end = end
        var after = self.position(end)
        self.tokens.append(Token(kind, text^, span, after.column))
        self.logical.value().end = after

    def layout(mut self, kind: TokenKind, at: Span):
        """Appends a NEWLINE, INDENT, DEDENT or EOF, which stand for no text."""
        self.tokens.append(Token(kind, "\n" if kind == .NEWLINE else "", at, at.column))

    def dedent(mut self, indent: Int, at: Span):
        """Closes the blocks indented deeper than `indent`."""
        while indent < self.block_indent():
            _ = self.indents.pop()
            self.layout(.DEDENT, at)

    def continues(self, indent: Int) -> Bool:
        """Whether a line indented `indent` continues the current logical line."""
        if case .Some(logical) = self.logical:
            return not logical.opener and indent > logical.indent
        return False

    def lex_line(mut self) raises:
        var start = self.line.start
        var rest = self.rest_of_line(start).lstrip(" \t")
        var i = self.line.end - rest.byte_length()
        var indent = i - start
        var tab = self.text[byte=start:i].find("\t")
        if rest and tab >= 0:
            raise self.error(start + tab, "tab in indentation: indent with spaces")
        if self.brackets:
            self.scan(i)
        elif not rest or rest.startswith("#"):
            return
        elif self.continues(indent):
            if self.logical.value().perf:
                self.scan_perf(i)
            else:
                self.scan(i)
        else:
            self.start_logical_line(i, indent)

    def start_logical_line(mut self, i: Int, indent: Int) raises:
        var here = self.position(i)
        var opens_block = False
        if self.logical is not None:
            var previous = self.logical.value()
            self.layout(.NEWLINE, previous.end)
            opens_block = previous.opener
        if opens_block and indent > self.block_indent():
            self.indents.append(indent)
            self.layout(.INDENT, here)
        elif indent > self.block_indent():
            raise self.error(i, "unexpected indentation")
        else:
            self.dedent(indent, here)
            if indent != self.block_indent():
                raise self.error(i, "indentation does not match any enclosing block")
        var rest = self.rest_of_line(i)
        var perf = _is_perf(rest)
        var opener = any([_opens(rest, word) for word in materialize[_OPENERS]()])
        self.logical = _LogicalLine(indent=indent, opener=opener, perf=perf, end=here)
        if perf:
            self.emit(.NAME, start=i, end=i + 4)
            self.scan_perf(i + 4)
        else:
            self.scan(i)

    def finished(mut self) raises -> List[Token]:
        """The tokens, ended by the last NEWLINE, a DEDENT per open block and EOF."""
        if case [*_, bracket] = self.brackets:
            raise self.error_at(bracket.span, t"'{chr(bracket.open)}' is never closed")
        if self.logical is not None:
            var end = self.logical.value().end
            self.layout(.NEWLINE, end)
        var end = self.position(self.line.end)
        self.dedent(0, end)
        self.layout(.EOF, end)
        var tokens: List[Token] = []
        swap(tokens, self.tokens)
        return tokens^

    def scan_perf(mut self, start: Int):
        """The rest of the line as one PERF token, blanks stripped."""
        var left = self.rest_of_line(start).lstrip(_SPACES)
        var a = self.line.end - left.byte_length()
        var b = a + left.rstrip(_SPACES).byte_length()
        if a < b:
            self.emit(.PERF, start=a, end=b)

    def scan(mut self, start: Int) raises:
        var i = start
        while i < self.line.end:
            var c = self.byte(i)
            if c == ord(" ") or c == ord("\t"):
                i += 1
            elif c == ord("#"):
                return
            elif c == ord('"'):
                i = self.scan_string(i)
            elif is_digit(c):
                i = self.scan_number(i)
            elif is_word_start(c):
                i = self.scan_name(i)
            else:
                i = self.scan_operator(i)

    def scan_name(mut self, start: Int) -> Int:
        var end = start + 1
        while is_word_char(self.byte(end)):
            end += 1
        self.emit(.NAME, start=start, end=end)
        return end

    def scan_operator(mut self, start: Int) raises -> Int:
        var c = self.byte(start)
        var rest = self.rest_of_line(start)
        var width = 2 if any([rest.startswith(op) for op in materialize[_TWO_CHAR_OPS]()]) else 1
        if width == 1 and not _in(c, _ONE_CHAR_OPS):
            raise self.error(start, t"unexpected character '{self.char_at(start)}'")
        if _in(c, "([{"):
            self.brackets.append(_Bracket(c, self.span_at(start)))
        elif _in(c, ")]}"):
            if not self.brackets:
                raise self.error(start, t"unmatched '{chr(c)}'")
            var opened = self.brackets.pop()
            if c != _closer(opened.open):
                raise self.error(
                    start, t"'{chr(c)}' does not match '{chr(opened.open)}' at {opened.span}"
                )
        self.emit(.OP, start=start, end=start + width)
        return start + width

    def after_digits(self, start: Int, *, hex: Bool) -> Int:
        """The end of the run `d(_?d)*` of digits at `start`, or `start` if there is none."""
        var end = start
        while True:
            var separated = end > start and self.byte(end) == ord("_")
            if is_digit(self.byte(end + 1 if separated else end), hex=hex):
                end += 2 if separated else 1
            else:
                return end

    def after_exponent(self, start: Int, marks: StaticString) -> Int:
        """The end of an exponent (a mark, an optional sign and digits) at `start`, or
        `start` if there is none."""
        if not _in(self.byte(start), marks):
            return start
        var digits = start + (2 if _in(self.byte(start + 1), "+-") else 1)
        var end = digits
        while is_digit(self.byte(end)):
            end += 1
        return end if end > digits else start

    def scan_number(mut self, start: Int) raises -> Int:
        var after_dot = False
        if case [*_, last] = self.tokens:
            after_dot = last.is_op(".")
        var end = start
        if after_dot:
            while is_digit(self.byte(end)):
                end += 1
            if is_word_char(self.byte(end)):
                raise self.error(start, "a tuple field is a decimal index, e.g. p.0")
        elif self.byte(start) == ord("0") and _in(self.byte(start + 1), "xX"):
            end = self.after_digits(start + 2, hex=True)
            if end == start + 2:
                raise self.error(start, "hexadecimal literal needs digits after 0x")
            var dotted = self.byte(end) == ord(".")
            if dotted:
                end = self.after_digits(end + 1, hex=True)
            var with_exponent = self.after_exponent(end, "pP")
            if dotted and with_exponent == end:
                var text = self.text[byte=start:end]
                raise self.error(
                    start, t"hexadecimal float {text} needs a binary exponent, e.g. {text}p0"
                )
            end = with_exponent
        else:
            end = self.after_digits(start, hex=False)
            if self.byte(end) == ord("."):
                var fraction = self.after_digits(end + 1, hex=False)
                end = fraction if fraction > end + 1 else end
            end = self.after_exponent(end, "eE")
        if not after_dot and is_word_char(self.byte(end)):
            var stop = end
            while is_word_char(self.byte(stop)) or self.byte(stop) == ord("."):
                stop += 1
            var text = self.text[byte=start:stop]
            raise self.error(start, t"invalid numeric literal '{text}'")
        self.emit(.NUMBER, start=start, end=end)
        return end

    def scan_string(mut self, start: Int) raises -> Int:
        var value: List[UInt8] = []
        var i = start + 1
        while True:
            var c = self.byte(i)
            if i >= self.line.end or (c == ord("\\") and i + 1 >= self.line.end):
                raise self.error(start, "unterminated string")
            if c == ord('"'):
                break
            if c == ord("\\"):
                i = self.scan_escape(i, value)
            else:
                value.append(UInt8(c))
                i += 1
        self.emit_text(.STRING, String(unsafe_from_utf8=value), start=start, end=i + 1)
        return i + 1

    def scan_escape(mut self, i: Int, mut value: List[UInt8]) raises -> Int:
        """Appends what the escape at `i` stands for; returns the index after it."""
        var e = self.byte(i + 1)
        var simple = _ESCAPED.find(chr(e))
        if simple >= 0:
            value.append(_ESCAPES.as_bytes()[simple])
            return i + 2
        if e == ord("x"):
            if not (is_digit(self.byte(i + 2), hex=True) and is_digit(self.byte(i + 3), hex=True)):
                raise self.error(i, "\\x needs two hex digits")
            value.extend(chr(atol(self.text[byte = i + 2 : i + 4], 16)).as_bytes())
            return i + 4
        if e == ord("u"):
            return self.scan_unicode_escape(i, value)
        raise self.error(i, t"unknown escape \\{self.char_at(i + 1)}")

    def scan_unicode_escape(mut self, i: Int, mut value: List[UInt8]) raises -> Int:
        """`\\u` and four hex digits, or one to six in braces."""
        var braced = self.byte(i + 2) == ord("{")
        var first = i + 3 if braced else i + 2
        var end = first
        while is_digit(self.byte(end), hex=True) and end - first < (7 if braced else 4):
            end += 1
        var count = end - first
        var well_formed = (1 <= count <= 6 and self.byte(end) == ord("}")) if braced else count == 4
        if not well_formed:
            raise self.error(i, "\\u needs {hex} or four hex digits")
        var code = atol(self.text[byte=first:end], 16)
        if Codepoint.from_u32(UInt32(code)) is None:
            var digits = hex(code, prefix="")
            raise self.error(i, t"\\u{digits} is not a Unicode scalar value")
        value.extend(chr(code).as_bytes())
        return end + 1 if braced else end
