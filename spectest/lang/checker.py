"""Static checking: ``check(file, uses) -> Spec``.

Resolves names and types, sets ``Expr.ty`` on every expression, assigns
clause IDs and enforces the static rules of docs/language.md. All errors are
collected and raised together as one SpecCheckError.
"""

from __future__ import annotations

import hashlib
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from fractions import Fraction

from spectest import ast
from spectest.lang.errors import SpecCheckError, SpecLangError
from spectest.lang.signatures import (
    CLASSIFIER_HINTS,
    CR_FUNCTIONS,
    MP_FUNCTIONS,
    PRELUDE_SIGNATURES,
    SET_CONSTRUCTORS,
    CallInfo,
    SigError,
    components,
    constants_of,
    contains_any,
    has_set_constructor,
    is_any,
    is_stringish,
    join,
    non_eq_part,
    ordered,
    satisfies,
    type_constant,
)
from spectest.lang.spec import Diagnostic, Resolution, Spec
from spectest.types import (
    ANY,
    BOOL,
    BYTES,
    FLOAT_FORMATS,
    INT,
    INT_FORMATS,
    QERR,
    REAL,
    STRING,
    UNIT,
    AnyT,
    BoolT,
    BytesT,
    EnumT,
    FixedIntT,
    FloatT,
    FnT,
    IntT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    QErrT,
    RealT,
    RecordT,
    SetT,
    StringT,
    TupleT,
    Type,
    TypeVarT,
    is_fixed_width,
    is_integer,
    is_numeric,
    scalar_type,
    substitute,
)


@dataclass(frozen=True)
class _Poison(AnyT):
    """The type of an expression that already has a reported error."""

    def __str__(self) -> str:
        return "?"


POISON = _Poison()

BUILTIN_GENERICS = {"list": 1, "map": 2, "option": 1}
BUILTIN_TYPE_NAMES = frozenset(
    {*FLOAT_FORMATS, *INT_FORMATS, "bool", "int", "real", "string", "bytes", "unit", "set"}
    | set(BUILTIN_GENERICS)
)
RESERVED_NAMES = frozenset({"old", "result", "self", "mp", "cr"})
NAMESPACES = {
    "mp": ("the reference functions, which return reals", MP_FUNCTIONS),
    "cr": ("the correctly rounded functions, which return floats", CR_FUNCTIONS),
}
TYPE_HINTS = {
    "float": "f64",
    "double": "f64",
    "str": "string",
    "String": "string",
    "integer": "int",
    "Int": "int",
    "boolean": "bool",
    "Bool": "bool",
    "List": "list",
    "Map": "map",
    "Option": "option",
    "dict": "map",
}
CALLABLE_CLAUSES = (
    "requires", "ensures", "raises", "may_raise", "modifies", "relates", "aggregate",
    "unspecified", "impl_defined", "perf",
)  # fmt: skip
AGGREGATE_SHAPES = (
    "sum(v in S: e) <= c, sum(v in S: e) < c, sum(v in S: e) == 0, "
    "max(v in S: e) <= c, max(v in S: e) < c or all(v in S: p), with S a set such as "
    "f16.all or a list, and c a constant"
)
AGGREGATE_OPS = {"sum": ("<=", "<", "=="), "max": ("<=", "<")}
SUM_EQUALS_ZERO = (
    "sum(...) == c is an aggregate shape only for c = 0, where it demands that every term "
    "is 0; bound the total with sum(...) <= c instead"
)
TYPE_CLAUSES = ("invariant", "unspecified", "impl_defined", "perf")


def _is_poison(t: Type | None) -> bool:
    return isinstance(t, _Poison)


def contains_model(t: Type) -> bool:
    if isinstance(t, ModelT):
        return True
    return any(contains_model(c) for c in components(t))


def contains_real(t: Type) -> bool:
    if isinstance(t, RealT):
        return True
    return any(contains_real(c) for c in components(t))


def float_representable(value: Fraction | int, ft: FloatT) -> bool:
    """Is a rational exactly representable as a finite value of float format ft?"""
    v = Fraction(value)
    if v == 0:
        return True
    num, den = abs(v.numerator), v.denominator
    if den & (den - 1):
        return False
    k = den.bit_length() - 1
    tz = (num & -num).bit_length() - 1
    num >>= tz
    k -= tz
    bias = (1 << (ft.exp_bits - 1)) - 1
    emin = 1 - bias
    top = num.bit_length() - 1 - k
    return -k >= emin - ft.man_bits and top <= bias and num.bit_length() <= ft.man_bits + 1


def literal_value(e: ast.Expr) -> int | Fraction | None:
    """The value of a numeric literal, possibly negated, or None."""
    if isinstance(e, ast.Num):
        return e.value
    if isinstance(e, ast.Unary) and e.op == "-":
        v = literal_value(e.operand)
        return None if v is None else -v
    return None


# ---------------------------------------------------------------------------
# Type syntax


class TypeResolver:
    """Resolves type syntax against the declared enums, records, aliases and models."""

    def __init__(self, report: Callable[[ast.Node, str], None]) -> None:
        self.report = report
        self.enums: dict[str, EnumT] = {}
        self.records: dict[str, RecordT] = {}
        self.aliases: dict[str, Type] = {}
        self.record_decls: dict[str, ast.RecordDecl] = {}
        self.alias_decls: dict[str, ast.AliasDecl] = {}
        self.models: dict[str, ast.ModelDecl | ast.InterfaceDecl] = {}
        self.model_tvars: dict[str, dict[str, TypeVarT]] = {}
        self.active: list[str] = []

    def load_spec(self, spec: Spec) -> None:
        self.enums.update(spec.enums)
        self.records.update(spec.records)
        self.aliases.update(spec.aliases)
        for table in (spec.models, spec.interfaces):
            for name, decl in table.items():
                self.models[name] = decl
                self.model_tvars[name] = spec.tparams.get(decl, {})

    def resolve(
        self,
        t: ast.AnyTypeExpr,
        tvars: dict[str, TypeVarT] | None = None,
        self_name: str | None = None,
    ) -> Type:
        tvars = tvars or {}
        if isinstance(t, ast.LiteralTypeExpr):
            if len(set(t.values)) != len(t.values):
                self.report(t, "a literal union lists a value twice")
            return LiteralT(tuple(dict.fromkeys(t.values)))
        if isinstance(t, ast.TupleTypeExpr):
            return TupleT(tuple(self.resolve(e, tvars, self_name) for e in t.elems))
        return self.named(t, tvars, self_name)

    def named(self, t: ast.TypeExpr, tvars: dict[str, TypeVarT], self_name: str | None) -> Type:
        name = t.name
        args = [self.resolve(a, tvars, self_name) for a in t.args]
        if name in tvars:
            return self.no_args(t, tvars[name])
        st = scalar_type(name)
        if st is not None:
            return self.no_args(t, st)
        if name in BUILTIN_GENERICS:
            n = BUILTIN_GENERICS[name]
            if len(args) != n:
                shape = {"list": "list<T>", "map": "map<K, V>", "option": "option<T>"}[name]
                self.report(t, f"{name} takes {n} type argument{'s' if n > 1 else ''}: {shape}")
                return ANY
            if name == "list":
                return ListT(args[0])
            if name == "option":
                return OptionT(args[0])
            return MapT(args[0], args[1])
        if name in ("set", "unit"):
            self.report(t, f"{name} is not a type that can be written in a spec")
            return ANY
        if name in self.enums:
            return self.no_args(t, self.enums[name])
        if name in self.records or name in self.record_decls:
            return self.no_args(t, self.record(name, t))
        if name in self.aliases or name in self.alias_decls:
            return self.no_args(t, self.alias(name, t))
        if name in self.models:
            return self.model(t, args, self_name)
        hint = f" (did you mean {TYPE_HINTS[name]}?)" if name in TYPE_HINTS else ""
        self.report(t, f"unknown type {name}{hint}")
        return ANY

    def no_args(self, t: ast.TypeExpr, result: Type) -> Type:
        if t.args:
            self.report(t, f"{t.name} takes no type arguments")
        return result

    def model(self, t: ast.TypeExpr, args: list[Type], self_name: str | None) -> Type:
        decl = self.models[t.name]
        tvars = list(self.model_tvars.get(t.name, {}).values())
        is_iface = isinstance(decl, ast.InterfaceDecl)
        if not args and tvars and t.name == self_name:
            return ModelT(t.name, tuple(tvars), is_iface)
        if len(args) != len(tvars):
            shape = f"{t.name}<{', '.join(v.name for v in tvars)}>" if tvars else t.name
            self.report(t, f"{t.name} takes {len(tvars)} type argument(s): {shape}")
            return ANY
        for tv, arg in zip(tvars, args, strict=True):
            if not satisfies(arg, tv.bound):
                what = "canonical equality" if tv.bound == "Eq" else "a total order"
                self.report(
                    t, f"{arg} does not satisfy {tv.name}: {tv.bound} of {t.name} (it needs {what})"
                )
        return ModelT(t.name, tuple(args), is_iface)

    def alias(self, name: str, at: ast.Node) -> Type:
        if name in self.aliases:
            return self.aliases[name]
        if name in self.active:
            self.report(at, f"type {name} is defined in terms of itself")
            return ANY
        self.active.append(name)
        try:
            t = self.resolve(self.alias_decls[name].type)
        finally:
            self.active.pop()
        self.aliases[name] = t
        return t

    def record(self, name: str, at: ast.Node) -> Type:
        if name in self.records:
            return self.records[name]
        if name in self.active:
            self.report(at, f"record {name} contains itself")
            return ANY
        decl = self.record_decls[name]
        self.active.append(name)
        try:
            fields: list[tuple[str, Type]] = []
            for p in decl.fields:
                if any(f == p.name for f, _ in fields):
                    self.report(p, f"record {name} has two fields named {p.name}")
                if p.default is not None:
                    self.report(p.default, "record fields cannot have defaults")
                fields.append((p.name, self.resolve(p.type)))
        finally:
            self.active.pop()
        t = RecordT(name, tuple(fields))
        self.records[name] = t
        return t


