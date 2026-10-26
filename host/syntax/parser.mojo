"""Recursive-descent parser for spec files and user preludes.

Follows the grammar of docs/language.md and docs/v2/syntax.md. `let` and `if` may also
start any operand (`a implies let y = e in b`) and then extend as far right as
possible. Inside a `let` value, `in` ends the value unless it is bracketed.

The tree is built flat into `Ast` (see `syntax/ast.mojo` for each node's children).
Every node's span runs from its first token to the last token consumed, so a clause
covers its continuation lines.
"""

from syntax.ast import (
    Ast,
    Span as SrcSpan,
    FILE,
    PRELUDE_FILE,
    USE,
    PRELUDE,
    ERROR,
    CONST,
    ENUM,
    RECORD,
    ALIAS,
    MODEL,
    INTERFACE,
    FN,
    CTOR,
    METHOD,
    DEF,
    OBSERVE,
    BUILD,
    PARTITION,
    CLASS,
    CLAUSE,
    PARAMS,
    PARAM,
    TPARAMS,
    TPARAM,
    QNAME,
    TYPE,
    TUPLE_TYPE,
    CHOICE_TYPE,
    NUM,
    STR,
    BOOL,
    NONE,
    NAME,
    UNARY,
    BINARY,
    IF,
    LET,
    COMPREHENSION,
    CALL,
    TYPEARGS,
    ARG,
    ATTR,
    TUPLE_INDEX,
    INDEX,
    SLICE,
    LIST,
    SET,
    TUPLE,
    NO_OP,
    IMPLIES,
    OR,
    AND,
    EQ,
    NE,
    LT,
    LE,
    GT,
    GE,
    IN,
    BITOR,
    BITAND,
    SHL,
    SHR,
    ADD,
    SUB,
    MUL,
    DIV,
    FLOORDIV,
    MOD,
    POW,
    NEG,
    NOT,
    REQUIRES,
    ENSURES,
    RAISES,
    MAY_RAISE,
    MODIFIES,
    RELATES,
    INVARIANT,
    AGGREGATE,
    UNSPECIFIED,
    IMPL_DEFINED,
    PERF,
    ALL,
    EXISTS,
    COUNT,
    SUM,
    MAX,
    MAP,
    FILTER,
    FALSE,
    TRUE,
)
from syntax.lexer import (
    Token,
    tokenize,
    syntax_error,
    T_NAME,
    T_NUMBER,
    T_STRING,
    T_OP,
    T_PERF,
    T_NEWLINE,
    T_INDENT,
    T_DEDENT,
    T_EOF,
)


comptime NIL = 0
"""The index of the EMPTY node."""


def _is_reserved(text: String) -> Bool:
    return (
        text == "let"
        or text == "in"
        or text == "if"
        or text == "then"
        or text == "else"
        or text == "implies"
        or text == "or"
        or text == "and"
        or text == "not"
        or text == "true"
        or text == "false"
        or text == "none"
    )


def _comprehension_op(text: String) -> UInt8:
    if text == "all":
        return ALL
    if text == "exists":
        return EXISTS
    if text == "count":
        return COUNT
    if text == "sum":
        return SUM
    if text == "max":
        return MAX
    if text == "map":
        return MAP
    if text == "filter":
        return FILTER
    return NO_OP


def _clause_op(text: String) -> UInt8:
    if text == "requires":
        return REQUIRES
    if text == "ensures":
        return ENSURES
    if text == "relates":
        return RELATES
    if text == "invariant":
        return INVARIANT
    if text == "aggregate":
        return AGGREGATE
    if text == "raises":
        return RAISES
    if text == "may_raise":
        return MAY_RAISE
    if text == "modifies":
        return MODIFIES
    if text == "unspecified":
        return UNSPECIFIED
    if text == "impl_defined":
        return IMPL_DEFINED
    if text == "perf":
        return PERF
    return NO_OP


def _is_generic_fn(text: String) -> Bool:
    return (
        text == "wrap"
        or text == "fits"
        or text == "round"
        or text == "ulp"
        or text == "qe"
    )


def _is_digits(text: String) -> Bool:
    if text.byte_length() == 0:
        return False
    for b in text.as_bytes():
        if b < 48 or b > 57:
            return False
    return True


