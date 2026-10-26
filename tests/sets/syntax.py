"""A small reader for the expression and declaration subset the set tests need.

It follows the precedence of docs/language.md and builds spectest.ast nodes
with spans, so the tests do not depend on the full front end.
"""

from __future__ import annotations

import re
from fractions import Fraction
from pathlib import Path

from spectest import ast

KEYWORDS = {"and", "or", "not", "implies", "if", "then", "else", "true", "false", "none", "in"}
GENERIC = {"wrap", "fits", "round"}
TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<num>0[xX][0-9a-fA-F]*(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?
      | \d+(?:\.\d*)?(?:[eE][+-]?\d+)?)
  | (?P<str>"(?:[^"\\]|\\.)*")
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op><=|>=|==|!=|//|[-+*/%<>|&(){}\[\],.:=])
    """,
    re.VERBOSE,
)


def number(text: str) -> int | Fraction:
    t = text.lower()
    if t.startswith("0x"):
        body, _, exp = t[2:].partition("p")
        whole, _, frac = body.partition(".")
        mantissa = int(whole + frac or "0", 16)
        value = Fraction(mantissa, 16 ** len(frac)) * Fraction(2) ** int(exp or "0")
        return int(value) if value.denominator == 1 and "p" not in t and "." not in t else value
    if "." in t or "e" in t:
        return Fraction(t)
    return int(t)


class Reader:
    def __init__(self, text: str, line: int = 1, col: int = 1) -> None:
        self.tokens: list[tuple[str, str, int]] = []
        pos = 0
        while pos < len(text):
            m = TOKEN.match(text, pos)
            if m is None:
                raise SyntaxError(f"bad character {text[pos]!r} in {text!r}")
            kind = m.lastgroup
            if kind != "ws":
                value = m.group()
                if kind == "name" and value in KEYWORDS:
                    kind = "kw"
                self.tokens.append((kind, value, pos))
            pos = m.end()
        self.tokens.append(("eof", "", len(text)))
        self.i = 0
        self.line, self.col, self.length = line, col, len(text)

    def span(self, start: int, end: int) -> ast.Span:
        return ast.Span(self.line, self.col + start, self.line, self.col + end)

    def peek(self, offset: int = 0) -> tuple[str, str, int]:
        return self.tokens[self.i + offset]

    def next(self) -> tuple[str, str, int]:
        tok = self.tokens[self.i]
        self.i += 1
        return tok

    def at(self, value: str) -> bool:
        kind, v, _ = self.peek()
        return v == value and kind in ("op", "kw")

    def expect(self, value: str) -> int:
        _, v, pos = self.next()
        if v != value:
            raise SyntaxError(f"expected {value!r}, got {v!r}")
        return pos

    def end(self) -> int:
        _, value, pos = self.tokens[self.i - 1]
        return pos + len(value)

    def done(self) -> ast.Expr:
        e = self.expr()
        if self.peek()[0] != "eof":
            raise SyntaxError(f"unexpected {self.peek()[1]!r}")
        return e

    def finish(self, node: ast.Expr, start: int) -> ast.Expr:
        node.span = self.span(start, self.end())
        return node

    def expr(self) -> ast.Expr:
        start = self.peek()[2]
        if self.at("if"):
            self.next()
            cond = self.expr()
            self.expect("then")
            then = self.expr()
            self.expect("else")
            return self.finish(ast.If(cond, then, self.expr()), start)
        return self.implies()

    def implies(self) -> ast.Expr:
        start = self.peek()[2]
        left = self.or_()
        if self.at("implies"):
            self.next()
            return self.finish(ast.Binary("implies", left, self.implies()), start)
        return left

    def binary(self, ops: tuple[str, ...], operand) -> ast.Expr:
        start = self.peek()[2]
        left = operand()
        while self.peek()[1] in ops and self.peek()[0] in ("op", "kw"):
            op = self.next()[1]
            left = self.finish(ast.Binary(op, left, operand()), start)
        return left

    def or_(self) -> ast.Expr:
        return self.binary(("or",), self.and_)

    def and_(self) -> ast.Expr:
        return self.binary(("and",), self.not_)

    def not_(self) -> ast.Expr:
        start = self.peek()[2]
        if self.at("not"):
            self.next()
            return self.finish(ast.Unary("not", self.not_()), start)
        return self.cmp()

    def cmp(self) -> ast.Expr:
        start = self.peek()[2]
        left = self.union()
        if self.peek()[1] in ("==", "!=", "<", "<=", ">", ">=") or self.at("in"):
            op = self.next()[1]
            return self.finish(ast.Binary(op, left, self.union()), start)
        return left

    def union(self) -> ast.Expr:
        return self.binary(("|",), self.inter)

    def inter(self) -> ast.Expr:
        return self.binary(("&",), self.sum)

    def sum(self) -> ast.Expr:
        return self.binary(("+", "-"), self.term)

    def term(self) -> ast.Expr:
        return self.binary(("*", "/", "//", "%"), self.unary)

    def unary(self) -> ast.Expr:
        start = self.peek()[2]
        if self.at("-"):
            self.next()
            return self.finish(ast.Unary("-", self.unary()), start)
        return self.post()

    def post(self) -> ast.Expr:
        start = self.peek()[2]
        e = self.atom()
        while True:
            if self.at("("):
                self.next()
                args = []
                while not self.at(")"):
                    args.append(self.expr())
                    if not self.at(")"):
                        self.expect(",")
                self.expect(")")
                e = self.finish(ast.Call(e, args), start)
            elif self.at("."):
                self.next()
                e = self.finish(ast.Attribute(e, self.next()[1]), start)
            else:
                return e

    def atom(self) -> ast.Expr:
        kind, value, start = self.next()
        if kind == "num":
            return self.finish(ast.Num(number(value), value), start)
        if kind == "str":
            return self.finish(ast.Str(value[1:-1]), start)
        if value in ("true", "false"):
            return self.finish(ast.BoolLit(value == "true"), start)
        if value == "none":
            return self.finish(ast.NoneLit(), start)
        if kind == "name":
            name = self.finish(ast.Name(value), start)
            if value in GENERIC and self.at("<"):
                self.next()
                targ = ast.TypeExpr(self.next()[1])
                self.expect(">")
                self.expect("(")
                args = [self.expr()]
                self.expect(")")
                return self.finish(ast.Call(name, args, type_args=[targ]), start)
            return name
        if value in ("(", "{", "["):
            close = {"(": ")", "{": "}", "[": "]"}[value]
            elems = []
            while not self.at(close):
                elems.append(self.expr())
                if not self.at(close):
                    self.expect(",")
            self.expect(close)
            if value == "(":
                return elems[0]
            node = ast.SetLit(elems) if value == "{" else ast.ListLit(elems)
            return self.finish(node, start)
        raise SyntaxError(f"unexpected {value!r}")


def expr(text: str, line: int = 1, col: int = 1) -> ast.Expr:
    """Parse one expression."""
    return Reader(text, line, col).done()


def type_expr(text: str) -> ast.TypeExpr:
    text = text.strip()
    m = re.fullmatch(r"(\w+)(?:<(.*)>)?", text)
    if m is None:
        return ast.TypeExpr(text)
    args = [type_expr(a) for a in m.group(2).split(",")] if m.group(2) else []
    return ast.TypeExpr(m.group(1), args)


def split_params(text: str) -> list[ast.Param]:
    params, depth, current = [], 0, ""
    for ch in text + ",":
        if ch == "," and depth == 0:
            if current.strip():
                name, _, rest = current.partition(":")
                tname, _, _default = rest.partition("=")
                params.append(ast.Param(name.strip(), type_expr(tname)))
            current = ""
            continue
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth -= 1
        current += ch
    return params


FN = re.compile(r"fn (\w+)(?:<([^>]*)>)?\((.*?)\)(?:\s*->\s*(.+))?$")


def read_fns(source: str) -> ast.SpecFile:
    """Top-level fns of a spec file with their partitions and requires clauses."""
    lines = source.splitlines()
    decls: list[ast.FnDecl] = []
    fn: ast.FnDecl | None = None
    part: ast.Partition | None = None
    for number_, raw in enumerate(lines, start=1):
        text = raw.split("#", 1)[0].rstrip()
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip())
        body = text.strip()
        if indent == 0:
            fn, part = None, None
            if m := FN.match(body):
                tparams = [
                    ast.TypeParam(t.split(":")[0].strip())
                    for t in (m.group(2) or "").split(",")
                    if t
                ]
                fn = ast.FnDecl(m.group(1), split_params(m.group(3)), None, tparams=tparams)
                fn.span = ast.Span(number_, 1, number_, len(raw) + 1)
                decls.append(fn)
            continue
        if fn is None:
            continue
        if indent == 2:
            part = None
            if body.startswith("partition "):
                part = ast.Partition(body.split()[1], [])
                part.span = ast.Span(number_, 3, number_, len(raw) + 1)
                fn.partitions.append(part)
            elif body.startswith("requires "):
                clause_text = body[len("requires ") :]
                label = None
                if m := re.match(r"(\w+):\s", clause_text):
                    label, clause_text = m.group(1), clause_text[m.end() :]
                col = raw.index(clause_text) + 1
                fn.clauses.append(
                    ast.Clause("requires", label, expr(clause_text, number_, col), text=body)
                )
            continue
        if part is not None and indent > 2:
            name, _, rhs = body.partition("=")
            col = raw.index(rhs.strip()) + 1
            cls = ast.PartitionClass(name.strip(), expr(rhs.strip(), number_, col))
            cls.span = ast.Span(number_, indent + 1, number_, len(raw) + 1)
            part.classes.append(cls)
    return ast.SpecFile("spec", decls, source=source)


def read_file(path: str | Path) -> ast.SpecFile:
    return read_fns(Path(path).read_text())
