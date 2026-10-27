"""Syntax tree of spec files and user preludes, stored flat.

Every node lives in `Ast.nodes` and is named by its index. Node 0 is `EMPTY`, which
stands for any absent optional part, so a node's children have fixed positions. A node
has a kind, an `op` (an operator, clause kind, comprehension kind or bool), a span, a
`text` and its children's indices.

Children by kind (`[...]` lists children in order; `text` is the node's text):

Files
  FILE            text spec name; [decl...]
  PRELUDE_FILE    [decl...]: DEF and USE only

Declarations
  USE             text path
  PRELUDE         text path (`prelude "x.prelude"` attaches a user prelude)
  ERROR           text qualified name
  CONST           text qualified name; [type]
  ENUM            text name; [NAME member...]
  RECORD          text name; [PARAM field...]
  ALIAS           text name; [type]
  MODEL           text qualified name; [TPARAMS, member...]; members are OBSERVE, BUILD,
                  CLAUSE
  INTERFACE       text qualified name; [TPARAMS, member...]; members are OBSERVE, CTOR,
                  METHOD, CLAUSE
  FN              text qualified name; [TPARAMS, PARAMS, return type or EMPTY, body...];
                  body items are PARTITION and CLAUSE
  CTOR            text name; layout of FN
  METHOD          text name; layout of FN, PARAMS starting with `self`
  DEF             text name; [TPARAMS, PARAMS, return type, body expr]

Members and parts
  OBSERVE         text name; [PARAMS or EMPTY, type, expr or EMPTY]
  BUILD           text qualified callable; [PARAMS]
  PARTITION       text parameter name; [CLASS...]
  CLASS           text class name; [expr]
  CLAUSE          op clause kind; text label or ""; children by kind:
                    REQUIRES ENSURES RELATES INVARIANT AGGREGATE   [expr]
                    RAISES                                         [QNAME error, expr]
                    MAY_RAISE                                      [QNAME error, expr or EMPTY]
                    MODIFIES                                       [NAME...]
                    UNSPECIFIED IMPL_DEFINED                       [NAME]
                    PERF                                           [STR the rest of the line]
  PARAMS          [PARAM...]
  PARAM           text name; [type or EMPTY, default expr or EMPTY]; `self` has no type
  TPARAMS         [TPARAM...]
  TPARAM          text name; [QNAME bound] or []
  QNAME           text dotted name

Types
  TYPE            text (qualified) name; [type argument...]
  TUPLE_TYPE      [element type...], at least two
  CHOICE_TYPE     [STR or QNAME...]: `"any" | "all"`, `pkg.a | pkg.b`, or one STR

Expressions
  NUM             text the literal as written
  STR             text the decoded string
  BOOL            op TRUE or FALSE
  NONE
  NAME            text identifier
  UNARY           op NEG or NOT; [operand]
  BINARY          op; [left, right]
  IF              [condition, then, else]
  LET             text variable; [value, body]
  COMPREHENSION   op ALL EXISTS COUNT SUM MAX MAP FILTER; text variable;
                  [iterable, body]
  CALL            [callee, TYPEARGS, ARG...]
  TYPEARGS        [type...], empty unless `name<T>(...)`
  ARG             text keyword or ""; [expr]
  ATTR            text attribute; [value]
  TUPLE_INDEX     text digits; [value]
  INDEX           [value, index]
  SLICE           [value, start, stop]
  LIST SET TUPLE  [element...]
"""

from std.hash import Hasher


@fieldwise_init
struct Span(Equatable, TrivialRegisterPassable, Writable):
    var start: Int
    """Byte offset of the first byte."""
    var end: Int
    """Byte offset past the last byte."""
    var line: Int
    """1-based line of `start`."""
    var col: Int
    """1-based column of `start`, in code points."""

    def __eq__(self, other: Self) -> Bool:
        return self.start == other.start and self.end == other.end

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.line, ":", self.col)


comptime NO_SPAN = Span(0, 0, 0, 0)


