"""Recursive-descent parser for spec files and user preludes.

Follows the grammar of docs/language.md and docs/v2/syntax.md. `let` and `if` may also
start any operand (`a implies let y = e in b`) and then extend as far right as
possible. Inside a `let` value, `in` ends the value unless it is bracketed.

The tree is built flat into `Ast` (see `syntax/ast.mojo` for each node's children).
Every node's span runs from its first token to the last token consumed, so a clause
covers its continuation lines.
"""

import syntax.ast as sx
from syntax.ast import Ast, Node, SourceFile, Span as SrcSpan, op_named
from syntax.lexer import (
    Token, tokenize, syntax_error,
    T_NAME, T_NUMBER, T_STRING, T_OP, T_PERF, T_NEWLINE, T_INDENT, T_DEDENT, T_EOF,
)

comptime NIL = 0
"""The index of the EMPTY node."""


def _is_reserved(text: String) -> Bool:
    return text in [
        "let", "in", "if", "then", "else", "implies", "or", "and", "not", "true", "false", "none"
    ]


def _comprehension_op(text: String) -> UInt8:
    return op_named(text, first=sx.ALL, last=sx.FILTER)


def _clause_op(text: String) -> UInt8:
    return op_named(text, first=sx.REQUIRES, last=sx.PERF)


def _cmp_op(text: String) -> UInt8:
    return op_named(text, first=sx.EQ, last=sx.GE)


# Binary operator levels, loosest first: | & shifts sums products. Level 5 is unary.
comptime _LEVELS = 5


def _level_op(level: Int, text: String) -> UInt8:
    match level:
        case 0:
            return op_named(text, first=sx.BITOR, last=sx.BITOR)
        case 1:
            return op_named(text, first=sx.BITAND, last=sx.BITAND)
        case 2:
            return op_named(text, first=sx.SHL, last=sx.SHR)
        case 3:
            return op_named(text, first=sx.ADD, last=sx.SUB)
        case _:
            return op_named(text, first=sx.MUL, last=sx.MOD)


