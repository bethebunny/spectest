"""Recursive-descent parser for spec files and user preludes.

Follows the grammar of docs/language.md and docs/v2/syntax.md. `let` and `if` may also
start any operand (`a implies let y = e in b`) and then extend as far right as
possible. Inside a `let` value, `in` ends the value unless it is bracketed.

The tree is built flat into `Ast` (see `syntax/ast.mojo` for each node's children).
Every node's span runs from its first token to the last token consumed, so a clause
covers its continuation lines.
"""

from syntax.ast import Ast, File, NIL, Node, NodeKind, Op, Span
from syntax.lexer import Token, TokenKind, syntax_error, tokens


def _is_reserved(text: String) -> Bool:
    return text in [
        "let", "in", "if", "then", "else", "implies", "or", "and", "not", "true", "false", "none"
    ]


def _comprehension_op(text: String) -> Op:
    return Op.named(text, first=.ALL, last=.FILTER)


def _clause_op(text: String) -> Op:
    return Op.named(text, first=.REQUIRES, last=.PERF)


# Binary operator levels, loosest first: | & shifts sums products. Level 5 is unary.
comptime _LEVELS = 5


def _level_op(level: Int, text: String) -> Op:
    match level:
        case 0:
            return Op.named(text, first=.BITOR, last=.BITOR)
        case 1:
            return Op.named(text, first=.BITAND, last=.BITAND)
        case 2:
            return Op.named(text, first=.SHL, last=.SHR)
        case 3:
            return Op.named(text, first=.ADD, last=.SUB)
        case _:
            return Op.named(text, first=.MUL, last=.MOD)