# Node kinds.
comptime EMPTY: UInt8 = 0
comptime FILE: UInt8 = 1
comptime PRELUDE_FILE: UInt8 = 2
comptime USE: UInt8 = 3
comptime PRELUDE: UInt8 = 4
comptime ERROR: UInt8 = 5
comptime CONST: UInt8 = 6
comptime ENUM: UInt8 = 7
comptime RECORD: UInt8 = 8
comptime ALIAS: UInt8 = 9
comptime MODEL: UInt8 = 10
comptime INTERFACE: UInt8 = 11
comptime FN: UInt8 = 12
comptime CTOR: UInt8 = 13
comptime METHOD: UInt8 = 14
comptime DEF: UInt8 = 15
comptime OBSERVE: UInt8 = 16
comptime BUILD: UInt8 = 17
comptime PARTITION: UInt8 = 18
comptime CLASS: UInt8 = 19
comptime CLAUSE: UInt8 = 20
comptime PARAMS: UInt8 = 21
comptime PARAM: UInt8 = 22
comptime TPARAMS: UInt8 = 23
comptime TPARAM: UInt8 = 24
comptime QNAME: UInt8 = 25
comptime TYPE: UInt8 = 26
comptime TUPLE_TYPE: UInt8 = 27
comptime CHOICE_TYPE: UInt8 = 28
comptime NUM: UInt8 = 29
comptime STR: UInt8 = 30
comptime BOOL: UInt8 = 31
comptime NONE: UInt8 = 32
comptime NAME: UInt8 = 33
comptime UNARY: UInt8 = 34
comptime BINARY: UInt8 = 35
comptime IF: UInt8 = 36
comptime LET: UInt8 = 37
comptime COMPREHENSION: UInt8 = 38
comptime CALL: UInt8 = 39
comptime TYPEARGS: UInt8 = 40
comptime ARG: UInt8 = 41
comptime ATTR: UInt8 = 42
comptime TUPLE_INDEX: UInt8 = 43
comptime INDEX: UInt8 = 44
comptime SLICE: UInt8 = 45
comptime LIST: UInt8 = 46
comptime SET: UInt8 = 47
comptime TUPLE: UInt8 = 48

comptime _KIND_NAMES = (
    "empty file prelude_file use prelude error const enum record alias model"
    " interface fn ctor method def observe build partition class clause params"
    " param tparams tparam qname type tuple_type choice_type num str bool none name"
    " unary binary if let comprehension call typeargs arg attr tuple_index index"
    " slice list set tuple"
)

# Ops. One numbering for every use of `op`, so a dump names each without its node.
comptime NO_OP: UInt8 = 0
# Binary operators, lowest precedence first.
comptime IMPLIES: UInt8 = 1
comptime OR: UInt8 = 2
comptime AND: UInt8 = 3
comptime EQ: UInt8 = 4
comptime NE: UInt8 = 5
comptime LT: UInt8 = 6
comptime LE: UInt8 = 7
comptime GT: UInt8 = 8
comptime GE: UInt8 = 9
comptime IN: UInt8 = 10
comptime BITOR: UInt8 = 11
comptime BITAND: UInt8 = 12
comptime SHL: UInt8 = 13
comptime SHR: UInt8 = 14
comptime ADD: UInt8 = 15
comptime SUB: UInt8 = 16
comptime MUL: UInt8 = 17
comptime DIV: UInt8 = 18
comptime FLOORDIV: UInt8 = 19
comptime MOD: UInt8 = 20
comptime POW: UInt8 = 21
# Unary operators.
comptime NEG: UInt8 = 22
comptime NOT: UInt8 = 23
# Clause kinds.
comptime REQUIRES: UInt8 = 24
comptime ENSURES: UInt8 = 25
comptime RAISES: UInt8 = 26
comptime MAY_RAISE: UInt8 = 27
comptime MODIFIES: UInt8 = 28
comptime RELATES: UInt8 = 29
comptime INVARIANT: UInt8 = 30
comptime AGGREGATE: UInt8 = 31
comptime UNSPECIFIED: UInt8 = 32
comptime IMPL_DEFINED: UInt8 = 33
comptime PERF: UInt8 = 34
# Comprehension kinds.
comptime ALL: UInt8 = 35
comptime EXISTS: UInt8 = 36
comptime COUNT: UInt8 = 37
comptime SUM: UInt8 = 38
comptime MAX: UInt8 = 39
comptime MAP: UInt8 = 40
comptime FILTER: UInt8 = 41
# Bools.
comptime FALSE: UInt8 = 42
comptime TRUE: UInt8 = 43

