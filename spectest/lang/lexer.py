"""Tokens and the layout rule.

Blocks are indentation-based. A logical line starts at the beginning of a
physical line outside brackets. A line whose first word is a block opener
(``fn``, ``new``, ``method``, ``model``, ``interface``, ``partition``,
followed by a name) opens a block when the next line is indented deeper:
the lexer emits INDENT, and DEDENT when the indentation returns. Following
lines indented deeper than any other line continue it. Newlines inside
``()``, ``[]`` and ``{}`` are ignored, as are blank and comment-only lines.
``perf`` takes the rest of its line raw.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from fractions import Fraction
from typing import Any

from spectest.ast import Span
from spectest.lang.errors import SpecSyntaxError

NAME = "NAME"
NUMBER = "NUMBER"
STRING = "STRING"
OP = "OP"
PERF = "PERF"
NEWLINE = "NEWLINE"
INDENT = "INDENT"
DEDENT = "DEDENT"
EOF = "EOF"

OPENERS = ("fn", "new", "method", "model", "interface", "partition")

OPERATORS = (
    "->", "==", "!=", "<=", ">=", "//",
    "<", ">", "=", "+", "-", "*", "/", "%", "|", "&",
    "(", ")", "[", "]", "{", "}", ",", ":", ".",
)  # fmt: skip

_CLOSERS = {")": "(", "]": "[", "}": "{"}
_OPENER_RE = re.compile(rf"(?:{'|'.join(OPENERS)})\s+[A-Za-z_]")
_PERF_RE = re.compile(r"perf(?:\s|$)")
_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_HEX_RE = re.compile(
    r"0[xX](?P<int>[0-9a-fA-F](?:_?[0-9a-fA-F])*)"
    r"(?:\.(?P<frac>[0-9a-fA-F](?:_?[0-9a-fA-F])*)?)?"
    r"(?:[pP](?P<exp>[+-]?[0-9]+))?"
)
_DEC_RE = re.compile(
    r"(?P<int>[0-9](?:_?[0-9])*)(?:\.(?P<frac>[0-9](?:_?[0-9])*))?(?P<exp>[eE][+-]?[0-9]+)?"
)
_DIGITS_RE = re.compile(r"[0-9]+")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"'}


@dataclass(frozen=True)
class Token:
    kind: str
    value: Any  # names and operators: str; numbers: int | Fraction; strings: decoded str
    text: str  # the source text of the token
    span: Span

    def is_(self, kind: str, value: Any = None) -> bool:
        return self.kind == kind and (value is None or self.value == value)

    def __repr__(self) -> str:
        if self.kind in (NEWLINE, INDENT, DEDENT, EOF):
            return self.kind
        return f"{self.kind}({self.text})"


@dataclass
class _Logical:
    indent: int
    opener: bool
    perf: bool
    last: Span


def parse_number(text: str) -> int | Fraction:
    """The exact value of a numeric literal: int for integers, Fraction otherwise."""
    m = _HEX_RE.fullmatch(text)
    if m:
        whole = m["int"].replace("_", "")
        frac = (m["frac"] or "").replace("_", "")
        if m["frac"] is None and m["exp"] is None and "." not in text:
            return int(whole, 16)
        value = Fraction(int(whole + frac, 16), 16 ** len(frac))
        exp = int(m["exp"] or 0)
        return value * (Fraction(2) ** exp)
    m = _DEC_RE.fullmatch(text)
    if m is None:
        raise ValueError(f"not a number: {text!r}")
    if m["frac"] is None and m["exp"] is None:
        return int(m["int"].replace("_", ""))
    return Fraction(text.replace("_", ""))


class _Lexer:
    def __init__(self, source: str, path: str) -> None:
        self.source = source
        self.path = path
        self.tokens: list[Token] = []
        self.brackets: list[Token] = []
        self.stack = [0]
        self.cur: _Logical | None = None

    def error(self, line: int, col: int, message: str, length: int = 1) -> SpecSyntaxError:
        return SpecSyntaxError.at(
            self.path, self.source, Span(line, col, line, col + length), message
        )

    def emit(self, kind: str, value: Any, text: str, span: Span) -> None:
        self.tokens.append(Token(kind, value, text, span))
        if kind not in (NEWLINE, INDENT, DEDENT, EOF) and self.cur is not None:
            self.cur.last = span

    def run(self) -> list[Token]:
        lines = self.source.split("\n")
        for ln, raw in enumerate(lines, 1):
            self.line(ln, raw.rstrip("\r"))
        last_line = len(lines)
        last_col = len(lines[-1].rstrip("\r")) + 1 if lines else 1
        if self.brackets:
            t = self.brackets[-1]
            raise SpecSyntaxError.at(self.path, self.source, t.span, f"'{t.value}' is never closed")
        end = Span(last_line, last_col, last_line, last_col)
        if self.cur is not None:
            self.emit(NEWLINE, "\n", "", self._after(self.cur.last))
        while len(self.stack) > 1:
            self.stack.pop()
            self.emit(DEDENT, "", "", end)
        self.emit(EOF, "", "", end)
        return self.tokens

    @staticmethod
    def _after(span: Span) -> Span:
        return Span(span.end_line, span.end_col, span.end_line, span.end_col)

    def line(self, ln: int, line: str) -> None:
        stripped = line.lstrip(" \t")
        lead = line[: len(line) - len(stripped)]
        if "\t" in lead and stripped:
            raise self.error(ln, lead.index("\t") + 1, "tab in indentation: indent with spaces")
        if self.brackets:
            self.scan(ln, line, len(lead))
            return
        if not stripped or stripped.startswith("#"):
            return
        indent = len(lead)
        cur = self.cur
        if cur is not None and not cur.opener and indent > cur.indent:
            if cur.perf:
                self.perf_text(ln, line, indent)
            else:
                self.scan(ln, line, indent)
            return
        here = Span(ln, indent + 1, ln, indent + 1)
        if cur is not None:
            self.emit(NEWLINE, "\n", "", self._after(cur.last))
        if cur is not None and cur.opener and indent > self.stack[-1]:
            self.stack.append(indent)
            self.emit(INDENT, indent, "", here)
        elif indent > self.stack[-1]:
            raise self.error(ln, indent + 1, "unexpected indentation")
        else:
            while indent < self.stack[-1]:
                self.stack.pop()
                self.emit(DEDENT, indent, "", here)
            if indent != self.stack[-1]:
                raise self.error(ln, indent + 1, "indentation does not match any enclosing block")
        perf = _PERF_RE.match(stripped) is not None
        self.cur = _Logical(indent, _OPENER_RE.match(stripped) is not None, perf, here)
        if perf:
            col = indent + 1
            self.emit(NAME, "perf", "perf", Span(ln, col, ln, col + 4))
            self.perf_text(ln, line, indent + 4)
        else:
            self.scan(ln, line, indent)

    def perf_text(self, ln: int, line: str, start: int) -> None:
        rest = line[start:]
        text = rest.strip()
        if not text:
            return
        col = start + (len(rest) - len(rest.lstrip())) + 1
        self.emit(PERF, text, text, Span(ln, col, ln, col + len(text)))

    def scan(self, ln: int, line: str, i: int) -> None:
        n = len(line)
        while i < n:
            c = line[i]
            col = i + 1
            if c in " \t":
                i += 1
                continue
            if c == "#":
                return
            if c == '"':
                i = self.string(ln, line, i)
                continue
            if c.isdigit():
                i = self.number(ln, line, i)
                continue
            m = _NAME_RE.match(line, i)
            if m:
                text = m.group()
                self.emit(NAME, text, text, Span(ln, col, ln, col + len(text)))
                i = m.end()
                continue
            for op in OPERATORS:
                if line.startswith(op, i):
                    break
            else:
                raise self.error(ln, col, f"unexpected character {c!r}")
            tok = Token(OP, op, op, Span(ln, col, ln, col + len(op)))
            if op in "([{":
                self.brackets.append(tok)
            elif op in _CLOSERS:
                if not self.brackets:
                    raise self.error(ln, col, f"unmatched '{op}'")
                opened = self.brackets.pop()
                if opened.value != _CLOSERS[op]:
                    raise self.error(
                        ln,
                        col,
                        f"'{op}' does not match '{opened.value}' at "
                        f"{opened.span.line}:{opened.span.col}",
                    )
            self.emit(OP, op, op, tok.span)
            i += len(op)

    def number(self, ln: int, line: str, i: int) -> int:
        col = i + 1
        prev = self.tokens[-1] if self.tokens else None
        if prev is not None and prev.is_(OP, "."):
            m = _DIGITS_RE.match(line, i)
            assert m is not None
            text = m.group()
            end = m.end()
            if end < len(line) and (line[end].isalnum() or line[end] == "_"):
                raise self.error(ln, col, "a tuple field is a decimal index, e.g. p.0", end - i + 1)
            self.emit(NUMBER, int(text), text, Span(ln, col, ln, col + len(text)))
            return end
        if line.startswith(("0x", "0X"), i):
            m = _HEX_RE.match(line, i)
            if m is None:
                raise self.error(ln, col, "hexadecimal literal needs digits after 0x", 2)
            text = m.group()
            if "." in text and m["exp"] is None:
                raise self.error(
                    ln,
                    col,
                    f"hexadecimal float {text} needs a binary exponent, e.g. {text}p0",
                    len(text),
                )
        else:
            m = _DEC_RE.match(line, i)
            assert m is not None
            text = m.group()
        end = m.end()
        if end < len(line) and (line[end].isalnum() or line[end] == "_"):
            stop = end
            while stop < len(line) and (line[stop].isalnum() or line[stop] in "_."):
                stop += 1
            raise self.error(ln, col, f"invalid numeric literal {line[i:stop]!r}", stop - i)
        self.emit(NUMBER, parse_number(text), text, Span(ln, col, ln, col + len(text)))
        return end

    def string(self, ln: int, line: str, i: int) -> int:
        start = i
        i += 1
        out: list[str] = []
        n = len(line)
        while True:
            if i >= n:
                raise self.error(ln, start + 1, "unterminated string", n - start)
            c = line[i]
            if c == '"':
                i += 1
                break
            if c != "\\":
                out.append(c)
                i += 1
                continue
            if i + 1 >= n:
                raise self.error(ln, start + 1, "unterminated string", n - start)
            e = line[i + 1]
            if e in _ESCAPES:
                out.append(_ESCAPES[e])
                i += 2
            elif e == "x":
                digits = line[i + 2 : i + 4]
                if not re.fullmatch(r"[0-9a-fA-F]{2}", digits):
                    raise self.error(ln, i + 1, "\\x needs two hex digits", 2)
                out.append(chr(int(digits, 16)))
                i += 4
            elif e == "u":
                m = re.compile(r"\{([0-9a-fA-F]{1,6})\}|([0-9a-fA-F]{4})").match(line, i + 2)
                if m is None:
                    raise self.error(ln, i + 1, "\\u needs {hex} or four hex digits", 2)
                code = int(m.group(1) or m.group(2), 16)
                if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
                    raise self.error(ln, i + 1, f"\\u{code:x} is not a Unicode scalar value", 2)
                out.append(chr(code))
                i = m.end()
            else:
                raise self.error(ln, i + 1, f"unknown escape \\{e}", 2)
        text = line[start:i]
        self.emit(STRING, "".join(out), text, Span(ln, start + 1, ln, i + 1))
        return i


def tokenize(source: str, path: str = "<string>") -> list[Token]:
    """Tokens of a spec source, with NEWLINE, INDENT and DEDENT from the layout rule."""
    return _Lexer(source, path).run()


__all__ = [
    "DEDENT", "EOF", "INDENT", "NAME", "NEWLINE", "NUMBER", "OP", "OPENERS", "OPERATORS",
    "PERF", "STRING", "Token", "parse_number", "tokenize",
]  # fmt: skip
