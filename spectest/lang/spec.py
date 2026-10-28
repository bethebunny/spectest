"""The checked form of a spec file: ``Spec``, ``Resolution`` and ``Diagnostic``.

``check`` (spectest.lang.checker) builds a ``Spec``; every later stage (sets,
generation, evaluation, the runtime) reads it and never re-derives names or
types.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from spectest import ast
from spectest.ast import NO_SPAN, Span
from spectest.types import EnumT, FnT, ModelT, RecordT, Type, TypeVarT

RESOLUTION_KINDS = (
    "param",  # name: parameter name; detail: its index in the callable's params
    "result",  # the return value (in a constructor: the new handle)
    "self",  # the handle of a method, or of an interface/model inside its invariants
    "local",  # let / comprehension variable; detail: the binding Let or Comprehension node
    "field",  # bare zero-arg observer inside an invariant (or a bare observer call); detail: model name
    "prelude",  # prelude function; name: "len", "mp.cos", "wrap", ...
    "type_const",  # i32.max, f64.nan, f64.all, ...; name: the attribute; detail: the scalar Type
    "set_ctor",  # f64.range(a, b), u8.pattern("..."); name: "range" | "pattern"; detail: scalar Type
    "spec_fn",  # call of a spec function (only in relates); detail: the FnDecl
    "observer",  # df.rows, df.cell(i, n); name: observer name; detail: model or interface name
    "record_field",  # r.f on a record value; detail: the record name
    "old",  # old(e)
    "error",  # a raises / may_raise clause's error (keyed by the Clause); name: the error
    "class",  # reference to an earlier partition class; detail: the PartitionClass node
    "enum_member",  # Color.Red or a bare member name; name: member; detail: enum name
)


@dataclass(frozen=True)
class Resolution:
    """What a Name, Call or Attribute refers to (see RESOLUTION_KINDS)."""

    kind: str
    name: str
    detail: Any = None


@dataclass(frozen=True)
class Diagnostic:
    """One error or warning with its location and a source excerpt."""

    path: str
    span: Span
    message: str
    excerpt: str = ""
    severity: str = "error"  # or "warning"

    @classmethod
    def at(
        cls, path: str, source: str, span: Span, message: str, severity: str = "error"
    ) -> Diagnostic:
        return cls(path, span, message, excerpt(source, span), severity)

    @classmethod
    def coerce(cls, d: Any, path: str, source: str) -> Diagnostic:
        """A Diagnostic from any object with ``span`` and ``message`` (and maybe
        ``severity``, ``path``, ``excerpt``), with the excerpt filled in."""
        span = getattr(d, "span", NO_SPAN) or NO_SPAN
        return cls(
            getattr(d, "path", "") or path,
            span,
            str(getattr(d, "message", d)),
            getattr(d, "excerpt", "") or excerpt(source, span),
            getattr(d, "severity", "error") or "error",
        )

    def with_source(self, source: str, path: str | None = None) -> Diagnostic:
        """Fill in a missing excerpt (and path) from the spec source."""
        return Diagnostic(
            self.path or (path or ""),
            self.span,
            self.message,
            self.excerpt or excerpt(source, self.span),
            self.severity,
        )

    @property
    def location(self) -> str:
        return f"{self.path or '<string>'}:{self.span.line}:{self.span.col}"

    def __str__(self) -> str:
        head = f"{self.location}: {self.severity}: {self.message}"
        return f"{head}\n{self.excerpt}" if self.excerpt else head


def excerpt(source: str, span: Span) -> str:
    """The span's first source line with a caret line under the spanned columns."""
    lines = source.split("\n")
    if span.line < 1 or span.line > len(lines):
        return ""
    text = lines[span.line - 1].rstrip("\r")
    start = max(span.col, 1)
    if span.end_line == span.line and span.end_col > start:
        stop = span.end_col
    else:
        stop = max(len(text) + 1, start + 1)
    number = str(span.line)
    gutter = " " * len(number)
    carets = " " * (start - 1) + "^" * (stop - start)
    return f" {number} | {text}\n {gutter} | {carets}"


@dataclass(eq=False)
class Spec:
    """A checked spec file.

    ``fns`` holds this file's functions only; models, interfaces, errors, enums,
    records and aliases include those of used files, as do ``signature``,
    ``tparams``, ``resolution``, ``owner`` and ``decl_ids``. ``clause_ids``
    holds this file's clauses and the model and interface clauses of used
    files. ``owner`` maps clauses, partitions, classes, observers,
    constructors and methods to their declaration; ``decl_ids`` maps a
    declaration to the prefix of its clause IDs ("cos", "Deque.pop").
    ``warnings`` collects non-fatal diagnostics of the partition checks.
    """

    name: str
    path: str
    source: str
    hash: str
    file: ast.SpecFile
    fns: dict[str, ast.FnDecl] = field(default_factory=dict)
    models: dict[str, ast.ModelDecl] = field(default_factory=dict)
    interfaces: dict[str, ast.InterfaceDecl] = field(default_factory=dict)
    errors: set[str] = field(default_factory=set)
    enums: dict[str, EnumT] = field(default_factory=dict)
    records: dict[str, RecordT] = field(default_factory=dict)
    aliases: dict[str, Type] = field(default_factory=dict)
    signature: dict[ast.Node, FnT] = field(default_factory=dict)
    tparams: dict[ast.Node, dict[str, TypeVarT]] = field(default_factory=dict)
    resolution: dict[ast.Node, Resolution] = field(default_factory=dict)
    clause_ids: dict[str, ast.Clause] = field(default_factory=dict)
    owner: dict[ast.Node, ast.Node] = field(default_factory=dict)
    decl_ids: dict[ast.Node, str] = field(default_factory=dict)
    uses: list[Spec] = field(default_factory=list)
    warnings: list[Diagnostic] = field(default_factory=list)

    def resolve_type(
        self, texpr: ast.AnyTypeExpr | str, tvars: dict[str, TypeVarT] | None = None
    ) -> Type:
        """Resolve type syntax (or a type written as text, e.g. "list<i64>") in this spec."""
        from spectest.lang.checker import resolve_type

        return resolve_type(self, texpr, tvars)

    def decl(self, name: str) -> ast.Node | None:
        """A function, model or interface by name."""
        return self.fns.get(name) or self.models.get(name) or self.interfaces.get(name)

    def observers(self, model: str) -> dict[str, ast.Observe]:
        """Observers of a model or interface, in declaration order."""
        decl = self.models.get(model) or self.interfaces.get(model)
        if decl is None:
            raise KeyError(model)
        return {o.name: o for o in decl.observers}

    def fields(self, model: str) -> list[ast.Observe]:
        """The zero-argument observers of a model or interface (its fields), in order."""
        return [o for o in self.observers(model).values() if not o.params]

    def model_type(self, name: str) -> ModelT:
        """The handle type of a model or interface, over its own type parameters."""
        decl = self.models.get(name) or self.interfaces.get(name)
        if decl is None:
            raise KeyError(name)
        tvars = self.tparams.get(decl, {})
        return ModelT(name, tuple(tvars.values()), isinstance(decl, ast.InterfaceDecl))

    def clauses_of(self, decl: ast.Node) -> list[ast.Clause]:
        return list(getattr(decl, "clauses", []))

    def location(self, node: ast.Node) -> str:
        return f"{self.path}:{node.span.line}:{node.span.col}"


__all__ = ["NO_SPAN", "RESOLUTION_KINDS", "Diagnostic", "Resolution", "Spec", "excerpt"]