comptime _OP_NAMES = (
    "- implies or and == != < <= > >= in | & << >> + - * / // % ** neg not"
    " requires ensures raises may_raise modifies relates invariant aggregate"
    " unspecified impl_defined perf all exists count sum max map filter false true"
)


def _nth_word(words: StaticString, n: Int) -> StaticString:
    var k = 0
    for word in words.split(" "):
        if k == n:
            return word
        k += 1
    return "?"


def kind_name(kind: UInt8) -> StaticString:
    return _nth_word(_KIND_NAMES, Int(kind))


def op_name(op: UInt8) -> StaticString:
    return _nth_word(_OP_NAMES, Int(op))


@fieldwise_init
struct Node(Copyable, Movable):
    var kind: UInt8
    var op: UInt8
    var span: Span
    var text: String
    var kids: List[Int]


@fieldwise_init
struct SourceFile(Copyable, Movable):
    """One file of a tree: `parse_into` appends each file's source to `Ast.source` and
    its nodes to `Ast.nodes`."""

    var path: String
    var source: String
    """The file's own text."""
    var offset: Int
    """Where the text starts in `Ast.source`."""
    var first_node: Int
    """The file's first node; its nodes run up to the next file's first node."""
    var root: Int
    """The FILE or PRELUDE_FILE node; 0 until the parser sets it."""


struct Ast(Movable):
    var nodes: List[Node]
    var source: String
    """The text of every file, one after another; spans are byte offsets into it."""
    var path: String
    """The path of the first file."""
    var root: Int
    """The first file's FILE or PRELUDE_FILE node; 0 until the parser sets it."""
    var files: List[SourceFile]
    """The first file is `files[0]`; `parse_into` adds the others."""

    def __init__(out self, var source: String, var path: String):
        self.nodes = List[Node]()
        self.source = source^
        self.path = path^
        self.root = 0
        self.files = List[SourceFile]()
        self.files.append(SourceFile(self.path.copy(), self.source.copy(), 0, 1, 0))
        self.nodes.append(Node(EMPTY, NO_OP, NO_SPAN, String(), List[Int]()))

    def add(
        mut self,
        kind: UInt8,
        span: Span,
        *,
        op: UInt8 = NO_OP,
        var text: String = String(),
        var kids: List[Int] = List[Int](),
    ) -> Int:
        self.nodes.append(Node(kind, op, span, text^, kids^))
        return len(self.nodes) - 1

    def node(self, id: Int) -> ref [self.nodes[0]] Node:
        return self.nodes[id]

    def kid(self, id: Int, k: Int) -> Int:
        return self.nodes[id].kids[k]

    def file_of(self, id: Int) -> Int:
        """The index in `files` of the file a node belongs to; node 0 belongs to the
        first."""
        var i = len(self.files) - 1
        while i > 0:
            if id >= self.files[i].first_node:
                return i
            i -= 1
        return 0

    def path_of(self, id: Int) -> String:
        """The path of the file a node belongs to."""
        return self.files[self.file_of(id)].path.copy()

    def kind_of_file(self, id: Int) -> UInt8:
        """FILE or PRELUDE_FILE: the kind of file a node belongs to."""
        return self.nodes[self.files[self.file_of(id)].root].kind

    def location(self, id: Int) -> String:
        """`path:line:col` of a node, in its own file."""
        return String(self.path_of(id), ":", self.nodes[id].span)

    def source_text(self, id: Int) -> String:
        """The node's source, verbatim: what a verdict quotes."""
        ref span = self.nodes[id].span
        return String(self.source[byte = span.start : span.end])


@fieldwise_init
struct Diagnostic(Copyable, Movable, Writable):
    """An error in a spec, located in its source. Writes as `path:line:col: message`."""

    var path: String
    var span: Span
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.path, ":", self.span, ": ", self.message)