# ---------------------------------------------------------------------------
# Checking


@dataclass
class Ctx:
    """Where an expression is checked: what names, result, old and calls it may use."""

    kind: str  # a clause kind, "partition", "partition_set" or "default"
    decl: str  # the declaration's ID, for messages
    tvars: dict[str, TypeVarT] = field(default_factory=dict)
    params: dict[str, tuple[Type, int]] = field(default_factory=dict)
    result: Type | None = None
    no_result: str = "result is not available here"
    self_t: ModelT | None = None
    no_self: str = "self is only available in methods and interface invariants"
    fields_of: ModelT | None = None
    allow_old: bool = False
    no_old: str = "old(...) is only allowed in ensures"
    allow_spec_fn: bool = False
    classes: dict[str, tuple[ast.PartitionClass, Type]] = field(default_factory=dict)
    only_param: str | None = None
    scopes: list[dict[str, tuple[Type, ast.Node]]] = field(default_factory=list)
    in_old: bool = False
    old_scope: int = 0  # scopes[:old_scope] are bound outside the current old(...)
    hidden: dict[str, str] = field(default_factory=dict)  # names that may not be used, why
    aggregate_top: ast.Comprehension | None = None  # may range over a set


class Checker:
    def __init__(self, file: ast.SpecFile, uses: Sequence[Spec] = ()) -> None:
        self.file = file
        self.path = file.path or "<string>"
        self.source = file.source
        self.uses = list(uses)
        self.diags: list[Diagnostic] = []
        digest = hashlib.sha256(self.source.encode())
        for u in self.uses:
            digest.update(b"\0" + u.hash.encode())
        self.spec = Spec(file.name, self.path, self.source, digest.hexdigest(), file)
        self.spec.uses = self.uses
        self.res = self.spec.resolution
        self.types = TypeResolver(self.error)
        self.local_fns: dict[str, ast.FnDecl] = {}
        self.names: dict[str, ast.Node] = {}
        self.local_signatures: list[ast.Node] = []
        self.duplicates: set[int] = set()
        self.used_names: dict[str, str] = {}
        for u in self.uses:
            self.merge(u)

    # -- reporting -----------------------------------------------------------

    def error(self, node: ast.Node, message: str) -> None:
        self.diags.append(Diagnostic.at(self.path, self.source, node.span, message))

    # -- used files ------------------------------------------------------------

    def merge(self, u: Spec) -> None:
        s = self.spec
        s.errors |= u.errors
        s.enums.update(u.enums)
        s.records.update(u.records)
        s.aliases.update(u.aliases)
        s.models.update(u.models)
        s.interfaces.update(u.interfaces)
        s.signature.update(u.signature)
        s.tparams.update(u.tparams)
        s.resolution.update(u.resolution)
        s.owner.update(u.owner)
        s.decl_ids.update(u.decl_ids)
        for cid, clause in u.clause_ids.items():
            if not isinstance(u.owner.get(clause), ast.FnDecl):
                s.clause_ids[cid] = clause
        for name in [*u.errors, *u.enums, *u.records, *u.aliases, *u.models, *u.interfaces]:
            self.used_names.setdefault(name, u.path)
        self.types.load_spec(u)

    # -- entry point -------------------------------------------------------------

    def run(self) -> Spec:
        self.collect()
        self.declare_signatures()
        self.check_defaults()
        for decl in self.file.decls:
            if id(decl) in self.duplicates:
                self.poison_all(decl)
            elif isinstance(decl, ast.ModelDecl):
                self.check_model(decl)
            elif isinstance(decl, ast.InterfaceDecl):
                self.check_interface(decl)
            elif isinstance(decl, ast.FnDecl):
                self.check_fn(decl)
        for node in ast.walk(self.file):
            if isinstance(node, ast.Expr) and node.ty is None:
                node.ty = POISON if self.diags else ANY
        if self.diags:
            raise SpecCheckError(self.diags)
        return self.spec

    # -- declarations ------------------------------------------------------------

    def declare(self, name: str, node: ast.Node) -> bool:
        if name in BUILTIN_TYPE_NAMES:
            self.error(node, f"{name} is a built-in type and cannot be redeclared")
        elif name in RESERVED_NAMES:
            self.error(node, f"{name} is reserved and cannot name a declaration")
        elif name in self.names:
            self.error(node, f"{name} is already declared at line {self.names[name].span.line}")
        elif name in self.used_names:
            self.error(node, f"{name} is already declared in {self.used_names[name]}")
        else:
            self.names[name] = node
            return True
        self.duplicates.add(id(node))
        return False

    def collect(self) -> None:
        s = self.spec
        for d in self.file.decls:
            if isinstance(d, ast.ErrorDecl):
                if self.declare(d.name, d):
                    s.errors.add(d.name)
            elif isinstance(d, ast.EnumDecl):
                if len(set(d.members)) != len(d.members):
                    self.error(d, f"enum {d.name} lists a member twice")
                if self.declare(d.name, d):
                    s.enums[d.name] = EnumT(d.name, tuple(dict.fromkeys(d.members)))
            elif isinstance(d, ast.RecordDecl):
                if self.declare(d.name, d):
                    self.types.record_decls[d.name] = d
            elif isinstance(d, ast.AliasDecl):
                if self.declare(d.name, d):
                    self.types.alias_decls[d.name] = d
            elif isinstance(d, ast.ModelDecl):
                if self.declare(d.name, d):
                    s.models[d.name] = d
                    self.types.models[d.name] = d
                s.tparams[d] = self.tvars_of(d.tparams)
                self.types.model_tvars.setdefault(d.name, s.tparams[d])
            elif isinstance(d, ast.InterfaceDecl):
                if self.declare(d.name, d):
                    s.interfaces[d.name] = d
                    self.types.models[d.name] = d
                s.tparams[d] = self.tvars_of(d.tparams)
                self.types.model_tvars.setdefault(d.name, s.tparams[d])
            elif isinstance(d, ast.FnDecl):
                if self.declare(d.name, d):
                    self.local_fns[d.name] = d
                    s.fns[d.name] = d
                s.tparams[d] = self.tvars_of(d.tparams)
        self.types.enums.update(s.enums)
        for name in list(self.types.alias_decls):
            self.types.alias(name, self.types.alias_decls[name])
        for name in list(self.types.record_decls):
            self.types.record(name, self.types.record_decls[name])
        s.aliases.update(self.types.aliases)
        s.records.update(self.types.records)

    def tvars_of(self, tparams: list[ast.TypeParam]) -> dict[str, TypeVarT]:
        out: dict[str, TypeVarT] = {}
        for tp in tparams:
            bound = tp.bound
            if bound not in (None, "Eq", "Ord"):
                self.error(tp, f"unknown bound {bound}: a type parameter's bound is Eq or Ord")
                bound = None
            if tp.name in out:
                self.error(tp, f"type parameter {tp.name} is declared twice")
            elif tp.name in BUILTIN_TYPE_NAMES:
                self.error(tp, f"type parameter {tp.name} shadows a built-in type")
            out[tp.name] = TypeVarT(tp.name, bound)
        return out

    def resolve(
        self, t: ast.AnyTypeExpr, tvars: dict[str, TypeVarT], self_name: str | None = None
    ) -> Type:
        return self.types.resolve(t, tvars, self_name)

    def param_types(
        self, params: list[ast.Param], tvars: dict[str, TypeVarT], self_name: str | None
    ) -> list[Type]:
        seen: set[str] = set()
        out: list[Type] = []
        for p in params:
            if p.name in seen:
                self.error(p, f"parameter {p.name} is declared twice")
            seen.add(p.name)
            if p.name in RESERVED_NAMES:
                self.error(p, f"{p.name} is reserved and cannot name a parameter")
            t = self.resolve(p.type, tvars, self_name)
            if contains_real(t):
                self.error(p.type, "real is clause-only and cannot be a parameter type")
            out.append(t)
        return out

    def signature_of(
        self,
        node: ast.Node,
        params: list[ast.Param],
        returns: ast.AnyTypeExpr | None,
        tvars: dict[str, TypeVarT],
        self_name: str | None,
    ) -> FnT:
        ptypes = self.param_types(params, tvars, self_name)
        result = UNIT if returns is None else self.resolve(returns, tvars, self_name)
        sig = FnT(tuple(ptypes), result, tuple(p.name for p in params))
        self.spec.signature[node] = sig
        self.local_signatures.append(node)
        return sig

    def declare_signatures(self) -> None:
        s = self.spec
        for d in self.file.decls:
            if isinstance(d, ast.ModelDecl | ast.InterfaceDecl):
                tvars = s.tparams[d]
                s.decl_ids[d] = d.name
                members: dict[str, ast.Node] = {}
                for o in d.observers:
                    self.member(members, o.name, o, d.name)
                    s.owner[o] = d
                    self.signature_of(o, o.params, o.type, tvars, d.name)
                if isinstance(d, ast.InterfaceDecl):
                    self_t = ModelT(d.name, tuple(tvars.values()), True)
                    for c in d.ctors:
                        self.member(members, c.name, c, d.name)
                        s.owner[c] = d
                        s.tparams[c] = tvars
                        s.decl_ids[c] = f"{d.name}.{c.name}"
                        sig = self.signature_of(c, c.params, c.returns, tvars, d.name)
                        if not is_any(sig.result) and sig.result != self_t:
                            self.error(
                                c.returns or c,
                                f"a constructor returns its interface: -> {d.name}",
                            )
                        s.signature[c] = FnT(sig.params, self_t, sig.param_names)
                    for m in d.methods:
                        self.member(members, m.name, m, d.name)
                        s.owner[m] = d
                        s.tparams[m] = tvars
                        s.decl_ids[m] = f"{d.name}.{m.name}"
                        self.signature_of(m, m.params, m.returns, tvars, d.name)
            elif isinstance(d, ast.FnDecl):
                s.decl_ids[d] = d.name
                self.signature_of(d, d.params, d.returns, s.tparams[d], None)

    def member(self, members: dict[str, ast.Node], name: str, node: ast.Node, owner: str) -> None:
        if name in members:
            self.error(node, f"{owner} already has a member named {name}")
        members[name] = node

    def check_defaults(self) -> None:
        for node in self.local_signatures:
            sig = self.spec.signature[node]
            tvars = self.spec.tparams.get(node) or self.spec.tparams.get(
                self.spec.owner.get(node, node), {}
            )
            for p, t in zip(node.params, sig.params, strict=False):  # type: ignore[attr-defined]
                if p.default is not None:
                    self.check_default(p, t, tvars)

    def check_default(self, p: ast.Param, t: Type, tvars: dict[str, TypeVarT]) -> None:
        assert p.default is not None
        ctx = Ctx("default", p.name, tvars, no_result="a default value cannot refer to result")
        dt = self.infer(p.default, ctx)
        if _is_poison(dt):
            return
        if not self.assignable(dt, t, p.default):
            if isinstance(t, LiteralT) and isinstance(p.default, ast.Str):
                self.error(p.default, f'"{p.default.value}" is not one of {t}')
            else:
                self.error(p.default, f"the default of {p.name} must be a {t}, but it is {dt}")
            return
        value = literal_value(p.default)
        if value is None:
            return
        if isinstance(t, FixedIntT) and not (isinstance(value, int) and t.min <= value <= t.max):
            self.error(p.default, f"{value} is not a {t} value ({t.min} to {t.max})")
        elif isinstance(t, FloatT) and not float_representable(value, t):
            self.error(p.default, f"{value} is not exactly representable as {t}")

    # -- clause IDs ----------------------------------------------------------------

    def assign_ids(
        self,
        decl: ast.Node,
        decl_id: str,
        clauses: list[ast.Clause],
        members: dict[str, str] | None = None,
    ) -> None:
        """Clause IDs: ``<decl>.<label>`` or ``<decl>#<n>``.

        ``members`` maps the member names of a model or interface to their kind;
        a label equal to one would give a clause the ID of that member.
        """
        labels: dict[str, ast.Clause] = {}
        for i, c in enumerate(clauses, 1):
            self.spec.owner[c] = decl
            if c.label is not None and members and c.label in members:
                cid = f"{decl_id}.{c.label}"
                self.error(
                    c,
                    f"clause label {c.label} gives the ID {cid}, which already names the "
                    f"{members[c.label]} {cid}: rename the label "
                    f"(e.g. {c.kind} {c.label}_holds:)",
                )
                c.id = f"{decl_id}#{i}"
            elif c.label is not None:
                if c.label in labels:
                    line = labels[c.label].span.line
                    self.error(
                        c, f"clause label {c.label} is already used in {decl_id} (line {line})"
                    )
                    c.id = f"{decl_id}#{i}"
                else:
                    labels[c.label] = c
                    c.id = f"{decl_id}.{c.label}"
            else:
                c.id = f"{decl_id}#{i}"
            if c.id in self.spec.clause_ids and self.spec.clause_ids[c.id] is not c:
                if c.label is None or labels.get(c.label) is c:
                    self.error(c, f"clause ID {c.id} is already in use")
            else:
                self.spec.clause_ids[c.id] = c

    def check_freedoms(self, decl_id: str, clauses: list[ast.Clause]) -> None:
        freedoms: dict[str, ast.Clause] = {}
        for c in clauses:
            if c.kind in ("unspecified", "impl_defined") and c.freedom is not None:
                if c.freedom in freedoms:
                    self.error(c, f"{c.freedom} is already declared a freedom of {decl_id}")
                freedoms[c.freedom] = c
        if not freedoms:
            return
        for c in clauses:
            if c.expr is None:
                continue
            reported: set[str] = set()
            for node in ast.walk(c.expr):
                r = self.res.get(node)
                if r is None or r.kind not in ("prelude", "observer", "field"):
                    continue
                if r.name in freedoms and r.name not in reported:
                    reported.add(r.name)
                    f = freedoms[r.name]
                    self.error(
                        node,
                        f"this clause observes {r.name}, which {decl_id} declares "
                        f"{f.kind} (line {f.span.line}): no clause may observe it",
                    )

    # -- models and interfaces ---------------------------------------------------------

    def check_model(self, m: ast.ModelDecl) -> None:
        mt = ModelT(m.name, tuple(self.spec.tparams[m].values()), False)
        self.check_type_clauses(m, mt)

    def check_interface(self, iface: ast.InterfaceDecl) -> None:
        tvars = self.spec.tparams[iface]
        it = ModelT(iface.name, tuple(tvars.values()), True)
        self.check_type_clauses(iface, it)
        for c in iface.ctors:
            sig = self.spec.signature[c]
            self.check_callable(c, f"{iface.name}.{c.name}", sig, None, tvars, "constructor")
        for m in iface.methods:
            sig = self.spec.signature[m]
            self.check_callable(m, f"{iface.name}.{m.name}", sig, it, tvars, "method")

    def check_type_clauses(self, decl: ast.ModelDecl | ast.InterfaceDecl, mt: ModelT) -> None:
        what = "interface" if mt.is_interface else "model"
        members = {o.name: "observer" for o in decl.observers}
        if isinstance(decl, ast.InterfaceDecl):
            members.update({c.name: "constructor" for c in decl.ctors})
            members.update({m.name: "method" for m in decl.methods})
        self.assign_ids(decl, decl.name, decl.clauses, members)
        for c in decl.clauses:
            if c.kind not in TYPE_CLAUSES:
                self.error(
                    c,
                    f"{c.kind} belongs to a function, constructor or method, "
                    f"not to {what} {decl.name}",
                )
                if c.expr is not None:
                    self.poison(c.expr)
                continue
            if c.kind != "invariant" or c.expr is None:
                continue
            ctx = Ctx(
                "invariant",
                decl.name,
                self.spec.tparams[decl],
                self_t=mt,
                fields_of=mt,
                no_result="an invariant describes an object's state: there is no result",
                no_old="old(...) is only allowed in ensures",
            )
            self.want_bool(c.expr, self.infer(c.expr, ctx), "an invariant")
        self.check_freedoms(decl.name, decl.clauses)

    # -- callables -----------------------------------------------------------------

    def check_fn(self, fn: ast.FnDecl) -> None:
        sig = self.spec.signature[fn]
        self.check_callable(fn, fn.name, sig, None, self.spec.tparams[fn], "function")

    def check_callable(
        self,
        decl: ast.Callable_,
        decl_id: str,
        sig: FnT,
        self_t: ModelT | None,
        tvars: dict[str, TypeVarT],
        what: str,
    ) -> None:
        params = {p.name: (t, i) for i, (p, t) in enumerate(zip(decl.params, sig.params))}
        has_state = self_t is not None or any(contains_model(t) for t in sig.params)
        no_self = (
            "a constructor has no self: the new object is result"
            if what == "constructor"
            else "self is only available in methods"
        )
        self.assign_ids(decl, decl_id, decl.clauses)
        seen: dict[str, ast.Partition] = {}
        for part in decl.partitions:
            self.check_partition(decl, decl_id, part, params, tvars, seen)
        for c in decl.clauses:
            if c.kind not in CALLABLE_CLAUSES:
                self.error(c, f"{c.kind} belongs to a model or interface; in a {what} use ensures")
                if c.expr is not None:
                    self.poison(c.expr)
                continue
            if c.kind == "modifies":
                self.check_modifies(c, decl_id, params, self_t)
                continue
            if c.kind == "aggregate":
                self.check_aggregate(c, decl, decl_id, params, tvars, what)
                continue
            if c.kind in ("raises", "may_raise") and c.error is not None:
                self.res[c] = Resolution("error", c.error)
                if c.error not in self.spec.errors:
                    self.error(c, f"unknown error {c.error}: declare it with 'error {c.error}'")
            if c.expr is None:
                continue
            ctx = Ctx(c.kind, decl_id, tvars, params=params, self_t=self_t, no_self=no_self)
            if c.kind in ("requires", "raises", "may_raise"):
                ctx.no_result = (
                    f"result is not available in {c.kind}: it is evaluated on the inputs, "
                    "before the call"
                )
                ctx.no_old = (
                    f"old(...) is only allowed in ensures; {c.kind} already sees the state "
                    "before the call"
                )
            else:
                if sig.result != UNIT:
                    ctx.result = sig.result
                ctx.no_result = f"{decl_id} returns nothing, so there is no result"
                if c.kind == "ensures":
                    ctx.allow_old = has_state
                    ctx.no_old = (
                        f"old(...) needs state that the call can change, but {decl_id} has "
                        "no handle parameter or self"
                    )
                else:
                    ctx.allow_spec_fn = True
                    ctx.no_old = "old(...) is only allowed in ensures"
            what_clause = (
                f"the condition of {c.kind}"
                if c.kind in ("raises", "may_raise")
                else f"the {c.kind} clause"
            )
            self.want_bool(c.expr, self.infer(c.expr, ctx), what_clause)
        self.check_freedoms(decl_id, decl.clauses)

    def check_aggregate(
        self,
        c: ast.Clause,
        decl: ast.Callable_,
        decl_id: str,
        params: dict[str, tuple[Type, int]],
        tvars: dict[str, TypeVarT],
        what: str,
    ) -> None:
        assert c.expr is not None
        if not isinstance(decl, ast.FnDecl):
            self.error(
                c,
                f"aggregate clauses belong to functions (fn), not to a {what}: a bound over "
                "a whole input set needs inputs that do not depend on an object's state",
            )
            self.poison(c.expr)
            return
        ctx = Ctx(
            "aggregate",
            decl_id,
            tvars,
            hidden={
                p: (
                    f"an aggregate clause cannot use the parameter {p} of {decl_id}: it "
                    f"ranges over its own variable, e.g. sum(v in S: qe({decl.name}(v), ...))"
                )
                for p in params
            },
            allow_spec_fn=True,
            no_result=(
                "an aggregate clause is evaluated once over a set of inputs, so there is no "
                f"result: call {decl.name}(v) for each member instead"
            ),
            no_old="old(...) has no meaning in an aggregate clause: it is not tied to one call",
            no_self="an aggregate clause has no self",
        )
        top, bound, problem = self.aggregate_shape(c.expr)
        ctx.aggregate_top = top
        self.want_bool(c.expr, self.infer(c.expr, ctx), "the aggregate clause")
        if problem is not None:
            self.error(c.expr, problem)
        elif bound is not None and not self.is_constant(bound):
            self.error(
                bound,
                "the bound of an aggregate clause must be a constant (numbers, and T.min or "
                "T.max, combined with + - * /), the same for every member",
            )

    def aggregate_shape(
        self, e: ast.Expr
    ) -> tuple[ast.Comprehension | None, ast.Expr | None, str | None]:
        """(top comprehension, bound, problem) of an aggregate clause's expression."""
        shapes = f"an aggregate clause has one of the shapes {AGGREGATE_SHAPES}"
        if isinstance(e, ast.Comprehension):
            return e, None, None if e.kind == "all" else shapes
        if isinstance(e, ast.Binary):
            for side in (e.left, e.right):
                if isinstance(side, ast.Comprehension):
                    break
            else:
                return None, None, shapes
            if side is not e.left or e.left.kind not in AGGREGATE_OPS:
                return side, None, shapes
            if e.op not in AGGREGATE_OPS[e.left.kind]:
                return side, None, shapes
            if e.op == "==" and literal_value(e.right) != 0:
                return side, None, SUM_EQUALS_ZERO
            return side, e.right, None
        return None, None, shapes

    def is_constant(self, e: ast.Expr) -> bool:
        if isinstance(e, ast.Num):
            return True
        if isinstance(e, ast.Unary) and e.op == "-":
            return self.is_constant(e.operand)
        if isinstance(e, ast.Binary) and e.op in ("+", "-", "*", "/", "//", "%"):
            return self.is_constant(e.left) and self.is_constant(e.right)
        if isinstance(e, ast.Attribute):
            r = self.res.get(e)
            return r is not None and r.kind == "type_const"
        return False

    def check_modifies(
        self,
        c: ast.Clause,
        decl_id: str,
        params: dict[str, tuple[Type, int]],
        self_t: ModelT | None,
    ) -> None:
        seen: set[str] = set()
        for n in c.names:
            if n in seen:
                self.error(c, f"modifies lists {n} twice")
            seen.add(n)
            if n == "self":
                if self_t is None:
                    self.error(c, "modifies self: self is only available in methods")
            elif n not in params:
                self.error(c, f"modifies {n}: {decl_id} has no parameter {n}")
            elif not contains_model(params[n][0]):
                self.error(
                    c,
                    f"modifies names handle parameters (models or interfaces) or "
                    f"self; {n} is a {params[n][0]} value, which a call cannot change",
                )

    def check_partition(
        self,
        decl: ast.Callable_,
        decl_id: str,
        part: ast.Partition,
        params: dict[str, tuple[Type, int]],
        tvars: dict[str, TypeVarT],
        seen: dict[str, ast.Partition],
    ) -> None:
        self.spec.owner[part] = decl
        for cls in part.classes:
            self.spec.owner[cls] = decl
        if part.param in seen:
            self.error(
                part, f"{part.param} is already partitioned at line {seen[part.param].span.line}"
            )
        seen[part.param] = part
        if part.param not in params:
            if part.param == "self":
                self.error(part, "self cannot be partitioned: partition the method's parameters")
            else:
                self.error(part, f"partition {part.param}: {decl_id} has no parameter {part.param}")
            for cls in part.classes:
                self.poison(cls.expr)
            return
        ptype = params[part.param][0]
        fixed = is_fixed_width(ptype)
        classes: dict[str, tuple[ast.PartitionClass, Type]] = {}
        for cls in part.classes:
            if cls.name in classes:
                self.error(cls, f"partition {part.param} already has a class named {cls.name}")
            elif cls.name in params:
                self.error(cls, f"class {cls.name} has the name of a parameter of {decl_id}")
            ctx = Ctx(
                "partition_set" if fixed else "partition",
                decl_id,
                tvars,
                params=params,
                only_param=part.param,
                classes=dict(classes),
                no_result="a partition class describes an input: there is no result",
                no_old="old(...) is only allowed in ensures",
                no_self="self cannot appear in a partition class",
            )
            if fixed:
                st = SetT(ptype)
                t = self.infer(cls.expr, ctx, st)
                if not is_any(t) and t != st:
                    self.error(
                        cls.expr,
                        f"class {cls.name} of the {ptype} parameter "
                        f"{part.param} must be a set of {ptype} values ({ptype}."
                        f"{'nan' if isinstance(ptype, FloatT) else 'all'}, "
                        f"{ptype}.range(a, b), {{v, ...}}, combined with | & -), "
                        f"but it is {t}",
                    )
                classes[cls.name] = (cls, st)
            else:
                t = self.infer(cls.expr, ctx)
                self.want_bool(cls.expr, t, f"class {cls.name} (a predicate over {part.param})")
                classes[cls.name] = (cls, BOOL)

    # -- expressions -------------------------------------------------------------------

    def poison_all(self, node: ast.Node) -> None:
        for n in ast.walk(node):
            if isinstance(n, ast.Expr) and n.ty is None:
                n.ty = POISON

    def poison(self, e: ast.Expr) -> None:
        for node in ast.walk(e):
            if isinstance(node, ast.Expr) and node.ty is None:
                node.ty = POISON

    def want_bool(self, node: ast.Expr, t: Type, what: str) -> None:
        if not isinstance(t, (BoolT, AnyT)):
            self.error(node, f"{what} must be a bool, but this is {t}")

    def infer(self, e: ast.Expr, ctx: Ctx, expected: Type | None = None) -> Type:
        method = getattr(self, f"infer_{type(e).__name__}")
        t = method(e, ctx, expected)
        e.ty = t
        return t

    def infer_Num(self, e: ast.Num, ctx: Ctx, expected: Type | None) -> Type:
        return INT if isinstance(e.value, int) else REAL

    def infer_Str(self, e: ast.Str, ctx: Ctx, expected: Type | None) -> Type:
        return STRING

    def infer_BoolLit(self, e: ast.BoolLit, ctx: Ctx, expected: Type | None) -> Type:
        return BOOL

    def infer_NoneLit(self, e: ast.NoneLit, ctx: Ctx, expected: Type | None) -> Type:
        return OptionT(ANY)

    # names

    def binds_value(self, name: str, ctx: Ctx) -> bool:
        """Is name a local, a partition class or a parameter here?"""
        return (
            any(name in s for s in ctx.scopes)
            or name in ctx.classes
            or (name in ctx.params and ctx.kind != "partition_set")
        )

    def observers_of(self, model: str) -> dict[str, ast.Observe]:
        decl = self.spec.models.get(model) or self.spec.interfaces.get(model)
        return {} if decl is None else {o.name: o for o in decl.observers}

    def model_env(self, mt: ModelT) -> dict[str, Type]:
        decl = self.spec.models.get(mt.name) or self.spec.interfaces.get(mt.name)
        tvars = self.spec.tparams.get(decl, {}) if decl is not None else {}
        return dict(zip(tvars, mt.args, strict=False))

    def observer_type(self, mt: ModelT, obs: ast.Observe) -> Type:
        sig = self.spec.signature.get(obs)
        return POISON if sig is None else substitute(sig.result, self.model_env(mt))

    def contains_float(self, t: Type, seen: frozenset[str] = frozenset()) -> bool:
        """Whether values of type t hold floats, looking through model fields."""
        if isinstance(t, FloatT):
            return True
        if isinstance(t, ModelT):
            if t.name in seen:
                return False
            return any(
                self.contains_float(self.observer_type(t, o), seen | {t.name})
                for o in self.observers_of(t.name).values()
                if not o.params
            )
        return any(self.contains_float(c, seen) for c in components(t))

    def infer_Name(self, e: ast.Name, ctx: Ctx, expected: Type | None) -> Type:
        found = self.lookup(e, ctx)
        if found is None:
            return POISON
        res, t = found
        self.res[e] = res
        return t

    def lookup(self, e: ast.Name, ctx: Ctx) -> tuple[Resolution, Type] | None:
        name = e.id
        for depth in range(len(ctx.scopes) - 1, -1, -1):
            scope = ctx.scopes[depth]
            if name in scope:
                t, binder = scope[name]
                if ctx.in_old and ctx.allow_old and depth < ctx.old_scope:
                    self.error(e, self.old_local_message(name, binder))
                    return None
                return Resolution("local", name, binder), t
        if name in ctx.hidden:
            self.error(e, ctx.hidden[name])
            return None
        if name in ctx.classes:
            cls, t = ctx.classes[name]
            return Resolution("class", name, cls), t
        if name in ctx.params:
            if ctx.kind == "partition_set":
                ptype = ctx.params[name][0]
                self.error(
                    e,
                    f"classes of the fixed-width parameter {ctx.only_param} are sets "
                    f"of values, so {name} cannot appear in them: build them from "
                    f"{ptype}.{'nan' if isinstance(ptype, FloatT) else 'all'}, "
                    f"{ptype}.range(a, b), {{v, ...}} and earlier classes",
                )
                return None
            if ctx.only_param is not None and name != ctx.only_param:
                self.error(
                    e,
                    f"a class of partition {ctx.only_param} may only refer to "
                    f"{ctx.only_param}, not to {name}",
                )
                return None
            t, i = ctx.params[name]
            return Resolution("param", name, i), t
        if name == "result":
            if ctx.in_old:
                self.error(e, "result does not exist before the call, so old(...) cannot use it")
                return None
            if ctx.result is None:
                self.error(e, ctx.no_result)
                return None
            return Resolution("result", "result"), ctx.result
        if name == "self":
            if ctx.self_t is None:
                self.error(e, ctx.no_self)
                return None
            return Resolution("self", "self", ctx.self_t.name), ctx.self_t
        if ctx.fields_of is not None:
            obs = self.observers_of(ctx.fields_of.name).get(name)
            if obs is not None:
                if obs.params:
                    self.error(
                        e,
                        f"{name} takes arguments: {name}({', '.join(p.name for p in obs.params)})",
                    )
                    return None
                return (
                    Resolution("field", name, ctx.fields_of.name),
                    self.observer_type(ctx.fields_of, obs),
                )
        members = [en for en in self.spec.enums.values() if name in en.members]
        if len(members) == 1:
            return Resolution("enum_member", name, members[0].name), members[0]
        if len(members) > 1:
            self.error(
                e,
                f"{name} is a member of several enums ("
                f"{', '.join(m.name for m in members)}): write {members[0].name}.{name}",
            )
            return None
        self.unknown_name(e, ctx)
        return None

    def old_local_message(self, name: str, binder: ast.Node) -> str:
        how = f"{binder.kind}(...)" if isinstance(binder, ast.Comprehension) else "let"
        return (
            f"old(...) is evaluated before the call, so it cannot use {name}, which {how} "
            "binds inside this clause: bind old(...) of the state first, e.g. "
            "let xs = old(self.items) in all(i in range(0, len(xs)): xs[i] == self.items[i])"
        )

    def unknown_name(self, e: ast.Name, ctx: Ctx) -> None:
        name = e.id
        if name == "old":
            msg = "old is called as old(e)"
        elif name in self.local_fns:
            msg = (
                f"{name} is a spec function: call it as {name}(...), in a relates or "
                "aggregate clause"
            )
        elif name in PRELUDE_SIGNATURES:
            msg = f"{name} is a function: call it as {name}(...)"
        elif name in NAMESPACES:
            msg = f"{name} is the namespace of {NAMESPACES[name][0]}, e.g. {name}.cos(x)"
        elif (
            scalar_type(name) is not None
            or name in self.spec.models
            or (name in self.spec.interfaces)
        ):
            msg = f"{name} is a type, not a value"
        else:
            msg = f"unknown name {name}"
            hints: list[str] = []
            if ctx.self_t is not None and name in self.observers_of(ctx.self_t.name):
                hints.append(f"self.{name}")
            for p, (t, _) in ctx.params.items():
                if isinstance(t, ModelT) and name in self.observers_of(t.name):
                    hints.append(f"{p}.{name}")
            hints.extend(
                f"{ns}.{name}" for ns in NAMESPACES if f"{ns}.{name}" in PRELUDE_SIGNATURES
            )
            if hints:
                msg += f" (did you mean {' or '.join(hints)}?)"
        self.error(e, msg)

    # operators

    def infer_Unary(self, e: ast.Unary, ctx: Ctx, expected: Type | None) -> Type:
        t = self.infer(e.operand, ctx)
        if e.op == "not":
            self.want_bool(e.operand, t, "the operand of not")
            return BOOL
        if is_any(t):
            return t
        if isinstance(t, FloatT):
            return t
        if is_integer(t):
            return INT
        if isinstance(t, RealT):
            return REAL
        self.error(e, f"unary - needs a number, but the operand is {t}")
        return POISON

    def infer_Binary(self, e: ast.Binary, ctx: Ctx, expected: Type | None) -> Type:
        op = e.op
        side = expected if isinstance(expected, SetT) else None
        lt = self.infer(e.left, ctx, side)
        rt = self.infer(e.right, ctx, side)
        if op in ("and", "or", "implies"):
            self.want_bool(e.left, lt, f"the left operand of {op}")
            self.want_bool(e.right, rt, f"the right operand of {op}")
            return BOOL
        if op in ("|", "&") or (op == "-" and (isinstance(lt, SetT) or isinstance(rt, SetT))):
            return self.set_op(e, lt, rt)
        if op in ("==", "!="):
            return self.equality(e, lt, rt)
        if op in ("<", "<=", ">", ">="):
            return self.ordering(e, lt, rt)
        if op == "in":
            return self.membership(e, lt, rt)
        return self.arith(e, lt, rt)

    def set_op(self, e: ast.Binary, lt: Type, rt: Type) -> Type:
        if _is_poison(lt) or _is_poison(rt):
            return POISON
        if not isinstance(lt, SetT) or not isinstance(rt, SetT):
            if e.op in ("|", "&") and isinstance(lt, BoolT) and isinstance(rt, BoolT):
                word = "or" if e.op == "|" else "and"
                self.error(e, f"{e.op} combines partition sets; for booleans write {word}")
            else:
                self.error(
                    e, f"{e.op} on partition sets needs a set on both sides, but got {lt} and {rt}"
                )
            return POISON
        if lt.elem != rt.elem:
            self.error(e, f"cannot combine a set of {lt.elem} with a set of {rt.elem}")
            return POISON
        return lt

    def eq_message(self, op: str, t: Type, bad: Type) -> str:
        inside = "" if t == bad else f" (inside {t})"
        if isinstance(bad, FloatT):
            return (
                f"{op} is not defined on {bad}{inside}: floats have no implicit equality. "
                "Use same(a, b) for bit-identical values, ieee_eq(a, b) for IEEE 754 equality, "
                f"real(a) {op} real(b) to compare numerically, or eq(a, b, float=...) "
                "for collections"
            )
        if isinstance(bad, ModelT):
            return (
                f"{op} is not defined on {bad} handles{inside}: compare their observers "
                "(a.items == b.items) or use eq(a, b, ...)"
            )
        if isinstance(bad, TypeVarT):
            return f"{op} needs equality on {bad}{inside}: declare it as {bad.name}: Eq"
        if isinstance(bad, SetT):
            return f"{op} is not defined on partition sets"
        return f"{op} is not defined on {bad}{inside}"

    def qerr_comparison(self, e: ast.Binary, lt: Type, rt: Type) -> bool:
        """Check a comparison with a qerr operand; False when neither side is a qerr."""
        if not isinstance(lt, QErrT) and not isinstance(rt, QErrT):
            return False
        other = rt if isinstance(lt, QErrT) else lt
        if isinstance(other, QErrT) or is_any(other):
            return True
        if is_numeric(other) and not isinstance(other, FloatT):
            return True
        self.error(
            e,
            f"{e.op} compares a qerr with a qerr or a number (an int or real, read as "
            f"c + 0·nan), but the other side is {other}",
        )
        return True

    def equality(self, e: ast.Binary, lt: Type, rt: Type) -> Type:
        if _is_poison(lt) or _is_poison(rt):
            return BOOL
        if self.qerr_comparison(e, lt, rt):
            return BOOL
        for t in (lt, rt):
            bad = non_eq_part(t)
            if bad is not None:
                self.error(e, self.eq_message(e.op, t, bad))
                return BOOL
        j = join(lt, rt)
        if j is None:
            self.error(e, f"cannot compare {lt} with {rt}")
            return BOOL
        if contains_any(j):
            self.error(
                e,
                f"cannot tell the type of both sides of {e.op} ({j}); "
                "compare with a value of known type",
            )
            return BOOL
        self.literal_member(e.left, lt, e.right, rt)
        self.literal_member(e.right, rt, e.left, lt)
        return BOOL

    def literal_member(self, a: ast.Expr, at: Type, b: ast.Expr, bt: Type) -> None:
        if isinstance(at, LiteralT) and isinstance(b, ast.Str) and b.value not in at.values:
            self.error(b, f'"{b.value}" is not one of {at}')

    def ordering(self, e: ast.Binary, lt: Type, rt: Type) -> Type:
        if is_any(lt) or is_any(rt):
            return BOOL
        if self.qerr_comparison(e, lt, rt):
            return BOOL
        if is_numeric(lt) and is_numeric(rt):
            return BOOL
        j = join(lt, rt)
        if j is None:
            self.error(e, f"cannot compare {lt} with {rt}")
        elif not ordered(j):
            if isinstance(j, TypeVarT):
                hint = f": declare it as {j.name}: Ord"
            elif isinstance(j, ModelT):
                hint = ": compare their observers"
            else:
                hint = ""
            self.error(e, f"{e.op} needs ordered operands, but {j} has no total order{hint}")
        return BOOL

    def membership(self, e: ast.Binary, lt: Type, rt: Type) -> Type:
        if _is_poison(lt) or _is_poison(rt):
            return BOOL
        if isinstance(rt, ListT):
            elem = rt.elem
        elif isinstance(rt, MapT):
            elem = rt.key
        elif is_stringish(rt):
            if not is_stringish(lt) and not is_any(lt):
                self.error(e, f"in on a string looks for a substring, but the left side is {lt}")
            return BOOL
        elif isinstance(rt, SetT):
            self.error(
                e,
                "partition sets are not values: in a clause test the value directly, "
                "e.g. is_nan(x) or x < 0",
            )
            return BOOL
        else:
            self.error(e, f"in needs a list, map or string on the right, but it is {rt}")
            return BOOL
        for t in (lt, elem):
            bad = non_eq_part(t)
            if bad is not None:
                self.error(e, self.eq_message("in", t, bad))
                return BOOL
        if join(lt, elem) is None:
            self.error(e, f"cannot look for a {lt} among {elem} values")
        return BOOL

    def arith(self, e: ast.Binary, lt: Type, rt: Type) -> Type:
        op = e.op
        if is_any(lt) or is_any(rt):
            return POISON if _is_poison(lt) or _is_poison(rt) else ANY
        if isinstance(lt, QErrT) or isinstance(rt, QErrT):
            if op == "+" and isinstance(lt, QErrT) and isinstance(rt, QErrT):
                return QERR
            self.error(
                e,
                f"cannot apply {op} to {lt} and {rt}: quantized errors only add to each "
                "other (qe(a, b) + qe(c, d)); read their parts with steps(e) and nans(e)",
            )
            return POISON
        if op == "+":
            if isinstance(lt, ListT) and isinstance(rt, ListT):
                j = join(lt, rt)
                if j is None:
                    self.error(e, f"cannot concatenate {lt} and {rt}")
                    return POISON
                return j
            if is_stringish(lt) and is_stringish(rt):
                return STRING
            if isinstance(lt, BytesT) and isinstance(rt, BytesT):
                return BYTES
        if is_numeric(lt) and is_numeric(rt):
            if op == "/":
                return REAL
            if op in ("//", "%"):
                if is_integer(lt) and is_integer(rt):
                    return INT
                self.error(
                    e, f"{op} takes integers, but got {lt} and {rt} (use / for division of reals)"
                )
                return POISON
            if isinstance(lt, (FloatT, RealT)) or isinstance(rt, (FloatT, RealT)):
                return REAL
            return INT
        self.error(e, f"cannot apply {op} to {lt} and {rt}")
        return POISON

    def infer_If(self, e: ast.If, ctx: Ctx, expected: Type | None) -> Type:
        self.want_bool(e.cond, self.infer(e.cond, ctx), "the condition of if")
        tt = self.infer(e.then, ctx, expected)
        et = self.infer(e.else_, ctx, expected)
        if _is_poison(tt) or _is_poison(et):
            return POISON
        j = join(tt, et)
        if j is None:
            self.error(e, f"the branches of if have different types: {tt} and {et}")
            return POISON
        return j

    def bind_name(self, node: ast.Expr, name: str) -> None:
        if name in RESERVED_NAMES:
            self.error(node, f"{name} is reserved and cannot be bound")

    def infer_Let(self, e: ast.Let, ctx: Ctx, expected: Type | None) -> Type:
        self.bind_name(e, e.name)
        vt = self.infer(e.value, ctx)
        ctx.scopes.append({e.name: (vt, e)})
        try:
            return self.infer(e.body, ctx, expected)
        finally:
            ctx.scopes.pop()

    def infer_Comprehension(self, e: ast.Comprehension, ctx: Ctx, expected: Type | None) -> Type:
        self.bind_name(e, e.var)
        elem: Type
        if self.is_set_syntax(e.iterable, ctx):
            elem = self.set_iterable(e, ctx)
        else:
            it = self.infer(e.iterable, ctx)
            if isinstance(it, ListT):
                elem = it.elem
            elif is_stringish(it):
                elem = STRING
            elif isinstance(it, BytesT):
                elem = INT
            elif isinstance(it, MapT):
                elem = it.key
            elif is_any(it):
                elem = it
            else:
                self.error(
                    e.iterable,
                    f"{e.kind}(...) ranges over a list, string, bytes or map, but this is {it}",
                )
                elem = POISON
        ctx.scopes.append({e.var: (elem, e)})
        try:
            bt = self.infer(e.body, ctx)
        finally:
            ctx.scopes.pop()
        if e.kind in ("all", "exists", "count", "filter"):
            self.want_bool(e.body, bt, f"the body of {e.kind}(...)")
        if e.kind in ("all", "exists"):
            return BOOL
        if e.kind == "count":
            return INT
        if e.kind == "filter":
            return ListT(elem)
        if e.kind == "map":
            return ListT(bt)
        if is_any(bt):
            return bt
        if isinstance(bt, QErrT):
            return QERR
        if is_integer(bt):
            return INT
        if is_numeric(bt):
            return REAL
        what = "adds" if e.kind == "sum" else "takes the largest of"
        self.error(e.body, f"{e.kind}(...) {what} numbers or qerr values, but the body is {bt}")
        return POISON

    def is_set_syntax(self, e: ast.Expr, ctx: Ctx) -> bool:
        """Is e written as a partition set (f16.all, f32.range(a, b), {v, ...}, | & -)?"""
        if isinstance(e, ast.SetLit):
            return True
        if isinstance(e, ast.Binary):
            if e.op in ("|", "&", "-"):
                return self.is_set_syntax(e.left, ctx) or self.is_set_syntax(e.right, ctx)
            return False
        return self.set_scalar(e, ctx) is not None

    def set_scalar(self, e: ast.Expr, ctx: Ctx) -> Type | None:
        """The scalar type T of a ``T.<set>`` or ``T.range(...)`` / ``T.pattern(...)`` node."""
        attr = e.func if isinstance(e, ast.Call) else e
        if not isinstance(attr, ast.Attribute) or not isinstance(attr.value, ast.Name):
            return None
        name = attr.value.id
        if self.binds_value(name, ctx) or name in ctx.hidden:
            return None
        st = scalar_type(name)
        if st is None:
            return None
        if isinstance(e, ast.Call):
            return st if has_set_constructor(st, attr.attr) else None
        return st if isinstance(type_constant(st, attr.attr), SetT) else None

    def set_iterable(self, e: ast.Comprehension, ctx: Ctx) -> Type:
        """Check a set ranged over by a comprehension; the type of its members."""
        it = e.iterable
        if ctx.aggregate_top is not e:
            self.error(
                it,
                f"{e.kind}(...) ranges over a set such as f16.all only as the top "
                "comprehension of an aggregate clause; elsewhere it ranges over a list, "
                "string, bytes or map",
            )
            self.poison(it)
            return POISON
        elem = next((t for n in ast.walk(it) if (t := self.set_scalar(n, ctx)) is not None), None)
        if elem is None:
            self.error(it, "the type of this set is unknown: start from a typed set, e.g. f16.all")
            self.poison(it)
            return POISON
        saved = ctx.kind
        ctx.kind = "partition_set"
        try:
            t = self.infer(it, ctx, SetT(elem))
        finally:
            ctx.kind = saved
        if isinstance(t, SetT):
            return t.elem
        if not is_any(t):
            self.error(it, f"{e.kind}(...) ranges over a set of {elem} values, but this is {t}")
        return POISON

    # calls

    def infer_args(
        self, e: ast.Call, ctx: Ctx
    ) -> tuple[list[Type], dict[str, tuple[Type, ast.Expr]]]:
        args = [self.infer(a, ctx) for a in e.args]
        kwargs = {k: (self.infer(v, ctx), v) for k, v in e.kwargs}
        return args, kwargs

    def fail_call(self, e: ast.Call, ctx: Ctx, node: ast.Node, message: str | None) -> Type:
        self.infer_args(e, ctx)
        self.poison(e.func)
        if message:
            self.error(node, message)
        return POISON

    def infer_Call(self, e: ast.Call, ctx: Ctx, expected: Type | None) -> Type:
        f = e.func
        if isinstance(f, ast.Name):
            name = f.id
            if self.binds_value(name, ctx):
                return self.fail_call(e, ctx, f, f"{name} is a value, not a function")
            if name == "old":
                return self.call_old(e, ctx)
            if ctx.fields_of is not None and name in self.observers_of(ctx.fields_of.name):
                return self.call_observer(e, ctx, ctx.fields_of, name, "field")
            if name in self.local_fns:
                return self.call_spec_fn(e, ctx, name)
            if name in PRELUDE_SIGNATURES:
                return self.call_prelude(e, ctx, name)
            if name in ("result", "self") or name in ctx.params:
                return self.fail_call(e, ctx, f, f"{name} is a value, not a function")
            options = [f"{ns}.{name}" for ns in NAMESPACES if f"{ns}.{name}" in PRELUDE_SIGNATURES]
            hint = f" (did you mean {' or '.join(options)}?)" if options else ""
            return self.fail_call(e, ctx, f, f"unknown function {name}{hint}")
        if isinstance(f, ast.Attribute):
            base = f.value
            if isinstance(base, ast.Name) and not self.binds_value(base.id, ctx):
                if base.id in NAMESPACES:
                    base.ty = ANY
                    name = f"{base.id}.{f.attr}"
                    if name not in PRELUDE_SIGNATURES:
                        what, members = NAMESPACES[base.id]
                        return self.fail_call(
                            e,
                            ctx,
                            f,
                            f"unknown function {name}: {base.id} holds {what}: "
                            + ", ".join(f"{base.id}.{n}" for n in members),
                        )
                    return self.call_prelude(e, ctx, name)
                st = scalar_type(base.id)
                if st is not None:
                    base.ty = st
                    return self.call_set_ctor(e, ctx, st, f.attr)
            vt = self.infer(base, ctx)
            if isinstance(vt, ModelT):
                return self.call_observer(e, ctx, vt, f.attr, "observer")
            if is_any(vt):
                return self.fail_call(e, ctx, f, None)
            return self.fail_call(
                e,
                ctx,
                f,
                f"{vt} has no function {f.attr}: only observers of models and "
                "interfaces can be called with '.'",
            )
        self.infer(f, ctx)
        return self.fail_call(e, ctx, f, "only functions and observers can be called")

    def call_old(self, e: ast.Call, ctx: Ctx) -> Type:
        f = e.func
        if len(e.args) != 1 or e.kwargs or e.type_args:
            self.error(e, "old takes one expression: old(e)")
        elif ctx.in_old:
            self.error(e, "old(...) cannot be nested")
        elif not ctx.allow_old:
            self.error(e, ctx.no_old)
        saved = ctx.in_old, ctx.old_scope
        ctx.in_old, ctx.old_scope = True, len(ctx.scopes)
        try:
            args, _ = self.infer_args(e, ctx)
        finally:
            ctx.in_old, ctx.old_scope = saved
        res = Resolution("old", "old")
        self.res[e] = res
        self.res[f] = res
        t = args[0] if len(args) == 1 else POISON
        f.ty = FnT((t,), t)
        return t

    def bind_args(
        self,
        e: ast.Call,
        what: str,
        params: list[ast.Param],
        ptypes: Sequence[Type],
        args: list[Type],
        kwargs: dict[str, tuple[Type, ast.Expr]],
    ) -> list[tuple[str, Type, Type, ast.Expr]] | None:
        if len(args) > len(params):
            self.error(e, f"{what} takes {len(params)} argument(s), but {len(args)} are given")
            return None
        given: dict[str, tuple[str, Type, Type, ast.Expr]] = {}
        for p, pt, at, node in zip(params, ptypes, args, e.args, strict=False):
            given[p.name] = (p.name, pt, at, node)
        names = [p.name for p in params]
        for k, (kt, node) in kwargs.items():
            if k not in names:
                self.error(node, f"{what} has no parameter named {k}")
                return None
            if k in given:
                self.error(node, f"argument {k} of {what} is given twice")
                return None
            i = names.index(k)
            given[k] = (k, ptypes[i], kt, node)
        missing = [p.name for p in params if p.name not in given and p.default is None]
        if missing:
            self.error(e, f"{what} needs argument {', '.join(missing)}")
            return None
        return list(given.values())

    def call_spec_fn(self, e: ast.Call, ctx: Ctx, name: str) -> Type:
        f = e.func
        fn = self.local_fns[name]
        args, kwargs = self.infer_args(e, ctx)
        res = Resolution("spec_fn", name, fn)
        self.res[e] = res
        self.res[f] = res
        sig = self.spec.signature.get(fn)
        if sig is None:
            f.ty = POISON
            return POISON
        f.ty = sig
        if not ctx.allow_spec_fn:
            shadow = (
                " (it shadows the prelude function of the same name)"
                if name in PRELUDE_SIGNATURES
                else ""
            )
            self.error(
                e,
                f"{name}(...) calls the spec function {name}{shadow}; calls to spec "
                "functions are only allowed in relates and aggregate clauses, where each "
                "one is a planned implementation call",
            )
            return POISON
        if e.type_args:
            self.error(e, f"{name} takes no explicit type arguments")
        bound = self.bind_args(e, name, fn.params, sig.params, args, kwargs)
        if bound is None:
            return POISON
        tvars = self.spec.tparams.get(fn, {})
        subst: dict[str, Type] = {}
        for _, pt, at, _ in bound:
            self.bind_tvars(pt, at, subst, tvars)
        ok = True
        for tname, t in subst.items():
            tv = tvars[tname]
            if not satisfies(t, tv.bound):
                self.error(e, f"{name}: {t} does not satisfy {tv.name}: {tv.bound}")
                ok = False
        for pname, pt, at, node in bound:
            target = substitute(pt, subst)
            if not self.assignable(at, target, node):
                self.error(node, f"argument {pname} of {name} is a {target}, but this is {at}")
                ok = False
        unsolved: dict[str, Type] = {n: ANY for n in tvars if n not in subst}
        result = substitute(substitute(sig.result, subst), unsolved)
        return result if ok else POISON

    def bind_tvars(
        self, pattern: Type, actual: Type, subst: dict[str, Type], tvars: dict[str, TypeVarT]
    ) -> None:
        if isinstance(pattern, TypeVarT) and pattern.name in tvars:
            if is_any(actual):
                return
            prev = subst.get(pattern.name)
            if prev is None:
                subst[pattern.name] = actual
            else:
                j = join(prev, actual)
                if j is not None:
                    subst[pattern.name] = j
            return
        if isinstance(pattern, (ListT, OptionT, SetT)) and type(actual) is type(pattern):
            self.bind_tvars(pattern.elem, actual.elem, subst, tvars)  # type: ignore[attr-defined]
        elif isinstance(pattern, MapT) and isinstance(actual, MapT):
            self.bind_tvars(pattern.key, actual.key, subst, tvars)
            self.bind_tvars(pattern.value, actual.value, subst, tvars)
        elif isinstance(pattern, TupleT) and isinstance(actual, TupleT):
            for p, a in zip(pattern.elems, actual.elems, strict=False):
                self.bind_tvars(p, a, subst, tvars)
        elif isinstance(pattern, ModelT) and isinstance(actual, ModelT):
            for p, a in zip(pattern.args, actual.args, strict=False):
                self.bind_tvars(p, a, subst, tvars)

    def assignable(self, actual: Type, target: Type, node: ast.Expr | None = None) -> bool:
        """May a value of type actual be passed where target is expected?

        Fixed-width numeric targets accept any number: representability is
        checked when the value is passed.
        """
        if is_any(actual) or is_any(target) or actual == target:
            return True
        if isinstance(target, FixedIntT):
            return is_integer(actual) or isinstance(actual, RealT)
        if isinstance(target, FloatT):
            return is_numeric(actual)
        if isinstance(target, IntT):
            return is_integer(actual)
        if isinstance(target, RealT):
            return is_numeric(actual)
        if isinstance(target, LiteralT):
            if isinstance(actual, LiteralT):
                return set(actual.values) <= set(target.values)
            return isinstance(node, ast.Str) and node.value in target.values
        if isinstance(target, StringT):
            return is_stringish(actual)
        if isinstance(target, ListT) and isinstance(actual, ListT):
            subs = node.elems if isinstance(node, ast.ListLit) else []
            if subs:
                return all(self.assignable(x.ty or ANY, target.elem, x) for x in subs)
            return self.assignable(actual.elem, target.elem)
        if isinstance(target, OptionT) and isinstance(actual, OptionT):
            return self.assignable(actual.elem, target.elem)
        if isinstance(target, MapT) and isinstance(actual, MapT):
            return self.assignable(actual.key, target.key) and self.assignable(
                actual.value, target.value
            )
        if isinstance(target, TupleT) and isinstance(actual, TupleT):
            if len(target.elems) != len(actual.elems):
                return False
            subs = node.elems if isinstance(node, ast.TupleLit) else [None] * len(target.elems)
            return all(
                self.assignable(a, t, n)
                for a, t, n in zip(actual.elems, target.elems, subs, strict=True)
            )
        return False

    def call_prelude(self, e: ast.Call, ctx: Ctx, name: str) -> Type:
        f = e.func
        sig = PRELUDE_SIGNATURES[name]
        args, kwargs = self.infer_args(e, ctx)
        res = Resolution("prelude", name)
        self.res[e] = res
        self.res[f] = res
        targs = [self.resolve(t, ctx.tvars) for t in e.type_args]
        ok = True
        if sig.type_args != len(targs) and not (sig.optional_type_args and not targs):
            if sig.type_args and not targs:
                self.error(e, f"{name} needs a type argument: {sig.shape}")
            elif not sig.type_args:
                self.error(e, f"{name} takes no type arguments: {sig.shape}")
            else:
                self.error(e, f"{name} takes {sig.type_args} type argument(s): {sig.shape}")
            ok = False
        lo, hi = sig.arity
        if not lo <= len(args) <= hi:
            self.error(e, f"{name} takes {lo} argument{'s' if lo != 1 else ''}: {sig.shape}")
            ok = False
        for k, (_, node) in kwargs.items():
            if k not in sig.kwargs:
                self.error(node, f"{name} has no argument named {k}: {sig.shape}")
                ok = False
        if not ok:
            f.ty = POISON
            return POISON
        info = CallInfo(name, args, list(e.args), kwargs, targs, self.contains_float)
        try:
            t = sig.typer(info)
        except SigError as err:
            where: ast.Node = e
            if isinstance(err.where, int) and err.where < len(e.args):
                where = e.args[err.where]
            elif isinstance(err.where, str) and err.where in kwargs:
                where = kwargs[err.where][1]
            self.error(where, err.message)
            t = POISON
        f.ty = FnT(tuple(args), t)
        return t

    def call_set_ctor(self, e: ast.Call, ctx: Ctx, st: Type, attr: str) -> Type:
        f = e.func
        if attr not in SET_CONSTRUCTORS:
            if type_constant(st, attr) is not None:
                msg = f"{st}.{attr} is a constant, not a function: write {st}.{attr}"
            else:
                msg = f"{st} has no function {attr}"
            return self.fail_call(e, ctx, f, msg)
        if not has_set_constructor(st, attr):
            return self.fail_call(e, ctx, f, f"{st} has no {attr}(...) set")
        res = Resolution("set_ctor", attr, st)
        self.res[e] = res
        self.res[f] = res
        ok = ctx.kind == "partition_set"
        if not ok:
            self.error(
                e,
                f"{st}.{attr}(...) is a partition set: it only appears in a partition "
                f"class of a {st} parameter",
            )
        if attr == "range":
            if len(e.args) != 2 or e.kwargs:
                self.error(
                    e,
                    f"{st}.range takes two bounds: {st}.range(a, b), half-open, with "
                    "none for an open end",
                )
                ok = False
            for a in e.args:
                if isinstance(a, ast.NoneLit):
                    a.ty = OptionT(ANY)
                    continue
                t = self.infer(a, ctx)
                if not is_numeric(t) and not is_any(t):
                    self.error(a, f"a bound of {st}.range must be a number or none, not {t}")
                    ok = False
        else:
            if len(e.args) != 1 or e.kwargs or not isinstance(e.args[0], ast.Str):
                self.error(
                    e, f'{st}.pattern takes one string literal of bits, e.g. {st}.pattern("0 1* 0")'
                )
                ok = False
            for a in e.args:
                self.infer(a, ctx)
        for _, v in e.kwargs:
            self.infer(v, ctx)
        f.ty = FnT(tuple(a.ty or ANY for a in e.args), SetT(st))
        return SetT(st) if ok else POISON

    def call_observer(self, e: ast.Call, ctx: Ctx, mt: ModelT, name: str, kind: str) -> Type:
        f = e.func
        obs = self.observers_of(mt.name).get(name)
        if obs is None:
            available = ", ".join(self.observers_of(mt.name)) or "none"
            return self.fail_call(
                e, ctx, f, f"{mt.name} has no observer {name} (its observers: {available})"
            )
        args, kwargs = self.infer_args(e, ctx)
        res = Resolution(kind, name, mt.name)
        self.res[e] = res
        self.res[f] = res
        sig = self.spec.signature.get(obs)
        if sig is None:
            f.ty = POISON
            return POISON
        env = self.model_env(mt)
        f.ty = substitute(sig, env)
        if not obs.params:
            self.error(
                e,
                f"{name} is a field of {mt.name} and takes no arguments: "
                f"write {'x.' if kind == 'observer' else ''}{name}",
            )
            return POISON
        bound = self.bind_args(e, f"{mt.name}.{name}", obs.params, sig.params, args, kwargs)
        if bound is None:
            return POISON
        ok = True
        for pname, pt, at, node in bound:
            target = substitute(pt, env)
            if not self.assignable(at, target, node):
                self.error(
                    node, f"argument {pname} of {mt.name}.{name} is a {target}, but this is {at}"
                )
                ok = False
        return substitute(sig.result, env) if ok else POISON

    # attributes, indexing and literals

    def infer_Attribute(self, e: ast.Attribute, ctx: Ctx, expected: Type | None) -> Type:
        base = e.value
        if isinstance(base, ast.Name) and not self.binds_value(base.id, ctx):
            if base.id in NAMESPACES:
                base.ty = ANY
                name = f"{base.id}.{e.attr}"
                if name in PRELUDE_SIGNATURES:
                    self.error(e, f"{name} is a function: call it as {name}(x)")
                else:
                    self.error(e, f"unknown function {name}")
                return POISON
            st = scalar_type(base.id)
            if st is not None:
                base.ty = st
                return self.type_const(e, ctx, st)
            if base.id in self.spec.enums:
                en = self.spec.enums[base.id]
                base.ty = en
                if e.attr not in en.members:
                    self.error(e, f"enum {en.name} has no member {e.attr}")
                    return POISON
                self.res[e] = Resolution("enum_member", e.attr, en.name)
                return en
        vt = self.infer(base, ctx)
        if isinstance(vt, ModelT):
            obs = self.observers_of(vt.name).get(e.attr)
            if obs is None:
                available = ", ".join(self.observers_of(vt.name)) or "none"
                self.error(e, f"{vt.name} has no observer {e.attr} (its observers: {available})")
                return POISON
            if obs.params:
                self.error(
                    e,
                    f"{e.attr} takes arguments: {e.attr}({', '.join(p.name for p in obs.params)})",
                )
                return POISON
            self.res[e] = Resolution("observer", e.attr, vt.name)
            return self.observer_type(vt, obs)
        if isinstance(vt, RecordT):
            for fname, ft in vt.fields:
                if fname == e.attr:
                    self.res[e] = Resolution("record_field", e.attr, vt.name)
                    return ft
            self.error(e, f"record {vt.name} has no field {e.attr}")
            return POISON
        if is_any(vt):
            return POISON
        if isinstance(vt, TupleT):
            self.error(e, "tuple fields are numbered: .0, .1, ...")
            return POISON
        self.error(e, f"{vt} has no field {e.attr}")
        return POISON

    def type_const(self, e: ast.Attribute, ctx: Ctx, st: Type) -> Type:
        attr = e.attr
        if has_set_constructor(st, attr):
            self.error(e, f"{st}.{attr} is called: {st}.{attr}(...)")
            return POISON
        t = type_constant(st, attr)
        if t is None:
            names = ", ".join(f"{st}.{n}" for n in constants_of(st))
            self.error(
                e, f"{st} has no constant {attr}" + (f" (available: {names})" if names else "")
            )
            return POISON
        self.res[e] = Resolution("type_const", attr, st)
        if isinstance(t, SetT) and ctx.kind != "partition_set":
            hint = CLASSIFIER_HINTS.get(attr) if isinstance(st, FloatT) else None
            self.error(
                e,
                f"{st}.{attr} is a partition set: it only appears in a partition "
                f"class of a {st} parameter"
                + (f"; in a clause, test the value with {hint}" if hint else ""),
            )
            return POISON
        return t

    def infer_TupleIndex(self, e: ast.TupleIndex, ctx: Ctx, expected: Type | None) -> Type:
        vt = self.infer(e.value, ctx)
        if isinstance(vt, TupleT):
            if e.index < len(vt.elems):
                return vt.elems[e.index]
            self.error(e, f".{e.index} is out of range for {vt}")
            return POISON
        if is_any(vt):
            return POISON
        self.error(e, f".{e.index} needs a tuple, but the value is {vt}")
        return POISON

    def want_int(self, node: ast.Expr, t: Type, what: str) -> None:
        if not is_integer(t) and not is_any(t):
            hint = " (use // for integer division)" if isinstance(t, RealT) else ""
            self.error(node, f"{what} must be an integer, but it is {t}{hint}")

    def infer_Index(self, e: ast.Index, ctx: Ctx, expected: Type | None) -> Type:
        vt = self.infer(e.value, ctx)
        it = self.infer(e.index, ctx)
        if isinstance(vt, MapT):
            bad = non_eq_part(vt.key)
            if bad is not None:
                self.error(e, self.eq_message("map lookup", vt.key, bad))
            elif join(it, vt.key) is None and not is_any(it):
                self.error(e.index, f"the keys of {vt} are {vt.key}, not {it}")
            return vt.value
        if isinstance(vt, (ListT, StringT, LiteralT, BytesT)):
            self.want_int(e.index, it, "an index")
            if isinstance(vt, ListT):
                return vt.elem
            return INT if isinstance(vt, BytesT) else STRING
        if is_any(vt):
            return POISON
        if isinstance(vt, TupleT):
            self.error(e, "tuple fields are selected with .0, .1, ..., not [i]")
            return POISON
        self.error(e, f"cannot index a {vt}")
        return POISON

    def infer_Slice(self, e: ast.Slice, ctx: Ctx, expected: Type | None) -> Type:
        vt = self.infer(e.value, ctx)
        self.want_int(e.start, self.infer(e.start, ctx), "a slice bound")
        self.want_int(e.stop, self.infer(e.stop, ctx), "a slice bound")
        if isinstance(vt, ListT | BytesT):
            return vt
        if is_stringish(vt):
            return STRING
        if is_any(vt):
            return POISON
        self.error(e, f"cannot slice a {vt}")
        return POISON

    def infer_ListLit(self, e: ast.ListLit, ctx: Ctx, expected: Type | None) -> Type:
        elem: Type = ANY
        ok = True
        for x in e.elems:
            xt = self.infer(x, ctx)
            if _is_poison(xt):
                ok = False
                continue
            j = join(elem, xt)
            if j is None:
                self.error(
                    x,
                    f"the elements of a list have one type, but this is {xt} and "
                    f"an earlier one is {elem}",
                )
                ok = False
            else:
                elem = j
        return ListT(elem) if ok else POISON

    def infer_TupleLit(self, e: ast.TupleLit, ctx: Ctx, expected: Type | None) -> Type:
        return TupleT(tuple(self.infer(x, ctx) for x in e.elems))

    def infer_SetLit(self, e: ast.SetLit, ctx: Ctx, expected: Type | None) -> Type:
        if ctx.kind != "partition_set" or not isinstance(expected, SetT):
            for x in e.elems:
                self.infer(x, ctx)
            self.error(
                e,
                "{...} is a partition set: it only appears in a partition class of a "
                "fixed-width parameter",
            )
            return POISON
        elem = expected.elem
        ok = True
        for x in e.elems:
            t = self.infer(x, ctx)
            if is_any(t):
                continue
            if isinstance(elem, FloatT):
                good = is_numeric(t)
            elif isinstance(elem, FixedIntT):
                good = is_integer(t)
            else:
                good = isinstance(t, BoolT)
            if not good:
                self.error(
                    x,
                    f"a member of a set of {elem} values must be a "
                    f"{'number' if is_numeric(elem) else elem}, not {t}",
                )
                ok = False
        return expected if ok else POISON


def check(file: ast.SpecFile, uses: Sequence[Spec] = ()) -> Spec:
    """Check a parsed file against the specs it uses; raises SpecCheckError with every error."""
    return Checker(file, uses).run()


def resolve_type(
    spec: Spec, texpr: ast.AnyTypeExpr | str, tvars: dict[str, TypeVarT] | None = None
) -> Type:
    """Resolve type syntax (or text such as "list<i64>") in a checked spec."""
    source = spec.source
    path = spec.path
    if isinstance(texpr, str):
        from spectest.lang.parser import parse_type

        source, path = texpr, "<type>"
        texpr = parse_type(texpr, path)
    diags: list[Diagnostic] = []

    def report(node: ast.Node, message: str) -> None:
        diags.append(Diagnostic.at(path, source, node.span, message))

    resolver = TypeResolver(report)
    resolver.load_spec(spec)
    t = resolver.resolve(texpr, tvars or {})
    if diags:
        raise SpecCheckError(diags)
    return t


__all__ = [
    "POISON", "Checker", "Ctx", "SpecCheckError", "SpecLangError", "TypeResolver", "check",
    "contains_model", "float_representable", "literal_value", "resolve_type",
]  # fmt: skip
