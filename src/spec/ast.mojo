"""Syntax tree of spec files and user preludes, stored flat.

Every node lives in `Ast.nodes` and is named by its index. Node 0 is `Empty`, which
stands for any absent optional part, so a node's children have fixed positions. A node
has a kind, an `op` (an operator, clause kind, comprehension kind or bool), a span, a
`text`, its children's indices and the index of its file.

Children by kind (`[...]` lists children in order; `text` is the node's text):

Files
  File            text spec name; [decl...]
  PreludeFile     [decl...]: Def and Use only

Declarations
  Use             text path
  Prelude         text path (`prelude "x.prelude"` attaches a user prelude)
  Error           text qualified name
  Const           text qualified name; [type]
  Enum            text name; [Name member...]
  Record          text name; [Param field...]
  Alias           text name; [type]
  Model           text qualified name; [TypeParams, member...]; members are Observe, Build,
                  Clause
  Interface       text qualified name; [TypeParams, member...]; members are Observe, Ctor,
                  Method, Clause
  Fn              text qualified name; [TypeParams, Params, return type or Empty, body...];
                  body items are Partition and Clause
  Ctor            text name; layout of Fn
  Method          text name; layout of Fn, Params starting with `self`
  Def             text name; [TypeParams, Params, return type, body expr]

Members and parts
  Observe         text name; [Params or Empty, type, expr or Empty]
  Build           text qualified callable; [Params]
  Partition       text parameter name; [Class...]
  Class           text class name; [expr]
  Clause          op clause kind; text label or ""; children by kind:
                    REQUIRES ENSURES RELATES INVARIANT AGGREGATE   [expr]
                    RAISES                                         [QualifiedName error, expr]
                    MAY_RAISE                                      [QualifiedName error, expr or Empty]
                    MODIFIES                                       [Name...]
                    UNSPECIFIED IMPL_DEFINED                       [Name]
                    PERF                                           [String the rest of the line]
  Params          [Param...]
  Param           text name; [type or Empty, default expr or Empty]; `self` has no type
  TypeParams      [TypeParam...]
  TypeParam       text name; [QualifiedName bound] or []
  QualifiedName   text dotted name

Types
  Type            text (qualified) name; [type argument...]
  TupleType       [element type...], at least two
  ChoiceType      [String or QualifiedName...]: `"any" | "all"`, `pkg.a | pkg.b`, or one String

Expressions
  Number          text the literal as written
  String          text the decoded string
  Bool            op TRUE or FALSE
  NoneLiteral
  Name            text identifier
  Unary           op NEG or NOT; [operand]
  Binary          op; [left, right]
  If              [condition, then, else]
  Let             text variable; [value, body]
  Comprehension   op ALL EXISTS COUNT SUM MAX MAP FILTER; text variable;
                  [iterable, body]
  Call            [callee, TypeArgs, Arg...]
  TypeArgs        [type...], empty unless `name<T>(...)`
  Arg             text keyword or ""; [expr]
  Attribute       text attribute; [value]
  TupleIndex      text digits; [value]
  Index           [value, index]
  Slice           [value, start, stop]
  List Set Tuple  [element...]
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
"""The index of the Empty node."""

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

    case Empty
    case File
    case PreludeFile
    case Use
    case Prelude
    case Error
    case Const
    case Enum
    case Record
    case Alias
    case Model
    case Interface
    case Fn
    case Ctor
    case Method
    case Def
    case Observe
    case Build
    case Partition
    case Class
    case Clause
    case Params
    case Param
    case TypeParams
    case TypeParam
    case QualifiedName
    case Type
    case TupleType
    case ChoiceType
    case Number
    case String
    case Bool
    case NoneLiteral
    case Name
    case Unary
    case Binary
    case If
    case Let
    case Comprehension
    case Call
    case TypeArgs
    case Arg
    case Attribute
    case TupleIndex
    case Index
    case Slice
    case List
    case Set
    case Tuple

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
    """Its File or PreludeFile node, or NIL until the parser sets it."""

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
        self.nodes = [Node(.Empty, .NO_OP, NO_SPAN, "", [], 0)]
        self.source = source^
        self.files = [File(path^, start=0, root=NIL)]

    def root(self) -> Int:
        """The first file's File or PreludeFile node."""
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
        """File or PreludeFile, for the file a node is in."""
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
