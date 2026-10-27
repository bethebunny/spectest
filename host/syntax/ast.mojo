"""Syntax tree of spec files and user preludes, stored flat.

Every node lives in `Ast.nodes` and is named by its index. Node 0 is `EMPTY`, which
stands for any absent optional part, so a node's children have fixed positions. A node
has a kind, an `op` (an operator, clause kind, comprehension kind or bool), a span, a
`text`, its children's indices and the index of its file.

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


struct Span(Equatable, TrivialRegisterPassable, Writable):
    var start: Int
    """Byte offset of the first byte."""
    var end: Int
    """Byte offset past the last byte."""
    var line: Int
    """1-based line of `start`."""
    var column: Int
    """1-based column of `start`, in code points."""

    def __init__(out self, *, start: Int, end: Int, line: Int, column: Int):
        self.start = start
        self.end = end
        self.line = line
        self.column = column

    def __eq__(self, other: Self) -> Bool:
        return self.start == other.start and self.end == other.end

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.line, ":", self.column)


comptime NO_SPAN = Span(start=0, end=0, line=0, column=0)

comptime NIL = 0
"""The index of the EMPTY node."""

comptime _KIND_NAMES: Array[StaticString, 49] = [
    "empty", "file", "prelude_file", "use", "prelude", "error", "const", "enum", "record",
    "alias", "model", "interface", "fn", "ctor", "method", "def", "observe", "build",
    "partition", "class", "clause", "params", "param", "tparams", "tparam", "qname", "type",
    "tuple_type", "choice_type", "num", "str", "bool", "none", "name", "unary", "binary", "if",
    "let", "comprehension", "call", "typeargs", "arg", "attr", "tuple_index", "index", "slice",
    "list", "set", "tuple",
]


__enum NodeKind(Equatable, ImplicitlyCopyable, Intable, Writable):
    """A node's kind. Writes as its lowercase name, eg. `tuple_index`."""

    case EMPTY
    case FILE
    case PRELUDE_FILE
    case USE
    case PRELUDE
    case ERROR
    case CONST
    case ENUM
    case RECORD
    case ALIAS
    case MODEL
    case INTERFACE
    case FN
    case CTOR
    case METHOD
    case DEF
    case OBSERVE
    case BUILD
    case PARTITION
    case CLASS
    case CLAUSE
    case PARAMS
    case PARAM
    case TPARAMS
    case TPARAM
    case QNAME
    case TYPE
    case TUPLE_TYPE
    case CHOICE_TYPE
    case NUM
    case STR
    case BOOL
    case NONE
    case NAME
    case UNARY
    case BINARY
    case IF
    case LET
    case COMPREHENSION
    case CALL
    case TYPEARGS
    case ARG
    case ATTR
    case TUPLE_INDEX
    case INDEX
    case SLICE
    case LIST
    case SET
    case TUPLE

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()

    def __int__(self) -> Int:
        return Int(self._get_enum_discriminant())

    def write_to(self, mut writer: Some[Writer]):
        writer.write(materialize[_KIND_NAMES]()[Int(self)])


comptime _OP_NAMES: Array[StaticString, 44] = [
    "-", "implies", "or", "and", "==", "!=", "<", "<=", ">", ">=", "in", "|", "&", "<<", ">>",
    "+", "-", "*", "/", "//", "%", "**", "neg", "not", "requires", "ensures", "raises",
    "may_raise", "modifies", "relates", "invariant", "aggregate", "unspecified", "impl_defined",
    "perf", "all", "exists", "count", "sum", "max", "map", "filter", "false", "true",
]