struct Parser:
    var tokens: List[Token]
    var pos: Int
    var no_in: Bool
    var last_end: Int
    var ast: Ast

    def __init__(out self, var tokens: List[Token], var source: String, var path: String):
        self.tokens = tokens^
        self.pos = 0
        self.no_in = False
        self.last_end = 0
        self.ast = Ast(source^, path^)

    def into_ast(deinit self) -> Ast:
        return self.ast^

    def current(self) -> ref [self.tokens[0]] Token:
        return self.tokens[self.pos]

    def kind(self) -> UInt8:
        return self.current().kind

    def peek_index(self, k: Int) -> Int:
        return min(self.pos + k, len(self.tokens) - 1)

    def skip(mut self):
        ref t = self.current()
        if t.kind == T_EOF:
            return
        if not T_NEWLINE <= t.kind <= T_DEDENT:
            self.last_end = t.end
        self.pos += 1

    def advance(mut self) -> Token:
        var t = self.current().copy()
        self.skip()
        return t^

    def is_kw(self, word: StaticString) -> Bool:
        return self.kind() == T_NAME and self.current().text == word

    def is_op(self, op: StaticString) -> Bool:
        return self.kind() == T_OP and self.current().text == op

    def peek_is_op(self, k: Int, op: StaticString) -> Bool:
        ref t = self.tokens[self.peek_index(k)]
        return t.kind == T_OP and t.text == op

    def peek_is_kw(self, k: Int, word: StaticString) -> Bool:
        ref t = self.tokens[self.peek_index(k)]
        return t.kind == T_NAME and t.text == word

    def peek_kind(self, k: Int) -> UInt8:
        return self.tokens[self.peek_index(k)].kind

    def accept_op(mut self, op: StaticString) -> Bool:
        if self.is_op(op):
            self.skip()
            return True
        return False

    def is_clause_kw(self) -> Bool:
        return self.kind() == T_NAME and _clause_op(self.current().text) != sx.NO_OP

    def describe(self, t: Token) -> String:
        if t.kind == T_NEWLINE:
            return "end of line"
        if t.kind == T_INDENT:
            return "an indented block"
        if t.kind == T_DEDENT:
            return "end of block"
        if t.kind == T_EOF:
            return "end of file"
        return String("'", self.ast.source[byte = t.start : t.end], "'")

    def error_at(self, span: SrcSpan, message: Some[Writable]) -> Error:
        return syntax_error(self.ast.path, span, String(message))

    def error(self, message: Some[Writable]) -> Error:
        return self.error_at(self.current().span(), message)

    def unexpected(self, wanted: Some[Writable]) -> Error:
        return self.error(t"expected {wanted}, found {self.describe(self.current())}")

    def expect_op(mut self, op: StaticString, wanted: String = String()) raises -> Token:
        if not self.is_op(op):
            raise self.unexpected(wanted if wanted.byte_length() > 0 else String("'", op, "'"))
        return self.advance()

    def expect_kw(mut self, word: StaticString) raises:
        if not self.is_kw(word):
            raise self.unexpected(String("'", word, "'"))
        self.skip()

    def expect_name(mut self, what: String = "a name") raises -> Token:
        if self.kind() != T_NAME:
            raise self.unexpected(what)
        if _is_reserved(self.current().text):
            raise self.error(t"'{self.current().text}' is a reserved word and cannot be {what}")
        return self.advance()

    def expect_newline(mut self) raises:
        if self.kind() != T_NEWLINE:
            raise self.unexpected("end of line")
        self.skip()

    def expect_gt(mut self) raises:
        """Consume '>' in type syntax, splitting a '>=' or '>>' token if needed."""
        if self.is_op(">=") or self.is_op(">>"):
            ref t = self.tokens[self.pos]
            var rest = String(t.text[byte=1:])
            t.text = rest^
            t.start += 1
            t.col += 1
            self.last_end = t.start
        else:
            _ = self.expect_op(">")

    def mark(self) -> SrcSpan:
        ref t = self.current()
        return SrcSpan(t.start, t.start, t.line, t.col)

    def close(self, m: SrcSpan) -> SrcSpan:
        return SrcSpan(m.start, max(self.last_end, m.start), m.line, m.col)

    def empty_node(mut self, kind: UInt8) -> Int:
        """A childless node of `kind`, zero-width at the end of the last token."""
        var at = self.mark()
        at.start = self.last_end
        at.end = self.last_end
        return self.ast.add(kind, at)

    def separated[item: def(mut Self) thin raises -> Int](
        mut self, separator: StaticString = ","
    ) raises -> List[Int]:
        """At least one `item`, with `separator` between them."""
        var items = List[Int]()
        items.append(item(self))
        while self.accept_op(separator):
            items.append(item(self))
        return items^

    def bracketed[item: def(mut Self) thin raises -> Int](
        mut self, close: StaticString, *, allow_empty: Bool = False
    ) raises -> List[Int]:
        """Comma-separated `item`s up to `close`, within which `in` is allowed again."""
        var saved = self.no_in
        self.no_in = False
        var items = List[Int]()
        if not (allow_empty and self.is_op(close)):
            items = self.separated[item]()
        _ = self.expect_op(close, String("',' or '", close, "'"))
        self.no_in = saved
        return items^

    def parse_file(mut self) raises -> Int:
        var m = self.mark()
        if not self.is_kw("spec"):
            raise self.unexpected("'spec <name>' at the start of the file")
        self.skip()
        var name = self.parse_qname_text("the spec name")
        self.expect_newline()
        var decls = List[Int]()
        while self.kind() != T_EOF:
            decls.append(self.parse_decl())
        var id = self.ast.add(sx.FILE, self.close(m), text=name^, kids=decls^)
        self.ast.root = id
        self.ast.files[0].root = id
        return id

    def parse_prelude_file(mut self) raises -> Int:
        var m = self.mark()
        var decls = List[Int]()
        while self.kind() != T_EOF:
            if self.is_kw("use"):
                decls.append(self.parse_use(sx.USE, "use"))
            elif self.is_kw("fn"):
                var at = self.mark()
                var id = self.parse_fn()
                if self.ast.node(id).kind != sx.DEF:
                    raise self.error_at(
                        at, "a prelude holds definitions: fn name(...) -> type = expression"
                    )
                decls.append(id)
            elif self.kind() == T_INDENT:
                raise self.error("unexpected indentation")
            else:
                raise self.unexpected("a definition ('fn name(...) -> type = expression') or 'use'")
        var id = self.ast.add(sx.PRELUDE_FILE, self.close(m), kids=decls^)
        self.ast.root = id
        self.ast.files[0].root = id
        return id

    def parse_decl(mut self) raises -> Int:
        if self.kind() == T_INDENT:
            raise self.error("unexpected indentation")
        if self.kind() == T_NAME:
            var text = self.current().text.copy()
            match text:
                case "use":
                    return self.parse_use(sx.USE, "use")
                case "prelude":
                    return self.parse_use(sx.PRELUDE, "prelude")
                case "error":
                    return self.parse_error_decl()
                case "const":
                    return self.parse_const()
                case "enum":
                    return self.parse_enum()
                case "record":
                    return self.parse_record()
                case "type":
                    return self.parse_alias()
                case "model":
                    return self.parse_model_or_interface(interface=False)
                case "interface":
                    return self.parse_model_or_interface(interface=True)
                case "fn":
                    return self.parse_fn()
                case _:
                    pass
            var is_member = text in ["partition", "observe", "build", "new", "method"]
            if is_member or _clause_op(text) != sx.NO_OP:
                raise self.error(
                    t"'{text}' must be indented under a declaration (fn, model or interface)"
                )
        raise self.unexpected(
            "a declaration (fn, model, interface, error, enum, record, type, const,"
            " prelude or use)"
        )

    def parse_use(mut self, kind: UInt8, word: String) raises -> Int:
        var m = self.mark()
        self.skip()
        if self.kind() != T_STRING:
            raise self.unexpected(t"a file name in quotes, e.g. {word} \"other\"")
        var path = self.advance().text.copy()
        var id = self.ast.add(kind, self.close(m), text=path^)
        self.expect_newline()
        return id

    def parse_error_decl(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("an error name")
        var id = self.ast.add(sx.ERROR, self.close(m), text=name^)
        self.expect_newline()
        return id

    def parse_const(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a constant name")
        _ = self.expect_op(":", "':' and the type of the constant")
        var type = self.parse_type()
        var id = self.ast.add(sx.CONST, self.close(m), text=name^, kids=[type])
        self.expect_newline()
        return id

    def parse_enum(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("an enum name").text.copy()
        _ = self.expect_op("{")
        var members = self.separated[Self.parse_enum_member]()
        _ = self.expect_op("}", "',' or '}'")
        var id = self.ast.add(sx.ENUM, self.close(m), text=name^, kids=members^)
        self.expect_newline()
        return id

    def parse_enum_member(mut self) raises -> Int:
        var m = self.mark()
        var member = self.expect_name("an enum member").text.copy()
        return self.ast.add(sx.NAME, self.close(m), text=member^)

    def parse_record(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a record name").text.copy()
        _ = self.expect_op("{")
        var fields = self.bracketed[Self.parse_param]("}")
        var id = self.ast.add(sx.RECORD, self.close(m), text=name^, kids=fields^)
        self.expect_newline()
        return id

    def parse_alias(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a type name").text.copy()
        _ = self.expect_op("=")
        var type = self.parse_type()
        var id = self.ast.add(sx.ALIAS, self.close(m), text=name^, kids=[type])
        self.expect_newline()
        return id

    def parse_model_or_interface(mut self, *, interface: Bool) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("an interface name" if interface else "a model name")
        var kids = List[Int]()
        kids.append(self.parse_tparams())
        self.expect_newline()
        if self.kind() == T_INDENT:
            self.skip()
            while self.kind() != T_DEDENT:
                if self.kind() == T_EOF:
                    raise self.unexpected(
                        "an interface member" if interface else "an observer or invariant"
                    )
                if self.is_kw("observe"):
                    kids.append(self.parse_observe())
                elif interface and self.is_kw("new"):
                    kids.append(self.parse_ctor())
                elif interface and self.is_kw("method"):
                    kids.append(self.parse_method())
                elif not interface and self.is_kw("build"):
                    kids.append(self.parse_build())
                elif self.is_clause_kw():
                    kids.append(self.parse_clause())
                else:
                    raise self.unexpected(
                        "'observe', 'new', 'method' or a clause such as 'invariant'" if interface
                        else "'observe', 'build' or a clause such as 'invariant'"
                    )
            self.skip()
        return self.ast.add(
            sx.INTERFACE if interface else sx.MODEL, self.close(m), text=name^, kids=kids^
        )

    def parse_fn(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a function name")
        var kids = List[Int]()
        kids.append(self.parse_tparams())
        kids.append(self.parse_params())
        var returns = self.parse_type() if self.accept_op("->") else NIL
        kids.append(returns)
        if not self.is_op("="):
            self.expect_newline()
            self.parse_body(kids)
            return self.ast.add(sx.FN, self.close(m), text=name^, kids=kids^)
        if returns == NIL:
            raise self.error("a definition needs a return type: fn name(...) -> type = expression")
        if "." in name:
            raise self.error("a definition's name is a single name, not a qualified one")
        self.skip()
        var continued = self.kind() == T_NEWLINE and self.peek_kind(1) == T_INDENT
        if continued:
            self.skip()
            self.skip()
        kids.append(self.parse_expr())
        self.expect_newline()
        if continued:
            if self.kind() != T_DEDENT:
                raise self.unexpected("end of block")
            self.skip()
        return self.ast.add(sx.DEF, self.close(m), text=name^, kids=kids^)

    def parse_ctor(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a constructor name").text.copy()
        var kids = List[Int]()
        kids.append(self.empty_node(sx.TPARAMS))
        kids.append(self.parse_params())
        _ = self.expect_op("->", "'->' and the interface name")
        kids.append(self.parse_type())
        self.expect_newline()
        self.parse_body(kids)
        return self.ast.add(sx.CTOR, self.close(m), text=name^, kids=kids^)

    def parse_method(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a method name").text.copy()
        var kids = List[Int]()
        kids.append(self.empty_node(sx.TPARAMS))
        var pm = self.mark()
        _ = self.expect_op("(")
        if not self.is_kw("self"):
            raise self.unexpected("'self' as the first parameter of a method")
        var params = self.bracketed[Self.parse_param](")")
        kids.append(self.ast.add(sx.PARAMS, self.close(pm), kids=params^))
        kids.append(self.parse_type() if self.accept_op("->") else NIL)
        self.expect_newline()
        self.parse_body(kids)
        return self.ast.add(sx.METHOD, self.close(m), text=name^, kids=kids^)

    def parse_body(mut self, mut kids: List[Int]) raises:
        """An optional indented block of partitions and clauses."""
        if self.kind() != T_INDENT:
            return
        self.skip()
        while self.kind() != T_DEDENT:
            if self.kind() == T_EOF:
                raise self.unexpected("a clause")
            if self.is_kw("partition") and self.peek_kind(1) == T_NAME:
                kids.append(self.parse_partition())
            elif self.is_clause_kw():
                kids.append(self.parse_clause())
            else:
                raise self.unexpected("a clause (requires, ensures, raises, ...) or 'partition'")
        self.skip()

    def parse_observe(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("an observer name").text.copy()
        var params = self.parse_params() if self.is_op("(") else NIL
        _ = self.expect_op(":", "':' and the observed type")
        var type = self.parse_type()
        var body = self.parse_expr() if self.accept_op("=") else NIL
        var id = self.ast.add(sx.OBSERVE, self.close(m), text=name^, kids=[params, type, body])
        self.expect_newline()
        return id

    def parse_build(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("the name of a build call")
        var params = self.parse_params()
        var id = self.ast.add(sx.BUILD, self.close(m), text=name^, kids=[params])
        self.expect_newline()
        return id

    def parse_partition(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var param = self.expect_name("the partitioned parameter").text.copy()
        self.expect_newline()
        if self.kind() != T_INDENT:
            raise self.unexpected("an indented list of classes ('name = expr')")
        self.skip()
        var classes = List[Int]()
        while self.kind() != T_DEDENT:
            if self.kind() == T_EOF:
                raise self.unexpected("a partition class")
            var cm = self.mark()
            var cname = self.expect_name("a partition class name").text.copy()
            _ = self.expect_op("=", "'=' and the class expression")
            var expr = self.parse_expr()
            classes.append(self.ast.add(sx.CLASS, self.close(cm), text=cname^, kids=[expr]))
            self.expect_newline()
        self.skip()
        return self.ast.add(sx.PARTITION, self.close(m), text=param^, kids=classes^)

    def parse_label(mut self) -> String:
        if (
            self.kind() == T_NAME
            and not _is_reserved(self.current().text)
            and self.peek_is_op(1, ":")
        ):
            var label = self.advance().text.copy()
            self.skip()
            return label^
        return String()

    def parse_clause(mut self) raises -> Int:
        var m = self.mark()
        var op = _clause_op(self.advance().text)
        var label = String()
        var kids = List[Int]()
        if op in [sx.REQUIRES, sx.ENSURES, sx.RELATES, sx.INVARIANT, sx.AGGREGATE]:
            label = self.parse_label()
            kids.append(self.parse_expr())
        elif op == sx.RAISES or op == sx.MAY_RAISE:
            label = self.parse_label()
            kids.append(self.parse_qname_node("an error name"))
            if op == sx.RAISES and not self.is_kw("when"):
                raise self.unexpected("'when' and the condition under which it raises")
            if self.is_kw("when"):
                self.skip()
                kids.append(self.parse_expr())
            else:
                kids.append(NIL)
        elif op == sx.MODIFIES:
            kids.append(self.parse_name_node("a parameter name or self"))
            while self.accept_op(","):
                kids.append(self.parse_name_node("a parameter name or self"))
        elif op == sx.UNSPECIFIED or op == sx.IMPL_DEFINED:
            kids.append(self.parse_name_node("the name of the freedom"))
        else:
            var pm = self.mark()
            var lines: List[String] = []
            while self.kind() == T_PERF:
                lines.append(self.advance().text.copy())
            if len(lines) == 0:
                pm.start = self.last_end
                pm.end = self.last_end
            kids.append(self.ast.add(sx.STR, self.close(pm), text=" ".join(lines)))
        var id = self.ast.add(sx.CLAUSE, self.close(m), op=op, text=label^, kids=kids^)
        self.expect_newline()
        return id

    def parse_qname_text(mut self, what: String) raises -> String:
        var name = self.expect_name(what).text.copy()
        while self.is_op(".") and self.peek_kind(1) == T_NAME:
            self.skip()
            name += String(".", self.advance().text)
        return name^

    def parse_qname_node(mut self, what: String) raises -> Int:
        var m = self.mark()
        var name = self.parse_qname_text(what)
        return self.ast.add(sx.QNAME, self.close(m), text=name^)

    def parse_name_node(mut self, what: String) raises -> Int:
        var m = self.mark()
        var name = self.expect_name(what).text.copy()
        return self.ast.add(sx.NAME, self.close(m), text=name^)

    def parse_tparams(mut self) raises -> Int:
        if not self.is_op("<"):
            return self.empty_node(sx.TPARAMS)
        var m = self.mark()
        self.skip()
        var items = self.separated[Self.parse_tparam]()
        self.expect_gt()
        return self.ast.add(sx.TPARAMS, self.close(m), kids=items^)

    def parse_tparam(mut self) raises -> Int:
        var m = self.mark()
        var name = self.expect_name("a type parameter").text.copy()
        var kids = List[Int]()
        if self.accept_op(":"):
            kids.append(self.parse_qname_node("a bound (Eq or Ord)"))
        return self.ast.add(sx.TPARAM, self.close(m), text=name^, kids=kids^)

    def parse_params(mut self) raises -> Int:
        var m = self.mark()
        _ = self.expect_op("(", "'(' and the parameters")
        var items = self.bracketed[Self.parse_param](")", allow_empty=True)
        return self.ast.add(sx.PARAMS, self.close(m), kids=items^)

    def parse_param(mut self) raises -> Int:
        var m = self.mark()
        var name = self.expect_name("a parameter name").text.copy()
        if name == "self" and not self.is_op(":"):
            return self.ast.add(sx.PARAM, self.close(m), text=name^, kids=[NIL, NIL])
        _ = self.expect_op(":", String("':' and the type of ", name))
        var type = self.parse_type()
        var default = self.parse_expr() if self.accept_op("=") else NIL
        return self.ast.add(sx.PARAM, self.close(m), text=name^, kids=[type, default])

    def parse_choice_alt(mut self) raises -> Int:
        var m = self.mark()
        if self.kind() == T_STRING:
            var value = self.advance().text.copy()
            return self.ast.add(sx.STR, self.close(m), text=value^)
        if self.kind() == T_NAME:
            return self.parse_qname_node("a constant name")
        raise self.unexpected("a string literal or a constant name in the choice")

    def parse_type(mut self) raises -> Int:
        var m = self.mark()
        if self.kind() == T_STRING:
            var alts = self.separated[Self.parse_choice_alt]("|")
            return self.ast.add(sx.CHOICE_TYPE, self.close(m), kids=alts^)
        if self.accept_op("("):
            var items = self.bracketed[Self.parse_type](")")
            if len(items) < 2:
                raise self.error_at(m, "a tuple type has at least two elements")
            return self.ast.add(sx.TUPLE_TYPE, self.close(m), kids=items^)
        var name = self.parse_qname_text("a type")
        if self.accept_op("<"):
            var args = self.separated[Self.parse_type]()
            self.expect_gt()
            return self.ast.add(sx.TYPE, self.close(m), text=name^, kids=args^)
        if self.is_op("|"):
            var alts = List[Int]()
            alts.append(self.ast.add(sx.QNAME, self.close(m), text=name^))
            while self.accept_op("|"):
                alts.append(self.parse_choice_alt())
            return self.ast.add(sx.CHOICE_TYPE, self.close(m), kids=alts^)
        return self.ast.add(sx.TYPE, self.close(m), text=name^)

    def parse_expr(mut self) raises -> Int:
        return self.parse_implies()

    def parse_implies(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_or()
        if not self.is_kw("implies"):
            return left
        self.skip()
        var right = self.parse_implies()
        return self.ast.add(sx.BINARY, self.close(m), op=sx.IMPLIES, kids=[left, right])

    def parse_or(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_and()
        while self.is_kw("or"):
            self.skip()
            var right = self.parse_and()
            left = self.ast.add(sx.BINARY, self.close(m), op=sx.OR, kids=[left, right])
        return left

    def parse_and(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_not()
        while self.is_kw("and"):
            self.skip()
            var right = self.parse_not()
            left = self.ast.add(sx.BINARY, self.close(m), op=sx.AND, kids=[left, right])
        return left

    def parse_not(mut self) raises -> Int:
        var m = self.mark()
        if not self.is_kw("not"):
            return self.parse_cmp()
        self.skip()
        var operand = self.parse_not()
        return self.ast.add(sx.UNARY, self.close(m), op=sx.NOT, kids=[operand])

    def cmp_op(self) -> UInt8:
        ref t = self.current()
        if t.kind == T_NAME and t.text == "in":
            return sx.NO_OP if self.no_in else sx.IN
        return _cmp_op(t.text) if t.kind == T_OP else sx.NO_OP

    def parse_cmp(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_level(0)
        var op = self.cmp_op()
        if op == sx.NO_OP:
            return left
        var first = self.advance().text.copy()
        var right = self.parse_level(0)
        var node = self.ast.add(sx.BINARY, self.close(m), op=op, kids=[left, right])
        if self.cmp_op() != sx.NO_OP:
            var second = String(self.ast.source[byte = self.current().start : self.current().end])
            raise self.error(t"comparisons do not chain: write 'a {first} b and b {second} c'")
        return node

    def parse_level(mut self, level: Int) raises -> Int:
        if level == _LEVELS:
            return self.parse_unary()
        var m = self.mark()
        var left = self.parse_level(level + 1)
        while self.kind() == T_OP:
            var op = _level_op(level, self.current().text)
            if op == sx.NO_OP:
                break
            self.skip()
            var right = self.parse_level(level + 1)
            left = self.ast.add(sx.BINARY, self.close(m), op=op, kids=[left, right])
        return left

    def parse_unary(mut self) raises -> Int:
        var m = self.mark()
        if self.accept_op("-"):
            var operand = self.parse_unary()
            return self.ast.add(sx.UNARY, self.close(m), op=sx.NEG, kids=[operand])
        if self.is_kw("let"):
            return self.parse_let()
        if self.is_kw("if"):
            return self.parse_if()
        var base = self.parse_post()
        if not self.accept_op("**"):
            return base
        var exponent = self.parse_unary()
        return self.ast.add(sx.BINARY, self.close(m), op=sx.POW, kids=[base, exponent])

    def parse_let(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("the name bound by let").text.copy()
        _ = self.expect_op("=", "'=' and the value bound by let")
        var saved = self.no_in
        self.no_in = True
        var value = self.parse_expr()
        self.no_in = saved
        if not self.is_kw("in"):
            raise self.unexpected("'in' after the value bound by let")
        self.skip()
        var body = self.parse_expr()
        return self.ast.add(sx.LET, self.close(m), text=name^, kids=[value, body])

    def parse_if(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var saved = self.no_in
        self.no_in = False
        var cond = self.parse_expr()
        if not self.is_kw("then"):
            raise self.unexpected("'then'")
        self.skip()
        var then = self.parse_expr()
        self.no_in = saved
        if not self.is_kw("else"):
            raise self.unexpected("'else' (every if has an else branch)")
        self.skip()
        var other = self.parse_expr()
        return self.ast.add(sx.IF, self.close(m), kids=[cond, then, other])

    def parse_post(mut self) raises -> Int:
        var m = self.mark()
        var node = self.parse_atom()
        while True:
            if self.is_op("("):
                node = self.parse_call(node, self.empty_node(sx.TYPEARGS), m)
            elif self.accept_op("."):
                if self.kind() == T_NUMBER:
                    var index = self.advance().text.copy()
                    node = self.ast.add(sx.TUPLE_INDEX, self.close(m), text=index^, kids=[node])
                elif self.kind() == T_NAME:
                    var attr = self.advance().text.copy()
                    node = self.ast.add(sx.ATTR, self.close(m), text=attr^, kids=[node])
                else:
                    raise self.unexpected("a field name or tuple index after '.'")
            elif self.accept_op("["):
                var saved = self.no_in
                self.no_in = False
                var first = self.parse_expr()
                var is_slice = self.accept_op(":")
                var stop = self.parse_expr() if is_slice else NIL
                _ = self.expect_op("]", "']'" if is_slice else "':' or ']'")
                self.no_in = saved
                if is_slice:
                    node = self.ast.add(sx.SLICE, self.close(m), kids=[node, first, stop])
                else:
                    node = self.ast.add(sx.INDEX, self.close(m), kids=[node, first])
            else:
                return node

    def parse_call(mut self, callee: Int, typeargs: Int, m: SrcSpan) raises -> Int:
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        var kids: List[Int] = [callee, typeargs]
        var keywords: List[String] = []
        if not self.accept_op(")"):
            while True:
                var am = self.mark()
                if self.kind() == T_NAME and self.peek_is_op(1, "="):
                    var key = self.expect_name("an argument name")
                    self.skip()
                    if key.text in keywords:
                        raise self.error_at(key.span(), t"argument {key.text} is given twice")
                    keywords.append(key.text.copy())
                    var value = self.parse_expr()
                    var arg = self.ast.add(sx.ARG, self.close(am), text=key.text.copy(), kids=[value])
                    kids.append(arg)
                else:
                    if len(keywords) > 0:
                        raise self.error("positional arguments must come before named ones")
                    var value = self.parse_expr()
                    kids.append(self.ast.add(sx.ARG, self.close(am), kids=[value]))
                if not self.accept_op(","):
                    break
            _ = self.expect_op(")", "',' or ')'")
        self.no_in = saved
        return self.ast.add(sx.CALL, self.close(m), kids=kids^)

    def parse_atom(mut self) raises -> Int:
        var m = self.mark()
        var k = self.kind()
        if k == T_NUMBER or k == T_STRING:
            var literal = self.advance().text.copy()
            return self.ast.add(sx.NUM if k == T_NUMBER else sx.STR, self.close(m), text=literal^)
        if k == T_NAME:
            var text = self.current().text.copy()
            if text == "true" or text == "false":
                self.skip()
                var value = sx.TRUE if text == "true" else sx.FALSE
                return self.ast.add(sx.BOOL, self.close(m), op=value)
            if text == "none":
                self.skip()
                return self.ast.add(sx.NONE, self.close(m))
            if (
                _comprehension_op(text) != sx.NO_OP
                and self.peek_is_op(1, "(")
                and self.peek_kind(2) == T_NAME
                and self.peek_is_kw(3, "in")
            ):
                return self.parse_comprehension()
            if _is_reserved(text):
                raise self.unexpected("an expression")
            self.skip()
            var name = self.ast.add(sx.NAME, self.close(m), text=text.copy())
            if text in ["wrap", "fits", "round", "ulp", "qe"] and self.is_op("<"):
                var tm = self.mark()
                self.skip()
                var args = self.separated[Self.parse_type]()
                self.expect_gt()
                var typeargs = self.ast.add(sx.TYPEARGS, self.close(tm), kids=args^)
                if not self.is_op("("):
                    raise self.unexpected(t"'(' and the arguments of {text}<...>")
                return self.parse_call(name, typeargs, m)
            return name
        if self.accept_op("["):
            var elems = self.bracketed[Self.parse_expr]("]", allow_empty=True)
            return self.ast.add(sx.LIST, self.close(m), kids=elems^)
        if self.accept_op("{"):
            var elems = self.bracketed[Self.parse_expr]("}", allow_empty=True)
            return self.ast.add(sx.SET, self.close(m), kids=elems^)
        if self.accept_op("("):
            var elems = self.bracketed[Self.parse_expr](")")
            if len(elems) == 1:
                return elems[0]
            return self.ast.add(sx.TUPLE, self.close(m), kids=elems^)
        raise self.unexpected("an expression")

    def parse_comprehension(mut self) raises -> Int:
        var m = self.mark()
        var word = self.advance().text.copy()
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        var variable = self.expect_name("the comprehension variable").text.copy()
        self.expect_kw("in")
        var iterable = self.parse_expr()
        _ = self.expect_op(":", String("':' and the body of ", word, "(...)"))
        var body = self.parse_expr()
        _ = self.expect_op(")", "')'")
        self.no_in = saved
        return self.ast.add(
            sx.COMPREHENSION, self.close(m),
            op=_comprehension_op(word), text=variable^, kids=[iterable, body],
        )


def parse_spec(source: String, path: String) raises -> Ast:
    """Parse a spec file. A syntax error raises an `Error` of the form `path:line:col: message`."""
    var parser = Parser(tokenize(source, path), source.copy(), path.copy())
    _ = parser.parse_file()
    return parser^.into_ast()


def parse_into(mut ast: Ast, source: String, path: String) raises -> Int:
    """Appends a spec file or a user prelude (told apart by a leading `spec`) to `ast`.

    Its nodes follow the existing ones and its source follows `ast.source`. Spans keep
    byte offsets into the combined source, and each one's line and column stay the
    file's own. Returns the file's index in `ast.files`.
    """
    var tokens = tokenize(source, path)
    var is_spec = False
    for t in tokens:
        if t.kind == T_NAME:
            is_spec = t.text == "spec"
            break
        if not T_NEWLINE <= t.kind <= T_DEDENT:
            break
    var parser = Parser(tokens^, source.copy(), path.copy())
    _ = parser.parse_file() if is_spec else parser.parse_prelude_file()
    var sub = parser^.into_ast()
    var n0 = len(ast.nodes)
    var offset = ast.source.byte_length()
    for i in range(1, len(sub.nodes)):
        ref n = sub.nodes[i]
        var kids = [0 if k == 0 else n0 + k - 1 for k in n.kids]
        var span = SrcSpan(n.span.start + offset, n.span.end + offset, n.span.line, n.span.col)
        ast.nodes.append(Node(n.kind, n.op, span, n.text.copy(), kids^))
    ast.source += source
    ast.files.append(SourceFile(path.copy(), source.copy(), offset, n0, n0 + sub.root - 1))
    return len(ast.files) - 1
