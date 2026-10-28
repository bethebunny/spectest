"""Syntax tree of spec files.

The parser builds these nodes; the checker fills in ``ty`` on expressions,
resolves clause IDs, and builds a ``Spec`` (see spectest.lang.checker).
Every node carries a ``Span`` so errors and verdicts can quote the source.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field, fields
from fractions import Fraction
from typing import Any

from spectest.types import Type


@dataclass(frozen=True)
class Span:
    line: int  # 1-based
    col: int  # 1-based
    end_line: int
    end_col: int

    def __str__(self) -> str:
        return f"{self.line}:{self.col}"


NO_SPAN = Span(0, 0, 0, 0)


@dataclass(eq=False)
class Node:
    """Base class: nodes compare by identity, so they can key dictionaries."""

    span: Span = field(default=NO_SPAN, kw_only=True)

    def children(self) -> Iterator[Node]:
        for f in fields(self):
            value = getattr(self, f.name)
            if isinstance(value, Node):
                yield value
            elif isinstance(value, (list, tuple)):
                for item in value:
                    if isinstance(item, Node):
                        yield item
                    elif isinstance(item, tuple):
                        yield from (x for x in item if isinstance(x, Node))


def walk(node: Node) -> Iterator[Node]:
    """Pre-order traversal of a node and all its descendants."""
    yield node
    for child in node.children():
        yield from walk(child)


# ---------------------------------------------------------------------------
# Type syntax


@dataclass(eq=False)
class TypeExpr(Node):
    """``name`` or ``name<args>``, e.g. ``f64``, ``list<T>``, ``Frame``."""

    name: str
    args: list[TypeExpr] = field(default_factory=list)


@dataclass(eq=False)
class TupleTypeExpr(Node):
    elems: list[TypeExpr | TupleTypeExpr | LiteralTypeExpr]


@dataclass(eq=False)
class LiteralTypeExpr(Node):
    """``"any" | "all"``."""

    values: list[str]


AnyTypeExpr = TypeExpr | TupleTypeExpr | LiteralTypeExpr


# ---------------------------------------------------------------------------
# Expressions. The checker sets ``ty`` on every expression it accepts.


@dataclass(eq=False)
class Expr(Node):
    ty: Type | None = field(default=None, kw_only=True, compare=False)


@dataclass(eq=False)
class Num(Expr):
    """A numeric literal. Integers are ints, others exact Fractions (hex floats included)."""

    value: int | Fraction
    text: str


@dataclass(eq=False)
class Str(Expr):
    value: str


@dataclass(eq=False)
class BoolLit(Expr):
    value: bool


@dataclass(eq=False)
class NoneLit(Expr):
    pass


@dataclass(eq=False)
class Name(Expr):
    """An identifier: a parameter, ``result``, ``self``, a let/comprehension
    variable, a model field inside a model or interface, or a prelude name."""

    id: str


@dataclass(eq=False)
class Unary(Expr):
    op: str  # "-" or "not"
    operand: Expr


@dataclass(eq=False)
class Binary(Expr):
    # implies or and == != < <= > >= in | & + - * / // %
    op: str
    left: Expr
    right: Expr


@dataclass(eq=False)
class If(Expr):
    cond: Expr
    then: Expr
    else_: Expr


@dataclass(eq=False)
class Let(Expr):
    name: str
    value: Expr
    body: Expr


@dataclass(eq=False)
class Comprehension(Expr):
    kind: str  # all exists count sum max map filter
    var: str
    iterable: Expr
    body: Expr


@dataclass(eq=False)
class Call(Expr):
    """``func(args, name=kwarg)``; ``func<T>(...)`` for generic prelude functions.

    ``func`` is a Name (``cos``, ``len``, ``old``), or an Attribute
    (``mp.cos``, ``f64.range``, ``df.cell``).
    """

    func: Expr
    args: list[Expr] = field(default_factory=list)
    kwargs: list[tuple[str, Expr]] = field(default_factory=list)
    type_args: list[AnyTypeExpr] = field(default_factory=list)


@dataclass(eq=False)
class Attribute(Expr):
    """``value.attr``: an observer, a record field, ``f64.nan``, ``i32.max``, ``mp.cos``."""

    value: Expr
    attr: str


@dataclass(eq=False)
class TupleIndex(Expr):
    """``value.0``."""

    value: Expr
    index: int


@dataclass(eq=False)
class Index(Expr):
    value: Expr
    index: Expr


@dataclass(eq=False)
class Slice(Expr):
    value: Expr
    start: Expr
    stop: Expr


@dataclass(eq=False)
class ListLit(Expr):
    elems: list[Expr]


@dataclass(eq=False)
class SetLit(Expr):
    """``{v, ...}``: an explicit set of values (partition classes)."""

    elems: list[Expr]


@dataclass(eq=False)
class TupleLit(Expr):
    elems: list[Expr]


# ---------------------------------------------------------------------------
# Declarations


@dataclass(eq=False)
class Param(Node):
    name: str
    type: AnyTypeExpr
    default: Expr | None = None


@dataclass(eq=False)
class TypeParam(Node):
    name: str
    bound: str | None = None  # "Eq" | "Ord" | None


# Clause kinds. ``expr`` holds the condition for requires/ensures/relates/
# invariant/aggregate, and the ``when`` condition (or None) for raises/may_raise.
CLAUSE_KINDS = (
    "requires",
    "ensures",
    "raises",
    "may_raise",
    "modifies",
    "relates",
    "invariant",
    "aggregate",
    "unspecified",
    "impl_defined",
    "perf",
)


@dataclass(eq=False)
class Clause(Node):
    kind: str  # one of CLAUSE_KINDS
    label: str | None = None  # the written ID, if any
    expr: Expr | None = None
    error: str | None = None  # raises / may_raise: the error name
    names: list[str] = field(default_factory=list)  # modifies: parameter names
    freedom: str | None = None  # unspecified / impl_defined: the freedom's name
    text: str = ""  # the clause's source text, verbatim
    id: str = ""  # resolved by the checker: "<decl>.<label>" or "<decl>#<n>"


@dataclass(eq=False)
class PartitionClass(Node):
    name: str
    expr: Expr


@dataclass(eq=False)
class Partition(Node):
    param: str
    classes: list[PartitionClass]


@dataclass(eq=False)
class Observe(Node):
    name: str
    params: list[Param]
    type: AnyTypeExpr


@dataclass(eq=False)
class Callable_(Node):
    """Shared shape of functions, constructors and methods."""

    name: str
    params: list[Param]
    returns: AnyTypeExpr | None
    partitions: list[Partition] = field(default_factory=list)
    clauses: list[Clause] = field(default_factory=list)


@dataclass(eq=False)
class FnDecl(Callable_):
    tparams: list[TypeParam] = field(default_factory=list)


@dataclass(eq=False)
class CtorDecl(Callable_):
    """``new name(params) -> Self``."""


@dataclass(eq=False)
class MethodDecl(Callable_):
    """``method name(self, params) -> T``; ``params`` excludes self."""


@dataclass(eq=False)
class ModelDecl(Node):
    name: str
    tparams: list[TypeParam]
    observers: list[Observe]
    clauses: list[Clause]  # invariants and freedoms


@dataclass(eq=False)
class InterfaceDecl(Node):
    name: str
    tparams: list[TypeParam]
    observers: list[Observe]
    ctors: list[CtorDecl]
    methods: list[MethodDecl]
    clauses: list[Clause]  # invariants and freedoms


@dataclass(eq=False)
class ErrorDecl(Node):
    name: str


@dataclass(eq=False)
class EnumDecl(Node):
    name: str
    members: list[str]


@dataclass(eq=False)
class RecordDecl(Node):
    name: str
    fields: list[Param]


@dataclass(eq=False)
class AliasDecl(Node):
    name: str
    type: AnyTypeExpr


@dataclass(eq=False)
class UseDecl(Node):
    path: str


Decl = (
    FnDecl | ModelDecl | InterfaceDecl | ErrorDecl | EnumDecl | RecordDecl | AliasDecl | UseDecl
)


@dataclass(eq=False)
class SpecFile(Node):
    name: str
    decls: list[Any]  # list[Decl]
    path: str = ""
    source: str = ""