struct Parser:
    var tokens: List[Token]
    var pos: Int
    var no_in: Bool
    """`in` ends the expression here: inside a `let` value, outside brackets."""
    var last_end: Int
    """Where the last token consumed ends; layout tokens leave it."""
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

    def kind(self) -> TokenKind:
        return self.current().kind

    def peek(self, k: Int) -> ref [self.tokens[0]] Token:
        """The token `k` ahead, or EOF past the end."""
        return self.tokens[min(self.pos + k, len(self.tokens) - 1)]

    def skip(mut self):
        ref t = self.current()
        if t.kind == .EOF:
            return
        if not t.kind.is_layout():
            self.last_end = t.span.end
        self.pos += 1

    def advance(mut self) -> Token:
        var t = self.current().copy()
        self.skip()
        return t^

    def is_keyword(self, word: StaticString) -> Bool:
        return self.current().is_keyword(word)

    def is_op(self, op: StaticString) -> Bool:
        return self.current().is_op(op)

    def accept_op(mut self, op: StaticString) -> Bool:
        if self.is_op(op):
            self.skip()
            return True
        return False

    def is_clause_keyword(self) -> Bool:
        return self.kind() == .NAME and _clause_op(self.current().text) != .NO_OP

    def describe(self, t: Token) -> String:
        match t.kind:
            case .NEWLINE:
                return "end of line"
            case .INDENT:
                return "an indented block"
            case .DEDENT:
                return "end of block"
            case .EOF:
                return "end of file"
            case _:
                return String("'", self.ast.source[byte = t.span.start : t.span.end], "'")

    def error_at(self, span: Span, message: Some[Writable]) -> Error:
        return syntax_error(self.ast.files[0].path, span, String(message))

    def error(self, message: Some[Writable]) -> Error:
        return self.error_at(self.current().span, message)

    def unexpected(self, wanted: Some[Writable]) -> Error:
        return self.error(t"expected {wanted}, found {self.describe(self.current())}")

    def expect_op(mut self, op: StaticString, wanted: String = "") raises -> Token:
        if not self.is_op(op):
            raise self.unexpected(wanted if wanted else String("'", op, "'"))
        return self.advance()

    def expect_keyword(mut self, word: StaticString) raises:
        if not self.is_keyword(word):
            raise self.unexpected(String("'", word, "'"))
        self.skip()

    def expect_name(mut self, what: String = "a name") raises -> Token:
        if self.kind() != .NAME:
            raise self.unexpected(what)
        if _is_reserved(self.current().text):
            raise self.error(t"'{self.current().text}' is a reserved word and cannot be {what}")
        return self.advance()

    def expect_newline(mut self) raises:
        if self.kind() != .NEWLINE:
            raise self.unexpected("end of line")
        self.skip()

    def expect_gt(mut self) raises:
        """Consume '>' in type syntax, splitting a '>=' or '>>' token if needed."""
        if self.is_op(">=") or self.is_op(">>"):
            ref t = self.tokens[self.pos]
            var rest = String(t.text[byte=1:])
            t.text = rest^
            t.span.start += 1
            t.span.column += 1
            self.last_end = t.span.start
        else:
            _ = self.expect_op(">")

    def mark(self) -> Span:
        """The empty span at the start of the current token."""
        var span = self.current().span
        span.end = span.start
        return span

    def close(self, m: Span) -> Span:
        """The span from the mark `m` to the end of the last token."""
        var span = m
        span.end = max(self.last_end, m.start)
        return span

    def empty_node(mut self, kind: NodeKind) -> Int:
        """A childless node of `kind`, zero-width at the end of the last token."""
        var at = self.mark()
        at.start = self.last_end
        at.end = self.last_end
        return self.ast.add(kind, at)

    def separated[item: def(mut Self) thin raises -> Int](
        mut self, separator: StaticString = ","
    ) raises -> List[Int]:
        """At least one `item`, with `separator` between them."""
        var items: List[Int] = [item(self)]
        while self.accept_op(separator):
            items.append(item(self))
        return items^

    def bracketed[item: def(mut Self) thin raises -> Int](
        mut self, close: StaticString, *, allow_empty: Bool = False
    ) raises -> List[Int]:
        """Comma-separated `item`s up to `close`, within which `in` is allowed again."""
        var saved = self.no_in
        self.no_in = False
        var items: List[Int] = []
        if not (allow_empty and self.is_op(close)):
            items = self.separated[item]()
        _ = self.expect_op(close, String("',' or '", close, "'"))
        self.no_in = saved
        return items^

    def parse_file(mut self) raises -> Int:
        var m = self.mark()
        if not self.is_keyword("spec"):
            raise self.unexpected("'spec <name>' at the start of the file")
        self.skip()
        var name = self.parse_qname_text("the spec name")
        self.expect_newline()
        var decls: List[Int] = []
        while self.kind() != .EOF:
            decls.append(self.parse_decl())
        self.ast.files[0].root = self.ast.add(.FILE, self.close(m), text=name^, children=decls^)
        return self.ast.root()

    def parse_prelude_file(mut self) raises -> Int:
        var m = self.mark()
        var decls: List[Int] = []
        while self.kind() != .EOF:
            if self.is_keyword("use"):
                decls.append(self.parse_use(.USE, "use"))
            elif self.is_keyword("fn"):
                var at = self.mark()
                var id = self.parse_fn()
                if self.ast.node(id).kind != .DEF:
                    raise self.error_at(
                        at, "a prelude holds definitions: fn name(...) -> type = expression"
                    )
                decls.append(id)
            elif self.kind() == .INDENT:
                raise self.error("unexpected indentation")
            else:
                raise self.unexpected("a definition ('fn name(...) -> type = expression') or 'use'")
        self.ast.files[0].root = self.ast.add(.PRELUDE_FILE, self.close(m), children=decls^)
        return self.ast.root()

    def parse_decl(mut self) raises -> Int:
        if self.kind() == .INDENT:
            raise self.error("unexpected indentation")
        if self.kind() == .NAME:
            var text = self.current().text.copy()
            match text:
                case "use":
                    return self.parse_use(.USE, "use")
                case "prelude":
                    return self.parse_use(.PRELUDE, "prelude")
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
            if is_member or _clause_op(text) != .NO_OP:
                raise self.error(
                    t"'{text}' must be indented under a declaration (fn, model or interface)"
                )
        raise self.unexpected(
            "a declaration (fn, model, interface, error, enum, record, type, const,"
            " prelude or use)"
        )

    def parse_use(mut self, kind: NodeKind, word: String) raises -> Int:
        var m = self.mark()
        self.skip()
        if self.kind() != .STRING:
            raise self.unexpected(t"a file name in quotes, e.g. {word} \"other\"")
        var path = self.advance().text.copy()
        var id = self.ast.add(kind, self.close(m), text=path^)
        self.expect_newline()
        return id

    def parse_error_decl(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("an error name")
        var id = self.ast.add(.ERROR, self.close(m), text=name^)
        self.expect_newline()
        return id

    def parse_const(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a constant name")
        _ = self.expect_op(":", "':' and the type of the constant")
        var type = self.parse_type()
        var id = self.ast.add(.CONST, self.close(m), text=name^, children=[type])
        self.expect_newline()
        return id

    def parse_enum(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("an enum name").text.copy()
        _ = self.expect_op("{")
        var members = self.separated[Self.parse_enum_member]()
        _ = self.expect_op("}", "',' or '}'")
        var id = self.ast.add(.ENUM, self.close(m), text=name^, children=members^)
        self.expect_newline()
        return id

    def parse_enum_member(mut self) raises -> Int:
        var m = self.mark()
        var member = self.expect_name("an enum member").text.copy()
        return self.ast.add(.NAME, self.close(m), text=member^)

    def parse_record(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a record name").text.copy()
        _ = self.expect_op("{")
        var fields = self.bracketed[Self.parse_param]("}")
        var id = self.ast.add(.RECORD, self.close(m), text=name^, children=fields^)
        self.expect_newline()
        return id

    def parse_alias(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a type name").text.copy()
        _ = self.expect_op("=")
        var type = self.parse_type()
        var id = self.ast.add(.ALIAS, self.close(m), text=name^, children=[type])
        self.expect_newline()
        return id

    def parse_model_or_interface(mut self, *, interface: Bool) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("an interface name" if interface else "a model name")
        var children: List[Int] = [self.parse_tparams()]
        self.expect_newline()
        if self.kind() == .INDENT:
            self.skip()
            while self.kind() != .DEDENT:
                if self.kind() == .EOF:
                    raise self.unexpected(
                        "an interface member" if interface else "an observer or invariant"
                    )
                if self.is_keyword("observe"):
                    children.append(self.parse_observe())
                elif interface and self.is_keyword("new"):
                    children.append(self.parse_ctor())
                elif interface and self.is_keyword("method"):
                    children.append(self.parse_method())
                elif not interface and self.is_keyword("build"):
                    children.append(self.parse_build())
                elif self.is_clause_keyword():
                    children.append(self.parse_clause())
                else:
                    raise self.unexpected(
                        "'observe', 'new', 'method' or a clause such as 'invariant'" if interface
                        else "'observe', 'build' or a clause such as 'invariant'"
                    )
            self.skip()
        var kind: NodeKind = .INTERFACE if interface else .MODEL
        return self.ast.add(kind, self.close(m), text=name^, children=children^)

    def parse_fn(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a function name")
        var children: List[Int] = [self.parse_tparams(), self.parse_params()]
        var returns = self.parse_type() if self.accept_op("->") else NIL
        children.append(returns)
        if not self.is_op("="):
            self.expect_newline()
            self.parse_body(children)
            return self.ast.add(.FN, self.close(m), text=name^, children=children^)
        if returns == NIL:
            raise self.error("a definition needs a return type: fn name(...) -> type = expression")
        if "." in name:
            raise self.error("a definition's name is a single name, not a qualified one")
        self.skip()
        var continued = self.kind() == .NEWLINE and self.peek(1).kind == .INDENT
        if continued:
            self.skip()
            self.skip()
        children.append(self.parse_expr())
        self.expect_newline()
        if continued:
            if self.kind() != .DEDENT:
                raise self.unexpected("end of block")
            self.skip()
        return self.ast.add(.DEF, self.close(m), text=name^, children=children^)

    def parse_ctor(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a constructor name").text.copy()
        var children: List[Int] = [self.empty_node(.TPARAMS), self.parse_params()]
        _ = self.expect_op("->", "'->' and the interface name")
        children.append(self.parse_type())
        self.expect_newline()
        self.parse_body(children)
        return self.ast.add(.CTOR, self.close(m), text=name^, children=children^)

    def parse_method(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a method name").text.copy()
        var children: List[Int] = [self.empty_node(.TPARAMS)]
        var pm = self.mark()
        _ = self.expect_op("(")
        if not self.is_keyword("self"):
            raise self.unexpected("'self' as the first parameter of a method")
        var params = self.bracketed[Self.parse_param](")")
        children.append(self.ast.add(.PARAMS, self.close(pm), children=params^))
        children.append(self.parse_type() if self.accept_op("->") else NIL)
        self.expect_newline()
        self.parse_body(children)
        return self.ast.add(.METHOD, self.close(m), text=name^, children=children^)

    def parse_body(mut self, mut children: List[Int]) raises:
        """An optional indented block of partitions and clauses."""
        if self.kind() != .INDENT:
            return
        self.skip()
        while self.kind() != .DEDENT:
            if self.kind() == .EOF:
                raise self.unexpected("a clause")
            if self.is_keyword("partition") and self.peek(1).kind == .NAME:
                children.append(self.parse_partition())
            elif self.is_clause_keyword():
                children.append(self.parse_clause())
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
        var id = self.ast.add(.OBSERVE, self.close(m), text=name^, children=[params, type, body])
        self.expect_newline()
        return id

    def parse_build(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("the name of a build call")
        var params = self.parse_params()
        var id = self.ast.add(.BUILD, self.close(m), text=name^, children=[params])
        self.expect_newline()
        return id

    def parse_partition(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var param = self.expect_name("the partitioned parameter").text.copy()
        self.expect_newline()
        if self.kind() != .INDENT:
            raise self.unexpected("an indented list of classes ('name = expr')")
        self.skip()
        var classes: List[Int] = []
        while self.kind() != .DEDENT:
            if self.kind() == .EOF:
                raise self.unexpected("a partition class")
            var cm = self.mark()
            var class_name = self.expect_name("a partition class name").text.copy()
            _ = self.expect_op("=", "'=' and the class expression")
            var expr = self.parse_expr()
            classes.append(self.ast.add(.CLASS, self.close(cm), text=class_name^, children=[expr]))
            self.expect_newline()
        self.skip()
        return self.ast.add(.PARTITION, self.close(m), text=param^, children=classes^)

    def parse_label(mut self) -> String:
        if (
            self.kind() == .NAME
            and not _is_reserved(self.current().text)
            and self.peek(1).is_op(":")
        ):
            var label = self.advance().text.copy()
            self.skip()
            return label^
        return ""

    def parse_clause(mut self) raises -> Int:
        var m = self.mark()
        var op = _clause_op(self.advance().text)
        var label: String = ""
        var children: List[Int] = []
        match op:
            case .REQUIRES | .ENSURES | .RELATES | .INVARIANT | .AGGREGATE:
                label = self.parse_label()
                children.append(self.parse_expr())
            case .RAISES | .MAY_RAISE:
                label = self.parse_label()
                children.append(self.parse_qname_node("an error name"))
                if op == .RAISES and not self.is_keyword("when"):
                    raise self.unexpected("'when' and the condition under which it raises")
                if self.is_keyword("when"):
                    self.skip()
                    children.append(self.parse_expr())
                else:
                    children.append(NIL)
            case .MODIFIES:
                children = self.separated[Self.parse_modified]()
            case .UNSPECIFIED | .IMPL_DEFINED:
                children.append(self.parse_name_node("the name of the freedom"))
            case _:
                var pm = self.mark()
                var lines: List[String] = []
                while self.kind() == .PERF:
                    lines.append(self.advance().text.copy())
                if not lines:
                    pm.start = self.last_end
                    pm.end = self.last_end
                children.append(self.ast.add(.STR, self.close(pm), text=" ".join(lines)))
        var id = self.ast.add(.CLAUSE, self.close(m), op=op, text=label^, children=children^)
        self.expect_newline()
        return id

    def parse_modified(mut self) raises -> Int:
        return self.parse_name_node("a parameter name or self")

    def parse_qname_text(mut self, what: String) raises -> String:
        var name = self.expect_name(what).text.copy()
        while self.is_op(".") and self.peek(1).kind == .NAME:
            self.skip()
            name += String(".", self.advance().text)
        return name^

    def parse_qname_node(mut self, what: String) raises -> Int:
        var m = self.mark()
        var name = self.parse_qname_text(what)
        return self.ast.add(.QNAME, self.close(m), text=name^)

    def parse_name_node(mut self, what: String) raises -> Int:
        var m = self.mark()
        var name = self.expect_name(what).text.copy()
        return self.ast.add(.NAME, self.close(m), text=name^)

    def parse_tparams(mut self) raises -> Int:
        if not self.is_op("<"):
            return self.empty_node(.TPARAMS)
        var m = self.mark()
        self.skip()
        var items = self.separated[Self.parse_tparam]()
        self.expect_gt()
        return self.ast.add(.TPARAMS, self.close(m), children=items^)

    def parse_tparam(mut self) raises -> Int:
        var m = self.mark()
        var name = self.expect_name("a type parameter").text.copy()
        var children: List[Int] = []
        if self.accept_op(":"):
            children.append(self.parse_qname_node("a bound (Eq or Ord)"))
        return self.ast.add(.TPARAM, self.close(m), text=name^, children=children^)

    def parse_params(mut self) raises -> Int:
        var m = self.mark()
        _ = self.expect_op("(", "'(' and the parameters")
        var items = self.bracketed[Self.parse_param](")", allow_empty=True)
        return self.ast.add(.PARAMS, self.close(m), children=items^)

    def parse_param(mut self) raises -> Int:
        var m = self.mark()
        var name = self.expect_name("a parameter name").text.copy()
        if name == "self" and not self.is_op(":"):
            return self.ast.add(.PARAM, self.close(m), text=name^, children=[NIL, NIL])
        _ = self.expect_op(":", String("':' and the type of ", name))
        var type = self.parse_type()
        var default = self.parse_expr() if self.accept_op("=") else NIL
        return self.ast.add(.PARAM, self.close(m), text=name^, children=[type, default])

    def parse_choice_alternative(mut self) raises -> Int:
        var m = self.mark()
        if self.kind() == .STRING:
            var value = self.advance().text.copy()
            return self.ast.add(.STR, self.close(m), text=value^)
        if self.kind() == .NAME:
            return self.parse_qname_node("a constant name")
        raise self.unexpected("a string literal or a constant name in the choice")

    def parse_type(mut self) raises -> Int:
        var m = self.mark()
        if self.kind() == .STRING:
            var alternatives = self.separated[Self.parse_choice_alternative]("|")
            return self.ast.add(.CHOICE_TYPE, self.close(m), children=alternatives^)
        if self.accept_op("("):
            var items = self.bracketed[Self.parse_type](")")
            if len(items) < 2:
                raise self.error_at(m, "a tuple type has at least two elements")
            return self.ast.add(.TUPLE_TYPE, self.close(m), children=items^)
        var name = self.parse_qname_text("a type")
        if self.accept_op("<"):
            var arguments = self.separated[Self.parse_type]()
            self.expect_gt()
            return self.ast.add(.TYPE, self.close(m), text=name^, children=arguments^)
        if self.is_op("|"):
            var alternatives: List[Int] = [self.ast.add(.QNAME, self.close(m), text=name^)]
            while self.accept_op("|"):
                alternatives.append(self.parse_choice_alternative())
            return self.ast.add(.CHOICE_TYPE, self.close(m), children=alternatives^)
        return self.ast.add(.TYPE, self.close(m), text=name^)

    def parse_expr(mut self) raises -> Int:
        return self.parse_implies()

    def parse_implies(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_or()
        if not self.is_keyword("implies"):
            return left
        self.skip()
        var right = self.parse_implies()
        return self.ast.add(.BINARY, self.close(m), op=.IMPLIES, children=[left, right])

    def parse_or(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_and()
        while self.is_keyword("or"):
            self.skip()
            var right = self.parse_and()
            left = self.ast.add(.BINARY, self.close(m), op=.OR, children=[left, right])
        return left

    def parse_and(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_not()
        while self.is_keyword("and"):
            self.skip()
            var right = self.parse_not()
            left = self.ast.add(.BINARY, self.close(m), op=.AND, children=[left, right])
        return left

    def parse_not(mut self) raises -> Int:
        var m = self.mark()
        if not self.is_keyword("not"):
            return self.parse_comparison()
        self.skip()
        var operand = self.parse_not()
        return self.ast.add(.UNARY, self.close(m), op=.NOT, children=[operand])

    def comparison_op(self) -> Op:
        ref t = self.current()
        if t.is_keyword("in"):
            return .NO_OP if self.no_in else .IN
        return Op.named(t.text, first=.EQ, last=.GE) if t.kind == .OP else .NO_OP

    def parse_comparison(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_level(0)
        var op = self.comparison_op()
        if op == .NO_OP:
            return left
        var first = self.advance().text.copy()
        var right = self.parse_level(0)
        var node = self.ast.add(.BINARY, self.close(m), op=op, children=[left, right])
        if self.comparison_op() != .NO_OP:
            var second = self.current().text.copy()
            raise self.error(t"comparisons do not chain: write 'a {first} b and b {second} c'")
        return node

    def parse_level(mut self, level: Int) raises -> Int:
        if level == _LEVELS:
            return self.parse_unary()
        var m = self.mark()
        var left = self.parse_level(level + 1)
        while self.kind() == .OP:
            var op = _level_op(level, self.current().text)
            if op == .NO_OP:
                break
            self.skip()
            var right = self.parse_level(level + 1)
            left = self.ast.add(.BINARY, self.close(m), op=op, children=[left, right])
        return left

    def parse_unary(mut self) raises -> Int:
        var m = self.mark()
        if self.accept_op("-"):
            var operand = self.parse_unary()
            return self.ast.add(.UNARY, self.close(m), op=.NEG, children=[operand])
        if self.is_keyword("let"):
            return self.parse_let()
        if self.is_keyword("if"):
            return self.parse_if()
        var base = self.parse_post()
        if not self.accept_op("**"):
            return base
        var exponent = self.parse_unary()
        return self.ast.add(.BINARY, self.close(m), op=.POW, children=[base, exponent])

    def parse_let(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("the name bound by let").text.copy()
        _ = self.expect_op("=", "'=' and the value bound by let")
        var saved = self.no_in
        self.no_in = True
        var value = self.parse_expr()
        self.no_in = saved
        if not self.is_keyword("in"):
            raise self.unexpected("'in' after the value bound by let")
        self.skip()
        var body = self.parse_expr()
        return self.ast.add(.LET, self.close(m), text=name^, children=[value, body])

    def parse_if(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var saved = self.no_in
        self.no_in = False
        var condition = self.parse_expr()
        if not self.is_keyword("then"):
            raise self.unexpected("'then'")
        self.skip()
        var then = self.parse_expr()
        self.no_in = saved
        if not self.is_keyword("else"):
            raise self.unexpected("'else' (every if has an else branch)")
        self.skip()
        var other = self.parse_expr()
        return self.ast.add(.IF, self.close(m), children=[condition, then, other])

    def parse_post(mut self) raises -> Int:
        var m = self.mark()
        var node = self.parse_atom()
        while True:
            if self.is_op("("):
                node = self.parse_call(node, self.empty_node(.TYPEARGS), m)
            elif self.accept_op("."):
                if self.kind() == .NUMBER:
                    var index = self.advance().text.copy()
                    node = self.ast.add(.TUPLE_INDEX, self.close(m), text=index^, children=[node])
                elif self.kind() == .NAME:
                    var attribute = self.advance().text.copy()
                    node = self.ast.add(.ATTR, self.close(m), text=attribute^, children=[node])
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
                    node = self.ast.add(.SLICE, self.close(m), children=[node, first, stop])
                else:
                    node = self.ast.add(.INDEX, self.close(m), children=[node, first])
            else:
                return node

    def parse_call(mut self, callee: Int, typeargs: Int, m: Span) raises -> Int:
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        var children: List[Int] = [callee, typeargs]
        var keywords: List[String] = []
        if not self.accept_op(")"):
            while True:
                var am = self.mark()
                if self.kind() == .NAME and self.peek(1).is_op("="):
                    var key = self.expect_name("an argument name")
                    self.skip()
                    if key.text in keywords:
                        raise self.error_at(key.span, t"argument {key.text} is given twice")
                    keywords.append(key.text.copy())
                    var value = self.parse_expr()
                    children.append(
                        self.ast.add(.ARG, self.close(am), text=key.text.copy(), children=[value])
                    )
                else:
                    if keywords:
                        raise self.error("positional arguments must come before named ones")
                    var value = self.parse_expr()
                    children.append(self.ast.add(.ARG, self.close(am), children=[value]))
                if not self.accept_op(","):
                    break
            _ = self.expect_op(")", "',' or ')'")
        self.no_in = saved
        return self.ast.add(.CALL, self.close(m), children=children^)

    def parse_atom(mut self) raises -> Int:
        var m = self.mark()
        match self.kind():
            case .NUMBER:
                var literal = self.advance().text.copy()
                return self.ast.add(.NUM, self.close(m), text=literal^)
            case .STRING:
                var literal = self.advance().text.copy()
                return self.ast.add(.STR, self.close(m), text=literal^)
            case .NAME:
                return self.parse_name_atom()
            case _:
                pass
        if self.accept_op("["):
            var elements = self.bracketed[Self.parse_expr]("]", allow_empty=True)
            return self.ast.add(.LIST, self.close(m), children=elements^)
        if self.accept_op("{"):
            var elements = self.bracketed[Self.parse_expr]("}", allow_empty=True)
            return self.ast.add(.SET, self.close(m), children=elements^)
        if self.accept_op("("):
            var elements = self.bracketed[Self.parse_expr](")")
            if len(elements) == 1:
                return elements[0]
            return self.ast.add(.TUPLE, self.close(m), children=elements^)
        raise self.unexpected("an expression")

    def parse_name_atom(mut self) raises -> Int:
        """A literal word, a comprehension, a name or a call with type arguments."""
        var m = self.mark()
        var text = self.current().text.copy()
        if text == "true" or text == "false":
            self.skip()
            return self.ast.add(.BOOL, self.close(m), op=Op.TRUE if text == "true" else Op.FALSE)
        if text == "none":
            self.skip()
            return self.ast.add(.NONE, self.close(m))
        if (
            _comprehension_op(text) != .NO_OP
            and self.peek(1).is_op("(")
            and self.peek(2).kind == .NAME
            and self.peek(3).is_keyword("in")
        ):
            return self.parse_comprehension()
        if _is_reserved(text):
            raise self.unexpected("an expression")
        self.skip()
        var name = self.ast.add(.NAME, self.close(m), text=text.copy())
        if text in ["wrap", "fits", "round", "ulp", "qe"] and self.is_op("<"):
            var tm = self.mark()
            self.skip()
            var arguments = self.separated[Self.parse_type]()
            self.expect_gt()
            var typeargs = self.ast.add(.TYPEARGS, self.close(tm), children=arguments^)
            if not self.is_op("("):
                raise self.unexpected(t"'(' and the arguments of {text}<...>")
            return self.parse_call(name, typeargs, m)
        return name

    def parse_comprehension(mut self) raises -> Int:
        var m = self.mark()
        var word = self.advance().text.copy()
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        var variable = self.expect_name("the comprehension variable").text.copy()
        self.expect_keyword("in")
        var iterable = self.parse_expr()
        _ = self.expect_op(":", String("':' and the body of ", word, "(...)"))
        var body = self.parse_expr()
        _ = self.expect_op(")", "')'")
        self.no_in = saved
        return self.ast.add(
            .COMPREHENSION, self.close(m),
            op=_comprehension_op(word), text=variable^, children=[iterable, body],
        )


def parse_spec(source: String, path: String) raises -> Ast:
    """Parse a spec file. A syntax error raises an `Error` of the form `path:line:col: message`."""
    var parser = Parser(tokens(source, path), source.copy(), path.copy())
    _ = parser.parse_file()
    return parser^.into_ast()


def parse_into(mut ast: Ast, source: String, path: String) raises -> Int:
    """Appends a spec file or a user prelude (told apart by a leading `spec`) to `ast`.

    Its nodes follow the existing ones and its source follows `ast.source`. Spans keep
    byte offsets into the combined source, and each one's line and column stay the
    file's own. Returns the file's index in `ast.files`.
    """
    var parser = Parser(tokens(source, path), source.copy(), path.copy())
    _ = parser.parse_file() if parser.is_keyword("spec") else parser.parse_prelude_file()
    var parsed = parser^.into_ast()
    var first = len(ast.nodes)
    var start = ast.source.byte_length()
    var file = len(ast.files)
    for node in parsed.nodes[1:]:
        var children = [NIL if c == NIL else first + c - 1 for c in node.children]
        var span = node.span
        span.start += start
        span.end += start
        ast.nodes.append(Node(node.kind, node.op, span, node.text.copy(), children^, file))
    ast.source += source
    ast.files.append(File(path.copy(), start=start, root=first + parsed.root() - 1))
    return file
