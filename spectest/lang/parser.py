"""Recursive-descent parser: ``parse(source, path) -> ast.SpecFile``.

Follows the grammar of docs/language.md. ``let`` and ``if`` may also start
any operand (``a implies let y = e in b``) and then extend as far right as
possible. Inside a ``let`` value, ``in`` ends the value unless bracketed.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any, TypeVar

from spectest import ast
from spectest.ast import Span
from spectest.lang.errors import SpecSyntaxError
from spectest.lang.lexer import (
    DEDENT,
    EOF,
    INDENT,
    NAME,
    NEWLINE,
    NUMBER,
    OP,
    PERF,
    STRING,
    Token,
    tokenize,
)

RESERVED = frozenset(
    {"let", "in", "if", "then", "else", "implies", "or", "and", "not", "true", "false", "none"}
)
COMPREHENSIONS = ("all", "exists", "count", "sum", "max", "map", "filter")
GENERIC_FNS = ("wrap", "fits", "round", "ulp", "qe")
EXPR_CLAUSES = ("requires", "ensures", "relates", "invariant", "aggregate")
COMPARISONS = ("==", "!=", "<", "<=", ">", ">=", "in")
DECL_KEYWORDS = ("use", "error", "enum", "record", "type", "model", "interface", "fn")

N = TypeVar("N", bound=ast.Node)


def _join(a: Span, b: Span) -> Span:
    return Span(a.line, a.col, b.end_line, b.end_col)


class Parser:
    def __init__(self, source: str, path: str = "<string>") -> None:
        self.source = source
        self.path = path
        self.tokens = tokenize(source, path)
        self.pos = 0
        self.no_in = False

    # -- token helpers -----------------------------------------------------

    @property
    def tok(self) -> Token:
        return self.tokens[self.pos]

    def peek(self, k: int = 1) -> Token:
        return self.tokens[min(self.pos + k, len(self.tokens) - 1)]

    def advance(self) -> Token:
        t = self.tokens[self.pos]
        if t.kind != EOF:
            self.pos += 1
        return t

    @property
    def last(self) -> Token:
        """The last consumed token that is not layout (NEWLINE, INDENT, DEDENT)."""
        i = self.pos - 1
        while i > 0 and self.tokens[i].kind in (NEWLINE, INDENT, DEDENT):
            i -= 1
        return self.tokens[max(i, 0)]

    def at(self, kind: str, value: Any = None) -> bool:
        return self.tok.is_(kind, value)

    def at_kw(self, *words: str) -> bool:
        return self.tok.kind == NAME and self.tok.value in words

    def at_op(self, *ops: str) -> bool:
        return self.tok.kind == OP and self.tok.value in ops

    def accept_op(self, op: str) -> bool:
        if self.at_op(op):
            self.advance()
            return True
        return False

    def describe(self, t: Token) -> str:
        if t.kind == NEWLINE:
            return "end of line"
        if t.kind == INDENT:
            return "an indented block"
        if t.kind == DEDENT:
            return "end of block"
        if t.kind == EOF:
            return "end of file"
        return f"'{t.text}'"

    def error(self, message: str, span: Span | None = None) -> SpecSyntaxError:
        if span is None:
            span = self.tok.span
        return SpecSyntaxError.at(self.path, self.source, span, message)

    def unexpected(self, wanted: str) -> SpecSyntaxError:
        return self.error(f"expected {wanted}, found {self.describe(self.tok)}")

    def expect_op(self, op: str, wanted: str | None = None) -> Token:
        if not self.at_op(op):
            raise self.unexpected(wanted or f"'{op}'")
        return self.advance()

    def expect_kw(self, word: str) -> Token:
        if not self.at_kw(word):
            raise self.unexpected(f"'{word}'")
        return self.advance()

    def expect_name(self, what: str = "a name") -> Token:
        if self.tok.kind != NAME:
            raise self.unexpected(what)
        if self.tok.value in RESERVED:
            raise self.error(f"'{self.tok.value}' is a reserved word and cannot be {what}")
        return self.advance()

    def expect_newline(self) -> None:
        if not self.at(NEWLINE):
            raise self.unexpected("end of line")
        self.advance()

    def expect_gt(self) -> Token:
        """Consume '>' in type syntax, splitting a '>=' token if needed."""
        t = self.tok
        if t.is_(OP, ">="):
            s = t.span
            gt = Token(OP, ">", ">", Span(s.line, s.col, s.line, s.col + 1))
            eq = Token(OP, "=", "=", Span(s.line, s.col + 1, s.end_line, s.end_col))
            self.tokens[self.pos : self.pos + 1] = [gt, eq]
        return self.expect_op(">")

    def finish(self, node: N, start: Token) -> N:
        node.span = _join(start.span, self.last.span)
        return node

    def text_between(self, start: int, stop: int) -> str:
        """Source text of tokens[start:stop], whitespace-normalized, comments dropped."""
        parts: list[str] = []
        prev: Token | None = None
        for t in self.tokens[start:stop]:
            if t.kind in (NEWLINE, INDENT, DEDENT, EOF):
                continue
            if prev is not None and (
                prev.span.end_line != t.span.line or prev.span.end_col != t.span.col
            ):
                parts.append(" ")
            parts.append(t.text)
            prev = t
        return "".join(parts)

    def bracketed(self, fn: Callable[[], N]) -> N:
        saved = self.no_in
        self.no_in = False
        try:
            return fn()
        finally:
            self.no_in = saved

    # -- file and declarations -------------------------------------------

    def parse_file(self) -> ast.SpecFile:
        start = self.tok
        if not self.at_kw("spec"):
            raise self.unexpected("'spec <name>' at the start of the file")
        self.advance()
        name = self.expect_name("the spec name").value
        self.expect_newline()
        decls: list[Any] = []
        while not self.at(EOF):
            decls.append(self.parse_decl())
        file = ast.SpecFile(name, decls, path=self.path, source=self.source)
        file.span = _join(start.span, self.last.span)
        return file

    def parse_decl(self) -> Any:
        t = self.tok
        if t.kind == INDENT:
            raise self.error("unexpected indentation")
        if t.kind != NAME or t.value not in DECL_KEYWORDS:
            if t.kind == NAME and t.value in ast.CLAUSE_KINDS + ("partition", "observe"):
                raise self.error(
                    f"'{t.value}' must be indented under a declaration (fn, model or interface)"
                )
            raise self.unexpected(
                "a declaration (fn, model, interface, error, enum, record, type or use)"
            )
        parsers: dict[str, Callable[[], Any]] = {
            "use": self.parse_use,
            "error": self.parse_error_decl,
            "enum": self.parse_enum,
            "record": self.parse_record,
            "type": self.parse_alias,
            "model": self.parse_model,
            "interface": self.parse_interface,
            "fn": self.parse_fn,
        }
        return parsers[t.value]()

    def parse_use(self) -> ast.UseDecl:
        start = self.advance()
        if not self.at(STRING):
            raise self.unexpected('a file name in quotes, e.g. use "other.spec"')
        path = self.advance().value
        node = self.finish(ast.UseDecl(path), start)
        self.expect_newline()
        return node

    def parse_error_decl(self) -> ast.ErrorDecl:
        start = self.advance()
        name = self.expect_name("an error name").value
        node = self.finish(ast.ErrorDecl(name), start)
        self.expect_newline()
        return node

    def parse_enum(self) -> ast.EnumDecl:
        start = self.advance()
        name = self.expect_name("an enum name").value
        self.expect_op("{")

        def members() -> list[str]:
            out = [self.expect_name("an enum member").value]
            while self.accept_op(","):
                out.append(self.expect_name("an enum member").value)
            self.expect_op("}", "',' or '}'")
            return out

        node = self.finish(ast.EnumDecl(name, self.bracketed(members)), start)
        self.expect_newline()
        return node

    def parse_record(self) -> ast.RecordDecl:
        start = self.advance()
        name = self.expect_name("a record name").value
        self.expect_op("{")

        def fields() -> list[ast.Param]:
            out = [self.parse_param()]
            while self.accept_op(","):
                out.append(self.parse_param())
            self.expect_op("}", "',' or '}'")
            return out

        node = self.finish(ast.RecordDecl(name, self.bracketed(fields)), start)
        self.expect_newline()
        return node

    def parse_alias(self) -> ast.AliasDecl:
        start = self.advance()
        name = self.expect_name("a type name").value
        self.expect_op("=")
        texpr = self.parse_type_expr()
        node = self.finish(ast.AliasDecl(name, texpr), start)
        self.expect_newline()
        return node

    def block(self, item: Callable[[], None], what: str) -> None:
        """An optional indented block after a header's NEWLINE."""
        if not self.at(INDENT):
            return
        self.advance()
        while not self.at(DEDENT):
            if self.at(EOF):
                raise self.unexpected(what)
            item()
        self.advance()

    def parse_model(self) -> ast.ModelDecl:
        start = self.advance()
        name = self.expect_name("a model name").value
        tparams = self.parse_tparams()
        self.expect_newline()
        node = ast.ModelDecl(name, tparams, [], [])

        def item() -> None:
            if self.at_kw("observe"):
                node.observers.append(self.parse_observe())
            elif self.at_kw(*ast.CLAUSE_KINDS):
                node.clauses.append(self.parse_clause())
            else:
                raise self.unexpected("'observe' or a clause such as 'invariant'")

        self.block(item, "an observer or invariant")
        return self.finish(node, start)

    def parse_interface(self) -> ast.InterfaceDecl:
        start = self.advance()
        name = self.expect_name("an interface name").value
        tparams = self.parse_tparams()
        self.expect_newline()
        node = ast.InterfaceDecl(name, tparams, [], [], [], [])

        def item() -> None:
            if self.at_kw("observe"):
                node.observers.append(self.parse_observe())
            elif self.at_kw("new"):
                node.ctors.append(self.parse_ctor())
            elif self.at_kw("method"):
                node.methods.append(self.parse_method())
            elif self.at_kw(*ast.CLAUSE_KINDS):
                node.clauses.append(self.parse_clause())
            else:
                raise self.unexpected("'observe', 'new', 'method' or a clause such as 'invariant'")

        self.block(item, "an interface member")
        return self.finish(node, start)

    def parse_fn(self) -> ast.FnDecl:
        start = self.advance()
        name = self.expect_name("a function name").value
        tparams = self.parse_tparams()
        params = self.parse_params()
        returns = self.parse_type_expr() if self.accept_op("->") else None
        self.expect_newline()
        node = ast.FnDecl(name, params, returns, tparams=tparams)
        self.parse_body(node)
        return self.finish(node, start)

    def parse_ctor(self) -> ast.CtorDecl:
        start = self.advance()
        name = self.expect_name("a constructor name").value
        params = self.parse_params()
        self.expect_op("->", "'->' and the interface name")
        returns = self.parse_type_expr()
        self.expect_newline()
        node = ast.CtorDecl(name, params, returns)
        self.parse_body(node)
        return self.finish(node, start)

    def parse_method(self) -> ast.MethodDecl:
        start = self.advance()
        name = self.expect_name("a method name").value
        self.expect_op("(")

        def params() -> list[ast.Param]:
            if not self.at_kw("self"):
                raise self.unexpected("'self' as the first parameter of a method")
            self.advance()
            out: list[ast.Param] = []
            while self.accept_op(","):
                out.append(self.parse_param())
            self.expect_op(")", "',' or ')'")
            return out

        plist = self.bracketed(params)
        returns = self.parse_type_expr() if self.accept_op("->") else None
        self.expect_newline()
        node = ast.MethodDecl(name, plist, returns)
        self.parse_body(node)
        return self.finish(node, start)

    def parse_body(self, node: ast.Callable_) -> None:
        def item() -> None:
            if self.at_kw("partition") and self.peek().kind == NAME:
                node.partitions.append(self.parse_partition())
            elif self.at_kw(*ast.CLAUSE_KINDS):
                node.clauses.append(self.parse_clause())
            else:
                raise self.unexpected("a clause (requires, ensures, raises, ...) or 'partition'")

        self.block(item, "a clause")

    def parse_observe(self) -> ast.Observe:
        start = self.advance()
        name = self.expect_name("an observer name").value
        params = self.parse_params() if self.at_op("(") else []
        self.expect_op(":", "':' and the observed type")
        texpr = self.parse_type_expr()
        node = self.finish(ast.Observe(name, params, texpr), start)
        self.expect_newline()
        return node

    def parse_partition(self) -> ast.Partition:
        start = self.advance()
        param = self.expect_name("the partitioned parameter").value
        self.expect_newline()
        if not self.at(INDENT):
            raise self.unexpected("an indented list of classes ('name = expr')")
        node = ast.Partition(param, [])

        def item() -> None:
            cstart = self.tok
            cname = self.expect_name("a partition class name").value
            self.expect_op("=", "'=' and the class expression")
            expr = self.parse_expr()
            node.classes.append(self.finish(ast.PartitionClass(cname, expr), cstart))
            self.expect_newline()

        self.block(item, "a partition class")
        return self.finish(node, start)

    def parse_label(self) -> str | None:
        if self.tok.kind == NAME and self.tok.value not in RESERVED and self.peek().is_(OP, ":"):
            label = self.advance().value
            self.advance()
            return label
        return None

    def parse_clause(self) -> ast.Clause:
        start_pos = self.pos
        start = self.advance()
        kind = start.value
        clause = ast.Clause(kind)
        if kind in EXPR_CLAUSES:
            clause.label = self.parse_label()
            clause.expr = self.parse_expr()
        elif kind in ("raises", "may_raise"):
            clause.label = self.parse_label()
            clause.error = self.expect_name("an error name").value
            if kind == "raises" or self.at_kw("when"):
                if not self.at_kw("when"):
                    raise self.unexpected("'when' and the condition under which it raises")
                self.advance()
                clause.expr = self.parse_expr()
        elif kind == "modifies":
            clause.names.append(self.expect_name("a parameter name or self").value)
            while self.accept_op(","):
                clause.names.append(self.expect_name("a parameter name or self").value)
        elif kind in ("unspecified", "impl_defined"):
            clause.freedom = self.expect_name("the name of the freedom").value
        else:
            raw: list[str] = []
            while self.at(PERF):
                raw.append(self.advance().value)
            clause.text = " ".join(["perf", *raw])
        self.finish(clause, start)
        if kind != "perf":
            clause.text = self.text_between(start_pos, self.pos)
        self.expect_newline()
        return clause

    # -- types and parameters ----------------------------------------------

    def parse_tparams(self) -> list[ast.TypeParam]:
        if not self.at_op("<"):
            return []
        self.advance()
        out: list[ast.TypeParam] = []
        while True:
            start = self.tok
            name = self.expect_name("a type parameter").value
            bound = self.expect_name("a bound (Eq or Ord)").value if self.accept_op(":") else None
            out.append(self.finish(ast.TypeParam(name, bound), start))
            if not self.accept_op(","):
                break
        self.expect_gt()
        return out

    def parse_params(self) -> list[ast.Param]:
        self.expect_op("(", "'(' and the parameters")

        def params() -> list[ast.Param]:
            out: list[ast.Param] = []
            if not self.at_op(")"):
                out.append(self.parse_param())
                while self.accept_op(","):
                    out.append(self.parse_param())
            self.expect_op(")", "',' or ')'")
            return out

        return self.bracketed(params)

    def parse_param(self) -> ast.Param:
        start = self.tok
        name = self.expect_name("a parameter name").value
        self.expect_op(":", f"':' and the type of {name}")
        texpr = self.parse_type_expr()
        default = self.parse_expr() if self.accept_op("=") else None
        return self.finish(ast.Param(name, texpr, default), start)

    def parse_type_expr(self) -> ast.AnyTypeExpr:
        start = self.tok
        if self.at(STRING):
            values = [self.advance().value]
            while self.accept_op("|"):
                if not self.at(STRING):
                    raise self.unexpected("a string literal in the union")
                values.append(self.advance().value)
            return self.finish(ast.LiteralTypeExpr(values), start)
        if self.at_op("("):
            self.advance()

            def elems() -> list[Any]:
                out = [self.parse_type_expr()]
                while self.accept_op(","):
                    out.append(self.parse_type_expr())
                self.expect_op(")", "',' or ')'")
                return out

            items = self.bracketed(elems)
            if len(items) < 2:
                raise self.error("a tuple type has at least two elements", start.span)
            return self.finish(ast.TupleTypeExpr(items), start)
        name = self.expect_name("a type").value
        args: list[ast.AnyTypeExpr] = []
        if self.at_op("<"):
            self.advance()
            args.append(self.parse_type_expr())
            while self.accept_op(","):
                args.append(self.parse_type_expr())
            self.expect_gt()
        return self.finish(ast.TypeExpr(name, args), start)

    # -- expressions -------------------------------------------------------

    def parse_expr(self) -> ast.Expr:
        return self.parse_implies()

    def parse_implies(self) -> ast.Expr:
        start = self.tok
        left = self.parse_or()
        if self.at_kw("implies"):
            self.advance()
            right = self.parse_implies()
            return self.finish(ast.Binary("implies", left, right), start)
        return left

    def parse_or(self) -> ast.Expr:
        start = self.tok
        left = self.parse_and()
        while self.at_kw("or"):
            self.advance()
            left = self.finish(ast.Binary("or", left, self.parse_and()), start)
        return left

    def parse_and(self) -> ast.Expr:
        start = self.tok
        left = self.parse_not()
        while self.at_kw("and"):
            self.advance()
            left = self.finish(ast.Binary("and", left, self.parse_not()), start)
        return left

    def parse_not(self) -> ast.Expr:
        start = self.tok
        if self.at_kw("not"):
            self.advance()
            return self.finish(ast.Unary("not", self.parse_not()), start)
        return self.parse_cmp()

    def at_cmp(self) -> bool:
        if self.at_kw("in"):
            return not self.no_in
        return self.at_op(*COMPARISONS)

    def parse_cmp(self) -> ast.Expr:
        start = self.tok
        left = self.parse_union()
        if not self.at_cmp():
            return left
        op = self.advance().value
        right = self.parse_union()
        node = self.finish(ast.Binary(op, left, right), start)
        if self.at_cmp():
            raise self.error(f"comparisons do not chain: write 'a {op} b and b {self.tok.text} c'")
        return node

    def _left_assoc(self, ops: tuple[str, ...], operand: Callable[[], ast.Expr]) -> ast.Expr:
        start = self.tok
        left = operand()
        while self.at_op(*ops):
            op = self.advance().value
            left = self.finish(ast.Binary(op, left, operand()), start)
        return left

    def parse_union(self) -> ast.Expr:
        return self._left_assoc(("|",), self.parse_inter)

    def parse_inter(self) -> ast.Expr:
        return self._left_assoc(("&",), self.parse_sum)

    def parse_sum(self) -> ast.Expr:
        return self._left_assoc(("+", "-"), self.parse_term)

    def parse_term(self) -> ast.Expr:
        return self._left_assoc(("*", "/", "//", "%"), self.parse_unary)

    def parse_unary(self) -> ast.Expr:
        start = self.tok
        if self.at_op("-"):
            self.advance()
            return self.finish(ast.Unary("-", self.parse_unary()), start)
        if self.at_kw("let"):
            return self.parse_let()
        if self.at_kw("if"):
            return self.parse_if()
        return self.parse_post()

    def parse_let(self) -> ast.Let:
        start = self.advance()
        name = self.expect_name("the name bound by let").value
        self.expect_op("=", "'=' and the value bound by let")
        saved = self.no_in
        self.no_in = True
        try:
            value = self.parse_expr()
        finally:
            self.no_in = saved
        if not self.at_kw("in"):
            raise self.unexpected("'in' after the value bound by let")
        self.advance()
        body = self.parse_expr()
        return self.finish(ast.Let(name, value, body), start)

    def parse_if(self) -> ast.If:
        start = self.advance()
        cond = self.bracketed(self.parse_expr)
        if not self.at_kw("then"):
            raise self.unexpected("'then'")
        self.advance()
        then = self.bracketed(self.parse_expr)
        if not self.at_kw("else"):
            raise self.unexpected("'else' (every if has an else branch)")
        self.advance()
        else_ = self.parse_expr()
        return self.finish(ast.If(cond, then, else_), start)

    def parse_post(self) -> ast.Expr:
        start = self.tok
        node = self.parse_atom()
        while True:
            if self.at_op("("):
                node = self.parse_call(node, [], start)
            elif self.at_op("."):
                self.advance()
                if self.at(NUMBER):
                    t = self.advance()
                    if not isinstance(t.value, int) or not t.text.isdigit():
                        raise self.error("a tuple field is a decimal index, e.g. p.0", t.span)
                    node = self.finish(ast.TupleIndex(node, t.value), start)
                elif self.tok.kind == NAME:
                    node = self.finish(ast.Attribute(node, self.advance().value), start)
                else:
                    raise self.unexpected("a field name or tuple index after '.'")
            elif self.at_op("["):
                self.advance()

                def index() -> tuple[ast.Expr, ast.Expr | None]:
                    first = self.parse_expr()
                    stop = self.parse_expr() if self.accept_op(":") else None
                    self.expect_op("]", "']'" if stop is not None else "':' or ']'")
                    return first, stop

                first, stop = self.bracketed(index)
                if stop is None:
                    node = self.finish(ast.Index(node, first), start)
                else:
                    node = self.finish(ast.Slice(node, first, stop), start)
            else:
                return node

    def parse_call(
        self, func: ast.Expr, type_args: list[ast.AnyTypeExpr], start: Token
    ) -> ast.Call:
        self.expect_op("(")

        def args() -> tuple[list[ast.Expr], list[tuple[str, ast.Expr]]]:
            pos: list[ast.Expr] = []
            kws: list[tuple[str, ast.Expr]] = []
            if self.at_op(")"):
                self.advance()
                return pos, kws
            while True:
                if self.tok.kind == NAME and self.peek().is_(OP, "="):
                    key = self.expect_name("an argument name")
                    self.advance()
                    if any(k == key.value for k, _ in kws):
                        raise self.error(f"argument {key.value} is given twice", key.span)
                    kws.append((key.value, self.parse_expr()))
                else:
                    if kws:
                        raise self.error("positional arguments must come before named ones")
                    pos.append(self.parse_expr())
                if not self.accept_op(","):
                    break
            self.expect_op(")", "',' or ')'")
            return pos, kws

        pos, kws = self.bracketed(args)
        return self.finish(ast.Call(func, pos, kws, type_args), start)

    def parse_atom(self) -> ast.Expr:
        t = self.tok
        if t.kind == NUMBER:
            self.advance()
            return self.finish(ast.Num(t.value, t.text), t)
        if t.kind == STRING:
            self.advance()
            return self.finish(ast.Str(t.value), t)
        if t.kind == NAME:
            if t.value in ("true", "false"):
                self.advance()
                return self.finish(ast.BoolLit(t.value == "true"), t)
            if t.value == "none":
                self.advance()
                return self.finish(ast.NoneLit(), t)
            if (
                t.value in COMPREHENSIONS
                and self.peek().is_(OP, "(")
                and self.peek(2).kind == NAME
                and self.peek(3).is_(NAME, "in")
            ):
                return self.parse_comprehension()
            if t.value in RESERVED:
                raise self.unexpected("an expression")
            self.advance()
            name = self.finish(ast.Name(t.value), t)
            if t.value in GENERIC_FNS and self.at_op("<"):
                self.advance()
                targs = [self.parse_type_expr()]
                while self.accept_op(","):
                    targs.append(self.parse_type_expr())
                self.expect_gt()
                if not self.at_op("("):
                    raise self.unexpected(f"'(' and the arguments of {t.value}<...>")
                return self.parse_call(name, targs, t)
            return name
        if t.is_(OP, "["):
            self.advance()
            elems = self.bracketed(lambda: self.parse_elems("]"))
            return self.finish(ast.ListLit(elems), t)
        if t.is_(OP, "{"):
            self.advance()
            elems = self.bracketed(lambda: self.parse_elems("}"))
            return self.finish(ast.SetLit(elems), t)
        if t.is_(OP, "("):
            self.advance()
            elems = self.bracketed(lambda: self.parse_elems(")", empty=False))
            if len(elems) == 1:
                inner = elems[0]
                return inner
            return self.finish(ast.TupleLit(elems), t)
        raise self.unexpected("an expression")

    def parse_elems(self, close: str, empty: bool = True) -> list[ast.Expr]:
        out: list[ast.Expr] = []
        if self.at_op(close):
            if not empty:
                raise self.unexpected("an expression")
            self.advance()
            return out
        out.append(self.parse_expr())
        while self.accept_op(","):
            out.append(self.parse_expr())
        self.expect_op(close, f"',' or '{close}'")
        return out

    def parse_comprehension(self) -> ast.Comprehension:
        start = self.advance()
        kind = start.value
        self.expect_op("(")

        def inner() -> tuple[str, ast.Expr, ast.Expr]:
            var = self.expect_name("the comprehension variable").value
            self.expect_kw("in")
            iterable = self.parse_expr()
            self.expect_op(":", f"':' and the body of {kind}(...)")
            body = self.parse_expr()
            self.expect_op(")", "')'")
            return var, iterable, body

        var, iterable, body = self.bracketed(inner)
        return self.finish(ast.Comprehension(kind, var, iterable, body), start)


def parse(source: str, path: str = "<string>") -> ast.SpecFile:
    """Parse a spec file; raises SpecSyntaxError at the first error."""
    return Parser(source, path).parse_file()


def parse_expr(source: str, path: str = "<expr>") -> ast.Expr:
    """Parse a single expression (used by tests and tools)."""
    p = Parser(source, path)
    e = p.parse_expr()
    if p.at(NEWLINE):
        p.advance()
    if not p.at(EOF):
        raise p.unexpected("end of expression")
    return e


def parse_type(source: str, path: str = "<type>") -> ast.AnyTypeExpr:
    """Parse type syntax such as "list<(i64, string)>"."""
    p = Parser(source, path)
    t = p.parse_type_expr()
    if p.at(NEWLINE):
        p.advance()
    if not p.at(EOF):
        raise p.unexpected("end of type")
    return t


__all__ = [
    "COMPREHENSIONS",
    "GENERIC_FNS",
    "RESERVED",
    "Parser",
    "parse",
    "parse_expr",
    "parse_type",
]