@fieldwise_init
struct Op(Comparable, Intable, TrivialRegisterPassable, Writable):
    """A node's `op`: an operator, clause kind, comprehension kind or bool. Writes as its name.

    One numbering covers every use, so a dump names each op without its node. The ops of
    each use are consecutive, and binary operators come lowest precedence first.
    """

    var code: UInt8

    comptime NO_OP = Self(0)
    # Binary operators.
    comptime IMPLIES = Self(1)
    comptime OR = Self(2)
    comptime AND = Self(3)
    comptime EQ = Self(4)
    comptime NE = Self(5)
    comptime LT = Self(6)
    comptime LE = Self(7)
    comptime GT = Self(8)
    comptime GE = Self(9)
    comptime IN = Self(10)
    comptime BITOR = Self(11)
    comptime BITAND = Self(12)
    comptime SHL = Self(13)
    comptime SHR = Self(14)
    comptime ADD = Self(15)
    comptime SUB = Self(16)
    comptime MUL = Self(17)
    comptime DIV = Self(18)
    comptime FLOORDIV = Self(19)
    comptime MOD = Self(20)
    comptime POW = Self(21)
    # Unary operators.
    comptime NEG = Self(22)
    comptime NOT = Self(23)
    # Clause kinds.
    comptime REQUIRES = Self(24)
    comptime ENSURES = Self(25)
    comptime RAISES = Self(26)
    comptime MAY_RAISE = Self(27)
    comptime MODIFIES = Self(28)
    comptime RELATES = Self(29)
    comptime INVARIANT = Self(30)
    comptime AGGREGATE = Self(31)
    comptime UNSPECIFIED = Self(32)
    comptime IMPL_DEFINED = Self(33)
    comptime PERF = Self(34)
    # Comprehension kinds.
    comptime ALL = Self(35)
    comptime EXISTS = Self(36)
    comptime COUNT = Self(37)
    comptime SUM = Self(38)
    comptime MAX = Self(39)
    comptime MAP = Self(40)
    comptime FILTER = Self(41)
    # Bools.
    comptime FALSE = Self(42)
    comptime TRUE = Self(43)

    @staticmethod
    def named(text: StringSlice, *, first: Self, last: Self) -> Self:
        """The op from `first` to `last` named `text`, or NO_OP."""
        var names = materialize[_OP_NAMES]()
        for code in range(Int(first.code), Int(last.code) + 1):
            if names[code] == text:
                return Self(UInt8(code))
        return Self.NO_OP

    def __lt__(self, other: Self) -> Bool:
        return self.code < other.code

    def __int__(self) -> Int:
        return Int(self.code)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(materialize[_OP_NAMES]()[Int(self)])


@fieldwise_init
struct Node(Copyable):
    var kind: NodeKind
    var op: Op
    var span: Span
    var text: String
    var children: List[Int]
    var file: Int
    """The index in `Ast.files` of the file the node is in."""


struct File(Copyable):
    """A file of the tree. Its text follows the previous file's in `Ast.source`."""

    var path: String
    var start: Int
    """Where its text starts in `Ast.source`."""
    var root: Int
    """Its FILE or PRELUDE_FILE node, or NIL until the parser sets it."""

    def __init__(out self, var path: String, *, start: Int, root: Int):
        self.path = path^
        self.start = start
        self.root = root


struct Ast(Movable):
    var nodes: List[Node]
    var source: String
    """The text of every file, one after another; spans are byte offsets into it."""
    var files: List[File]
    """The first file is `files[0]`; `parse_into` adds the others."""

    def __init__(out self, var source: String, var path: String):
        self.nodes = [Node(.EMPTY, .NO_OP, NO_SPAN, "", [], 0)]
        self.source = source^
        self.files = [File(path^, start=0, root=NIL)]

    def root(self) -> Int:
        """The first file's FILE or PRELUDE_FILE node."""
        return self.files[0].root

    def add(
        mut self,
        kind: NodeKind,
        span: Span,
        *,
        op: Op = .NO_OP,
        var text: String = "",
        var children: List[Int] = [],
    ) -> Int:
        """A new node in the last file."""
        self.nodes.append(Node(kind, op, span, text^, children^, len(self.files) - 1))
        return len(self.nodes) - 1

    def node(self, id: Int) -> ref [self.nodes[0]] Node:
        return self.nodes[id]

    def child(self, id: Int, k: Int) -> Int:
        return self.nodes[id].children[k]

    def subtree(self, id: Int) -> List[Int]:
        """`id` and every node below it, ascending; each absent part adds a NIL."""
        var found: List[Int] = []
        var stack: List[Int] = [id]
        while stack:
            var n = stack.pop()
            found.append(n)
            stack.extend(self.nodes[n].children.copy())
        sort(found)
        return found^

    def path_of(self, id: Int) -> String:
        return self.files[self.nodes[id].file].path.copy()

    def kind_of_file(self, id: Int) -> NodeKind:
        """FILE or PRELUDE_FILE, for the file a node is in."""
        return self.nodes[self.files[self.nodes[id].file].root].kind

    def location(self, id: Int) -> String:
        """`path:line:column` of a node, in its own file."""
        return String(self.path_of(id), ":", self.nodes[id].span)

    def diagnostic(self, id: Int, message: Some[Writable]) -> Diagnostic:
        return Diagnostic(self.path_of(id), self.nodes[id].span, String(message))

    def source_text(self, id: Int) -> String:
        """The node's source, verbatim."""
        ref span = self.nodes[id].span
        return String(self.source[byte = span.start : span.end])


@fieldwise_init
struct Diagnostic(Copyable, Writable):
    """An error in a spec, located in its source. Writes as `path:line:column: message`."""

    var path: String
    var span: Span
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.path, ":", self.span, ": ", self.message)