# Binary operator levels, loosest first: | & shifts sums products. Level 5 is unary.
comptime _LEVELS = 5


def _level_op(level: Int, text: String) -> UInt8:
    if level == 0:
        if text == "|":
            return BITOR
    elif level == 1:
        if text == "&":
            return BITAND
    elif level == 2:
        if text == "<<":
            return SHL
        if text == ">>":
            return SHR
    elif level == 3:
        if text == "+":
            return ADD
        if text == "-":
            return SUB
    else:
        if text == "*":
            return MUL
        if text == "/":
            return DIV
        if text == "//":
            return FLOORDIV
        if text == "%":
            return MOD
    return NO_OP


def _cmp_op(text: String) -> UInt8:
    if text == "==":
        return EQ
    if text == "!=":
        return NE
    if text == "<":
        return LT
    if text == "<=":
        return LE
    if text == ">":
        return GT
    if text == ">=":
        return GE
    return NO_OP


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

    # -- token helpers -----------------------------------------------------

    def kind(self) -> UInt8:
        return self.tokens[self.pos].kind

    def peek_index(self, k: Int) -> Int:
        return min(self.pos + k, len(self.tokens) - 1)

    def advance(mut self) -> Token:
        var t = self.tokens[self.pos].copy()
        if t.kind != T_EOF:
            self.pos += 1
            if t.kind != T_NEWLINE and t.kind != T_INDENT and t.kind != T_DEDENT:
                self.last_end = t.end
        return t^

    def skip(mut self):
        if self.tokens[self.pos].kind != T_EOF:
            var t = self.tokens[self.pos].kind
            if t != T_NEWLINE and t != T_INDENT and t != T_DEDENT:
                self.last_end = self.tokens[self.pos].end
            self.pos += 1

    def is_kw(self, word: StaticString) -> Bool:
        ref t = self.tokens[self.pos]
        return t.kind == T_NAME and t.text == word

    def is_op(self, op: StaticString) -> Bool:
        ref t = self.tokens[self.pos]
        return t.kind == T_OP and t.text == op

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
        ref t = self.tokens[self.pos]
        return t.kind == T_NAME and _clause_op(t.text) != NO_OP

    def describe(self, t: Token) -> String:
        if t.kind == T_NEWLINE:
            return "end of line"
        if t.kind == T_INDENT:
            return "an indented block"
        if t.kind == T_DEDENT:
            return "end of block"
        if t.kind == T_EOF:
            return "end of file"
        return "'" + String(self.ast.source[byte = t.start : t.end]) + "'"

    def error_at(self, span: SrcSpan, message: String) -> Error:
        return syntax_error(self.ast.path, span, message)

    def error(self, message: String) -> Error:
        return self.error_at(self.tokens[self.pos].span(), message)

    def unexpected(self, wanted: String) -> Error:
        return self.error(
            "expected " + wanted + ", found " + self.describe(self.tokens[self.pos])
        )

    def expect_op(mut self, op: StaticString, wanted: String = String()) raises -> Token:
        if not self.is_op(op):
            if wanted.byte_length() > 0:
                raise self.unexpected(wanted)
            raise self.unexpected("'" + String(op) + "'")
        return self.advance()

    def expect_kw(mut self, word: StaticString) raises:
        if not self.is_kw(word):
            raise self.unexpected("'" + String(word) + "'")
        self.skip()

    def expect_name(mut self, what: String = "a name") raises -> Token:
        if self.kind() != T_NAME:
            raise self.unexpected(what)
        if _is_reserved(self.tokens[self.pos].text):
            raise self.error(
                "'" + self.tokens[self.pos].text + "' is a reserved word and cannot be " + what
            )
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
            return
        _ = self.expect_op(">")

    def mark(self) -> SrcSpan:
        ref t = self.tokens[self.pos]
        return SrcSpan(t.start, t.start, t.line, t.col)

    def close(self, m: SrcSpan) -> SrcSpan:
        return SrcSpan(m.start, max(self.last_end, m.start), m.line, m.col)

    def empty_node(mut self, kind: UInt8) -> Int:
        """A childless node of `kind`, zero-width at the end of the last token."""
        var at = self.mark()
        at.start = self.last_end
        at.end = self.last_end
        return self.ast.add(kind, at)

    # -- files ------------------------------------------------------------

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
        var id = self.ast.add(FILE, self.close(m), text=name^, kids=decls^)
        self.ast.root = id
        return id

    def parse_prelude_file(mut self) raises -> Int:
        var m = self.mark()
        var decls = List[Int]()
        while self.kind() != T_EOF:
            if self.is_kw("use"):
                decls.append(self.parse_use(USE, "use"))
            elif self.is_kw("fn"):
                var at = self.mark()
                var id = self.parse_fn()
                if self.ast.node(id).kind != DEF:
                    raise self.error_at(
                        at,
                        "a prelude holds definitions: fn name(...) -> type = expression",
                    )
                decls.append(id)
            elif self.kind() == T_INDENT:
                raise self.error("unexpected indentation")
            else:
                raise self.unexpected(
                    "a definition ('fn name(...) -> type = expression') or 'use'"
                )
        var id = self.ast.add(PRELUDE_FILE, self.close(m), kids=decls^)
        self.ast.root = id
        return id

    def parse_decl(mut self) raises -> Int:
        if self.kind() == T_INDENT:
            raise self.error("unexpected indentation")
        if self.kind() == T_NAME:
            ref text = self.tokens[self.pos].text
            if text == "use":
                return self.parse_use(USE, "use")
            if text == "prelude":
                return self.parse_use(PRELUDE, "prelude")
            if text == "error":
                return self.parse_error_decl()
            if text == "const":
                return self.parse_const()
            if text == "enum":
                return self.parse_enum()
            if text == "record":
                return self.parse_record()
            if text == "type":
                return self.parse_alias()
            if text == "model":
                return self.parse_model()
            if text == "interface":
                return self.parse_interface()
            if text == "fn":
                return self.parse_fn()
            if (
                _clause_op(text) != NO_OP
                or text == "partition"
                or text == "observe"
                or text == "build"
                or text == "new"
                or text == "method"
            ):
                raise self.error(
                    "'" + text + "' must be indented under a declaration (fn, model or interface)"
                )
        raise self.unexpected(
            "a declaration (fn, model, interface, error, enum, record, type, const,"
            " prelude or use)"
        )

    def parse_use(mut self, kind: UInt8, word: String) raises -> Int:
        var m = self.mark()
        self.skip()
        if self.kind() != T_STRING:
            raise self.unexpected(
                "a file name in quotes, e.g. " + word + ' "other"'
            )
        var path = self.advance().text.copy()
        var id = self.ast.add(kind, self.close(m), text=path^)
        self.expect_newline()
        return id

    def parse_error_decl(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("an error name")
        var id = self.ast.add(ERROR, self.close(m), text=name^)
        self.expect_newline()
        return id

    def parse_const(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a constant name")
        _ = self.expect_op(":", "':' and the type of the constant")
        var type = self.parse_type()
        var id = self.ast.add(CONST, self.close(m), text=name^, kids=[type])
        self.expect_newline()
        return id

    def parse_enum(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("an enum name").text.copy()
        _ = self.expect_op("{")
        var members = List[Int]()
        while True:
            var at = self.mark()
            var member = self.expect_name("an enum member").text.copy()
            members.append(self.ast.add(NAME, self.close(at), text=member^))
            if not self.accept_op(","):
                break
        _ = self.expect_op("}", "',' or '}'")
        var id = self.ast.add(ENUM, self.close(m), text=name^, kids=members^)
        self.expect_newline()
        return id

    def parse_record(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a record name").text.copy()
        _ = self.expect_op("{")
        var saved = self.no_in
        self.no_in = False
        var fields = List[Int]()
        fields.append(self.parse_param())
        while self.accept_op(","):
            fields.append(self.parse_param())
        _ = self.expect_op("}", "',' or '}'")
        self.no_in = saved
        var id = self.ast.add(RECORD, self.close(m), text=name^, kids=fields^)
        self.expect_newline()
        return id

    def parse_alias(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a type name").text.copy()
        _ = self.expect_op("=")
        var type = self.parse_type()
        var id = self.ast.add(ALIAS, self.close(m), text=name^, kids=[type])
        self.expect_newline()
        return id

    # -- models, interfaces and functions -----------------------------------

    def parse_model(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a model name")
        var kids = List[Int]()
        kids.append(self.parse_tparams())
        self.expect_newline()
        if self.kind() == T_INDENT:
            self.skip()
            while self.kind() != T_DEDENT:
                if self.kind() == T_EOF:
                    raise self.unexpected("an observer or invariant")
                if self.is_kw("observe"):
                    kids.append(self.parse_observe())
                elif self.is_kw("build"):
                    kids.append(self.parse_build())
                elif self.is_clause_kw():
                    kids.append(self.parse_clause())
                else:
                    raise self.unexpected(
                        "'observe', 'build' or a clause such as 'invariant'"
                    )
            self.skip()
        return self.ast.add(MODEL, self.close(m), text=name^, kids=kids^)

    def parse_interface(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("an interface name")
        var kids = List[Int]()
        kids.append(self.parse_tparams())
        self.expect_newline()
        if self.kind() == T_INDENT:
            self.skip()
            while self.kind() != T_DEDENT:
                if self.kind() == T_EOF:
                    raise self.unexpected("an interface member")
                if self.is_kw("observe"):
                    kids.append(self.parse_observe())
                elif self.is_kw("new"):
                    kids.append(self.parse_ctor())
                elif self.is_kw("method"):
                    kids.append(self.parse_method())
                elif self.is_clause_kw():
                    kids.append(self.parse_clause())
                else:
                    raise self.unexpected(
                        "'observe', 'new', 'method' or a clause such as 'invariant'"
                    )
            self.skip()
        return self.ast.add(INTERFACE, self.close(m), text=name^, kids=kids^)

    def parse_fn(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("a function name")
        var kids = List[Int]()
        kids.append(self.parse_tparams())
        kids.append(self.parse_params())
        var returns = NIL
        if self.accept_op("->"):
            returns = self.parse_type()
        kids.append(returns)
        if self.is_op("="):
            if returns == NIL:
                raise self.error(
                    "a definition needs a return type: fn name(...) -> type = expression"
                )
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
            return self.ast.add(DEF, self.close(m), text=name^, kids=kids^)
        self.expect_newline()
        self.parse_body(kids)
        return self.ast.add(FN, self.close(m), text=name^, kids=kids^)

    def parse_ctor(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a constructor name").text.copy()
        var kids = List[Int]()
        kids.append(self.empty_node(TPARAMS))
        kids.append(self.parse_params())
        _ = self.expect_op("->", "'->' and the interface name")
        kids.append(self.parse_type())
        self.expect_newline()
        self.parse_body(kids)
        return self.ast.add(CTOR, self.close(m), text=name^, kids=kids^)

    def parse_method(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("a method name").text.copy()
        var kids = List[Int]()
        kids.append(self.empty_node(TPARAMS))
        var pm = self.mark()
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        if not self.is_kw("self"):
            raise self.unexpected("'self' as the first parameter of a method")
        var params = List[Int]()
        params.append(self.parse_param())
        while self.accept_op(","):
            params.append(self.parse_param())
        _ = self.expect_op(")", "',' or ')'")
        self.no_in = saved
        kids.append(self.ast.add(PARAMS, self.close(pm), kids=params^))
        if self.accept_op("->"):
            kids.append(self.parse_type())
        else:
            kids.append(NIL)
        self.expect_newline()
        self.parse_body(kids)
        return self.ast.add(METHOD, self.close(m), text=name^, kids=kids^)

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
                raise self.unexpected(
                    "a clause (requires, ensures, raises, ...) or 'partition'"
                )
        self.skip()

    def parse_observe(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.expect_name("an observer name").text.copy()
        var params = NIL
        if self.is_op("("):
            params = self.parse_params()
        _ = self.expect_op(":", "':' and the observed type")
        var type = self.parse_type()
        var body = NIL
        if self.accept_op("="):
            body = self.parse_expr()
        var id = self.ast.add(OBSERVE, self.close(m), text=name^, kids=[params, type, body])
        self.expect_newline()
        return id

    def parse_build(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var name = self.parse_qname_text("the name of a build call")
        var params = self.parse_params()
        var id = self.ast.add(BUILD, self.close(m), text=name^, kids=[params])
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
            classes.append(self.ast.add(CLASS, self.close(cm), text=cname^, kids=[expr]))
            self.expect_newline()
        self.skip()
        return self.ast.add(PARTITION, self.close(m), text=param^, kids=classes^)

    def parse_label(mut self) -> String:
        if (
            self.kind() == T_NAME
            and not _is_reserved(self.tokens[self.pos].text)
            and self.peek_is_op(1, ":")
        ):
            var label = self.tokens[self.pos].text.copy()
            self.skip()
            self.skip()
            return label^
        return String()

    def parse_clause(mut self) raises -> Int:
        var m = self.mark()
        var word = self.advance().text.copy()
        var op = _clause_op(word)
        var label = String()
        var kids = List[Int]()
        if (
            op == REQUIRES
            or op == ENSURES
            or op == RELATES
            or op == INVARIANT
            or op == AGGREGATE
        ):
            label = self.parse_label()
            kids.append(self.parse_expr())
        elif op == RAISES or op == MAY_RAISE:
            label = self.parse_label()
            kids.append(self.parse_qname_node("an error name"))
            if op == RAISES or self.is_kw("when"):
                if not self.is_kw("when"):
                    raise self.unexpected(
                        "'when' and the condition under which it raises"
                    )
                self.skip()
                kids.append(self.parse_expr())
            else:
                kids.append(NIL)
        elif op == MODIFIES:
            kids.append(self.parse_name_node("a parameter name or self"))
            while self.accept_op(","):
                kids.append(self.parse_name_node("a parameter name or self"))
        elif op == UNSPECIFIED or op == IMPL_DEFINED:
            kids.append(self.parse_name_node("the name of the freedom"))
        else:
            var raw = String()
            var first = True
            var pm = self.mark()
            var any = False
            while self.kind() == T_PERF:
                if first:
                    pm = self.mark()
                    first = False
                else:
                    raw += " "
                raw += self.advance().text
                any = True
            if not any:
                pm.start = self.last_end
                pm.end = self.last_end
            kids.append(self.ast.add(STR, self.close(pm), text=raw^))
        var id = self.ast.add(CLAUSE, self.close(m), op=op, text=label^, kids=kids^)
        self.expect_newline()
        return id

    # -- names, types and parameters ----------------------------------------

    def parse_qname_text(mut self, what: String) raises -> String:
        var name = self.expect_name(what).text.copy()
        while self.is_op(".") and self.peek_kind(1) == T_NAME:
            self.skip()
            name += "."
            name += self.advance().text
        return name^

    def parse_qname_node(mut self, what: String) raises -> Int:
        var m = self.mark()
        var name = self.parse_qname_text(what)
        return self.ast.add(QNAME, self.close(m), text=name^)

    def parse_name_node(mut self, what: String) raises -> Int:
        var m = self.mark()
        var name = self.expect_name(what).text.copy()
        return self.ast.add(NAME, self.close(m), text=name^)

    def parse_tparams(mut self) raises -> Int:
        if not self.is_op("<"):
            return self.empty_node(TPARAMS)
        var m = self.mark()
        self.skip()
        var items = List[Int]()
        while True:
            var tm = self.mark()
            var name = self.expect_name("a type parameter").text.copy()
            var kids = List[Int]()
            if self.accept_op(":"):
                kids.append(self.parse_qname_node("a bound (Eq or Ord)"))
            items.append(self.ast.add(TPARAM, self.close(tm), text=name^, kids=kids^))
            if not self.accept_op(","):
                break
        self.expect_gt()
        return self.ast.add(TPARAMS, self.close(m), kids=items^)

    def parse_params(mut self) raises -> Int:
        var m = self.mark()
        _ = self.expect_op("(", "'(' and the parameters")
        var saved = self.no_in
        self.no_in = False
        var items = List[Int]()
        if not self.is_op(")"):
            items.append(self.parse_param())
            while self.accept_op(","):
                items.append(self.parse_param())
        _ = self.expect_op(")", "',' or ')'")
        self.no_in = saved
        return self.ast.add(PARAMS, self.close(m), kids=items^)

    def parse_param(mut self) raises -> Int:
        var m = self.mark()
        var name = self.expect_name("a parameter name").text.copy()
        if name == "self" and not self.is_op(":"):
            return self.ast.add(PARAM, self.close(m), text=name^, kids=[NIL, NIL])
        _ = self.expect_op(":", "':' and the type of " + name)
        var type = self.parse_type()
        var default = NIL
        if self.accept_op("="):
            default = self.parse_expr()
        return self.ast.add(PARAM, self.close(m), text=name^, kids=[type, default])

    def parse_choice_alt(mut self) raises -> Int:
        var m = self.mark()
        if self.kind() == T_STRING:
            var value = self.advance().text.copy()
            return self.ast.add(STR, self.close(m), text=value^)
        if self.kind() == T_NAME:
            return self.parse_qname_node("a constant name")
        raise self.unexpected("a string literal or a constant name in the choice")

    def parse_type(mut self) raises -> Int:
        var m = self.mark()
        if self.kind() == T_STRING:
            var alts = List[Int]()
            alts.append(self.parse_choice_alt())
            while self.accept_op("|"):
                alts.append(self.parse_choice_alt())
            return self.ast.add(CHOICE_TYPE, self.close(m), kids=alts^)
        if self.is_op("("):
            self.skip()
            var saved = self.no_in
            self.no_in = False
            var items = List[Int]()
            items.append(self.parse_type())
            while self.accept_op(","):
                items.append(self.parse_type())
            _ = self.expect_op(")", "',' or ')'")
            self.no_in = saved
            if len(items) < 2:
                raise self.error_at(m, "a tuple type has at least two elements")
            return self.ast.add(TUPLE_TYPE, self.close(m), kids=items^)
        var name = self.parse_qname_text("a type")
        if self.is_op("<"):
            self.skip()
            var args = List[Int]()
            args.append(self.parse_type())
            while self.accept_op(","):
                args.append(self.parse_type())
            self.expect_gt()
            return self.ast.add(TYPE, self.close(m), text=name^, kids=args^)
        if self.is_op("|"):
            var alts = List[Int]()
            alts.append(self.ast.add(QNAME, self.close(m), text=name^))
            while self.accept_op("|"):
                alts.append(self.parse_choice_alt())
            return self.ast.add(CHOICE_TYPE, self.close(m), kids=alts^)
        return self.ast.add(TYPE, self.close(m), text=name^)

    # -- expressions ----------------------------------------------------------

    def parse_expr(mut self) raises -> Int:
        return self.parse_implies()

    def parse_implies(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_or()
        if self.is_kw("implies"):
            self.skip()
            var right = self.parse_implies()
            return self.ast.add(BINARY, self.close(m), op=IMPLIES, kids=[left, right])
        return left

    def parse_or(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_and()
        while self.is_kw("or"):
            self.skip()
            var right = self.parse_and()
            left = self.ast.add(BINARY, self.close(m), op=OR, kids=[left, right])
        return left

    def parse_and(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_not()
        while self.is_kw("and"):
            self.skip()
            var right = self.parse_not()
            left = self.ast.add(BINARY, self.close(m), op=AND, kids=[left, right])
        return left

    def parse_not(mut self) raises -> Int:
        var m = self.mark()
        if self.is_kw("not"):
            self.skip()
            var operand = self.parse_not()
            return self.ast.add(UNARY, self.close(m), op=NOT, kids=[operand])
        return self.parse_cmp()

    def cmp_op(self) -> UInt8:
        ref t = self.tokens[self.pos]
        if t.kind == T_NAME and t.text == "in":
            return NO_OP if self.no_in else IN
        if t.kind == T_OP:
            return _cmp_op(t.text)
        return NO_OP

    def parse_cmp(mut self) raises -> Int:
        var m = self.mark()
        var left = self.parse_level(0)
        var op = self.cmp_op()
        if op == NO_OP:
            return left
        var opname = self.advance().text.copy()
        var right = self.parse_level(0)
        var node = self.ast.add(BINARY, self.close(m), op=op, kids=[left, right])
        if self.cmp_op() != NO_OP:
            raise self.error(
                "comparisons do not chain: write 'a "
                + opname
                + " b and b "
                + String(self.ast.source[byte = self.tokens[self.pos].start : self.tokens[self.pos].end])
                + " c'"
            )
        return node

    def parse_level(mut self, level: Int) raises -> Int:
        if level == _LEVELS:
            return self.parse_unary()
        var m = self.mark()
        var left = self.parse_level(level + 1)
        while self.kind() == T_OP:
            var op = _level_op(level, self.tokens[self.pos].text)
            if op == NO_OP:
                break
            self.skip()
            var right = self.parse_level(level + 1)
            left = self.ast.add(BINARY, self.close(m), op=op, kids=[left, right])
        return left

    def parse_unary(mut self) raises -> Int:
        var m = self.mark()
        if self.is_op("-"):
            self.skip()
            var operand = self.parse_unary()
            return self.ast.add(UNARY, self.close(m), op=NEG, kids=[operand])
        if self.is_kw("let"):
            return self.parse_let()
        if self.is_kw("if"):
            return self.parse_if()
        var base = self.parse_post()
        if self.is_op("**"):
            self.skip()
            var exponent = self.parse_unary()
            return self.ast.add(BINARY, self.close(m), op=POW, kids=[base, exponent])
        return base

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
        return self.ast.add(LET, self.close(m), text=name^, kids=[value, body])

    def parse_if(mut self) raises -> Int:
        var m = self.mark()
        self.skip()
        var saved = self.no_in
        self.no_in = False
        var cond = self.parse_expr()
        self.no_in = saved
        if not self.is_kw("then"):
            raise self.unexpected("'then'")
        self.skip()
        self.no_in = False
        var then = self.parse_expr()
        self.no_in = saved
        if not self.is_kw("else"):
            raise self.unexpected("'else' (every if has an else branch)")
        self.skip()
        var other = self.parse_expr()
        return self.ast.add(IF, self.close(m), kids=[cond, then, other])

    def parse_post(mut self) raises -> Int:
        var m = self.mark()
        var node = self.parse_atom()
        while True:
            if self.is_op("("):
                node = self.parse_call(node, self.empty_node(TYPEARGS), m)
            elif self.is_op("."):
                self.skip()
                if self.kind() == T_NUMBER:
                    var t = self.advance()
                    if not _is_digits(t.text):
                        raise self.error_at(
                            t.span(), "a tuple field is a decimal index, e.g. p.0"
                        )
                    node = self.ast.add(TUPLE_INDEX, self.close(m), text=t.text.copy(), kids=[node])
                elif self.kind() == T_NAME:
                    var attr = self.advance().text.copy()
                    node = self.ast.add(ATTR, self.close(m), text=attr^, kids=[node])
                else:
                    raise self.unexpected("a field name or tuple index after '.'")
            elif self.is_op("["):
                self.skip()
                var saved = self.no_in
                self.no_in = False
                var first = self.parse_expr()
                var is_slice = False
                var stop = NIL
                if self.accept_op(":"):
                    is_slice = True
                    stop = self.parse_expr()
                _ = self.expect_op("]", "']'" if is_slice else "':' or ']'")
                self.no_in = saved
                if is_slice:
                    node = self.ast.add(SLICE, self.close(m), kids=[node, first, stop])
                else:
                    node = self.ast.add(INDEX, self.close(m), kids=[node, first])
            else:
                return node

    def parse_call(mut self, callee: Int, typeargs: Int, m: SrcSpan) raises -> Int:
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        var kids = List[Int]()
        kids.append(callee)
        kids.append(typeargs)
        var keywords = List[String]()
        if self.is_op(")"):
            self.skip()
        else:
            while True:
                var am = self.mark()
                if self.kind() == T_NAME and self.peek_is_op(1, "="):
                    var key = self.expect_name("an argument name")
                    self.skip()
                    for seen in keywords:
                        if seen == key.text:
                            raise self.error_at(
                                key.span(), "argument " + key.text + " is given twice"
                            )
                    keywords.append(key.text.copy())
                    var value = self.parse_expr()
                    kids.append(self.ast.add(ARG, self.close(am), text=key.text.copy(), kids=[value]))
                else:
                    if len(keywords) > 0:
                        raise self.error("positional arguments must come before named ones")
                    var value = self.parse_expr()
                    kids.append(self.ast.add(ARG, self.close(am), kids=[value]))
                if not self.accept_op(","):
                    break
            _ = self.expect_op(")", "',' or ')'")
        self.no_in = saved
        return self.ast.add(CALL, self.close(m), kids=kids^)

    def parse_atom(mut self) raises -> Int:
        var m = self.mark()
        var k = self.kind()
        if k == T_NUMBER:
            var text = self.advance().text.copy()
            return self.ast.add(NUM, self.close(m), text=text^)
        if k == T_STRING:
            var text = self.advance().text.copy()
            return self.ast.add(STR, self.close(m), text=text^)
        if k == T_NAME:
            var text = self.tokens[self.pos].text.copy()
            if text == "true" or text == "false":
                self.skip()
                return self.ast.add(
                    BOOL, self.close(m), op=TRUE if text == "true" else FALSE
                )
            if text == "none":
                self.skip()
                return self.ast.add(NONE, self.close(m))
            if (
                _comprehension_op(text) != NO_OP
                and self.peek_is_op(1, "(")
                and self.peek_kind(2) == T_NAME
                and self.peek_is_kw(3, "in")
            ):
                return self.parse_comprehension()
            if _is_reserved(text):
                raise self.unexpected("an expression")
            self.skip()
            var name = self.ast.add(NAME, self.close(m), text=text.copy())
            if _is_generic_fn(text) and self.is_op("<"):
                var tm = self.mark()
                self.skip()
                var args = List[Int]()
                args.append(self.parse_type())
                while self.accept_op(","):
                    args.append(self.parse_type())
                self.expect_gt()
                var typeargs = self.ast.add(TYPEARGS, self.close(tm), kids=args^)
                if not self.is_op("("):
                    raise self.unexpected(
                        "'(' and the arguments of " + text + "<...>"
                    )
                return self.parse_call(name, typeargs, m)
            return name
        if self.is_op("["):
            self.skip()
            var elems = self.parse_elems("]", True)
            return self.ast.add(LIST, self.close(m), kids=elems^)
        if self.is_op("{"):
            self.skip()
            var elems = self.parse_elems("}", True)
            return self.ast.add(SET, self.close(m), kids=elems^)
        if self.is_op("("):
            self.skip()
            var elems = self.parse_elems(")", False)
            if len(elems) == 1:
                return elems[0]
            return self.ast.add(TUPLE, self.close(m), kids=elems^)
        raise self.unexpected("an expression")

    def parse_elems(mut self, close: StaticString, allow_empty: Bool) raises -> List[Int]:
        var saved = self.no_in
        self.no_in = False
        var out = List[Int]()
        if self.is_op(close):
            if not allow_empty:
                raise self.unexpected("an expression")
            self.skip()
            self.no_in = saved
            return out^
        out.append(self.parse_expr())
        while self.accept_op(","):
            out.append(self.parse_expr())
        _ = self.expect_op(close, "',' or '" + String(close) + "'")
        self.no_in = saved
        return out^

    def parse_comprehension(mut self) raises -> Int:
        var m = self.mark()
        var word = self.advance().text.copy()
        var op = _comprehension_op(word)
        _ = self.expect_op("(")
        var saved = self.no_in
        self.no_in = False
        var var_name = self.expect_name("the comprehension variable").text.copy()
        self.expect_kw("in")
        var iterable = self.parse_expr()
        _ = self.expect_op(":", "':' and the body of " + word + "(...)")
        var body = self.parse_expr()
        _ = self.expect_op(")", "')'")
        self.no_in = saved
        return self.ast.add(
            COMPREHENSION, self.close(m), op=op, text=var_name^, kids=[iterable, body]
        )


def parse_spec(source: String, path: String) raises -> Ast:
    """Parse a spec file. On a syntax error raises an `Error` whose message is the
    diagnostic text `path:line:col: message`, for the first error."""
    var tokens = tokenize(source, path)
    var parser = Parser(tokens^, source.copy(), path.copy())
    _ = parser.parse_file()
    return parser^.into_ast()


def parse_prelude(source: String, path: String) raises -> Ast:
    """Parse a user prelude file: definitions and `use` lines, with no `spec` header."""
    var tokens = tokenize(source, path)
    var parser = Parser(tokens^, source.copy(), path.copy())
    _ = parser.parse_prelude_file()
    return parser^.into_ast()
