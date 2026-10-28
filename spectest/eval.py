"""The expression evaluator: clauses over runtime values.

``evaluate`` interprets a checked expression (``Expr.ty`` and
``spec.resolution`` come from spectest.lang) over the values of
spectest.values. Observers, planned calls and identity questions go through
an ``EvalContext`` supplied by the runtime. Evaluation raises only
``EvalError`` (or another ``SpecError`` from the context) and ``SkipClause``;
any other Python error is reported as an EvalError naming the expression
and its location.
"""

from __future__ import annotations

import heapq
import weakref
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from fractions import Fraction
from functools import lru_cache
from typing import Any, Protocol, runtime_checkable

from spectest import ast
from spectest import prelude as _prelude
from spectest.lang.spec import Spec
from spectest.prelude import collections as _collections
from spectest.prelude import floats as _floats
from spectest.prelude import reals as _reals
from spectest.types import (
    BoolT,
    BytesT,
    EnumT,
    FixedIntT,
    FloatT,
    IntT,
    ListT,
    LiteralT,
    MapT,
    OptionT,
    QErrT,
    RealT,
    RecordT,
    SetT,
    StringT,
    TupleT,
    Type,
    TypeVarT,
    UnitT,
    scalar_type,
    substitute,
)
from spectest.values import (
    EvalError,
    FloatValue,
    Handle,
    MapValue,
    QError,
    RecordValue,
    SkipClause,
    Some,
    SpecError,
    is_infinity,
)

__all__ = [
    "AggregateResult",
    "Env",
    "EvalContext",
    "NullContext",
    "coerce_arg",
    "default_value",
    "evaluate",
    "evaluate_aggregate",
    "explain",
    "format_value",
    "holds",
    "old_calls",
    "snapshot_olds",
    "source_text",
]

EXPLAIN_LIMIT = 16
EXPLAIN_VALUE_CHARS = 300
WORST_LIMIT = 20
_TEXT_IN_ERRORS = 100


@runtime_checkable
class EvalContext(Protocol):
    """What the evaluator asks of the runtime."""

    def observe(self, handle: Handle, observer: str, args: tuple) -> Any:
        """The value of an observer on a handle (lazy, cached by the runtime)."""
        ...

    def fields(self, handle: Handle) -> dict[str, Any]:
        """All zero-argument observers of a handle, for eq()."""
        ...

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        """A planned implementation call (in relates); may raise SkipClause."""
        ...

    def is_fresh(self, handle: Handle) -> bool: ...

    def same_object(self, a: Handle, b: Handle) -> bool: ...

    def shares_memory(self, a: Handle, b: Handle) -> bool: ...

    def members(self, s: Any, elem: Type) -> tuple[Iterable[Any], bool]:
        """The members of a set (a BDDSet of elem values) to visit, and whether they are a
        sample: all of them for a small set, a seeded sample of a large one."""
        ...


class NullContext:
    """A context with nothing to observe: every request is an EvalError."""

    def _none(self, what: str) -> EvalError:
        return EvalError(f"{what} is not available here: there is no implementation to ask")

    def observe(self, handle: Handle, observer: str, args: tuple) -> Any:
        raise self._none(f"observer {observer}")

    def fields(self, handle: Handle) -> dict[str, Any]:
        raise self._none("observing a handle")

    def call_spec_fn(self, name: str, args: tuple) -> Any:
        raise self._none(f"calling {name}")

    def is_fresh(self, handle: Handle) -> bool:
        raise self._none("fresh")

    def same_object(self, a: Handle, b: Handle) -> bool:
        raise self._none("same_object")

    def shares_memory(self, a: Handle, b: Handle) -> bool:
        raise self._none("shares_memory")

    def members(self, s: Any, elem: Type) -> tuple[Iterable[Any], bool]:
        raise self._none(f"ranging over a set of {elem} values")


@dataclass
class Env:
    """The values a clause sees.

    ``values`` holds parameters, "result" and "self" (and, optionally,
    locals by name). ``olds`` holds the pre-state value of each old(...) call,
    or the exception its evaluation raised. ``fields`` is the handle that bare
    field names refer to inside invariants. ``tenv`` instantiates type
    variables (e.g. {"T": i64}) wherever the evaluator needs concrete
    types: type arguments, the static types passed to the prelude, and
    explanations.
    """

    values: dict[str, Any]
    olds: dict[ast.Call, Any] = field(default_factory=dict)
    fields: Handle | None = None
    tenv: dict[str, Type] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Source text and locations


_ORIGINS: weakref.WeakKeyDictionary[Spec, dict[int, tuple[str, str]]] = weakref.WeakKeyDictionary()


def _origins(spec: Spec) -> dict[int, tuple[str, str]]:
    table = _ORIGINS.get(spec)
    if table is None:
        table = {}
        pending, seen = [spec], set()
        while pending:
            s = pending.pop(0)
            if id(s) in seen:
                continue
            seen.add(id(s))
            for node in ast.walk(s.file):
                table.setdefault(id(node), (s.path, s.source))
            pending.extend(s.uses)
        _ORIGINS[spec] = table
    return table


def _origin(spec: Spec, node: ast.Node) -> tuple[str, str]:
    """The path and source text of the file a node comes from."""
    if not spec.uses:
        return spec.path, spec.source
    return _origins(spec).get(id(node), (spec.path, spec.source))


def _location(spec: Spec, node: ast.Node) -> str:
    path, _ = _origin(spec, node)
    return f"{path}:{node.span.line}:{node.span.col}"


@lru_cache(maxsize=64)
def _lines(source: str) -> tuple[str, ...]:
    return tuple(source.split("\n"))


def _normalize(text: str) -> str:
    """Drop comments and collapse whitespace outside string literals."""
    out: list[str] = []
    in_str = escaped = in_comment = False
    pending_space = False
    for ch in text:
        if in_comment:
            if ch == "\n":
                in_comment = False
                pending_space = True
            continue
        if in_str:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == "#":
            in_comment = True
            continue
        if ch.isspace():
            pending_space = True
            continue
        if pending_space and out:
            out.append(" ")
        pending_space = False
        out.append(ch)
        if ch == '"':
            in_str = True
    return "".join(out)


def source_text(node: ast.Node, spec: Spec) -> str:
    """The source text of a node, comments dropped and whitespace collapsed."""
    span = node.span
    _, source = _origin(spec, node)
    lines = _lines(source)
    if span.line < 1 or span.line > len(lines) or span.end_line < span.line:
        return f"<{type(node).__name__.lower()}>"
    if span.line == span.end_line:
        text = lines[span.line - 1][span.col - 1 : span.end_col - 1]
    else:
        parts = [lines[span.line - 1][span.col - 1 :]]
        parts.extend(lines[span.line : span.end_line - 1])
        if span.end_line <= len(lines):
            parts.append(lines[span.end_line - 1][: span.end_col - 1])
        text = "\n".join(parts)
    return _normalize(text) or f"<{type(node).__name__.lower()}>"


def _short(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: limit - 3] + "..."


# ---------------------------------------------------------------------------
# Errors


def _located(exc: EvalError, node: ast.Node, spec: Spec) -> EvalError:
    message = str(exc)
    text = _short(source_text(node, spec), _TEXT_IN_ERRORS)
    where = _location(spec, node)
    err = EvalError(f"{message} (at {where}: {text})")
    err.message = message  # type: ignore[attr-defined]
    err.location = where  # type: ignore[attr-defined]
    err.node = node  # type: ignore[attr-defined]
    return err


def _is_located(exc: BaseException) -> bool:
    return getattr(exc, "location", None) is not None


def _is_control_flow(exc: BaseException) -> bool:
    """Exceptions of the test engine (Hypothesis) pass through untouched."""
    return type(exc).__module__.split(".")[0] == "hypothesis"


# ---------------------------------------------------------------------------
# Evaluation


def _is_bool(v: Any) -> bool:
    return v is True or v is False


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _numeric_result(v: Any, t: Type | None) -> Any:
    if isinstance(t, RealT) and _is_int(v):
        return Fraction(v)
    if isinstance(t, IntT) and isinstance(v, Fraction) and v.denominator == 1:
        return int(v)
    return v


_ARITH: dict[str, Callable[[Any, Any], Any]] = {
    "+": _reals.add,
    "-": _reals.sub,
    "*": _reals.mul,
    "/": _reals.truediv,
    "//": _reals.floordiv,
    "%": _reals.mod,
}
_COMPARE: dict[str, Callable[[int], bool]] = {
    "<": lambda c: c < 0,
    "<=": lambda c: c <= 0,
    ">": lambda c: c > 0,
    ">=": lambda c: c >= 0,
}


def _kind(v: Any) -> str:
    if isinstance(v, (tuple, list)):
        return f"a list of length {len(v)}"
    if isinstance(v, str):
        return f"a string of length {len(v)}"
    if isinstance(v, bytes):
        return f"bytes of length {len(v)}"
    return format_value(v)


def _elements(v: Any, what: str) -> Sequence[Any] | bytes:
    if isinstance(v, (tuple, list, bytes)):
        return v
    if isinstance(v, str):
        return tuple(v)
    if isinstance(v, MapValue):
        return tuple(k for k, _ in v.items)
    raise EvalError(f"{what} ranges over a list, string, bytes or map, but got {format_value(v)}")


def _map_lookup(m: MapValue, key: Any) -> Any:
    for k, v in m.items:
        if _floats.same(k, key):
            return v
    raise EvalError(f"key {format_value(key)} is not in the map")


class _Evaluator:
    """Evaluates expressions of one spec in one environment."""

    def __init__(self, env: Env, spec: Spec, ctx: Any) -> None:
        self.env = env
        self.spec = spec
        self.ctx = ctx
        self.locals: dict[ast.Node, Any] = {}

    # -- dispatch ----------------------------------------------------------

    def eval(self, e: ast.Expr) -> Any:
        try:
            method = _DISPATCH.get(type(e))
            if method is None:
                raise EvalError(f"cannot evaluate a {type(e).__name__} node")
            return method(self, e)
        except SkipClause:
            raise
        except EvalError as exc:
            if _is_located(exc):
                raise
            raise _located(exc, e, self.spec) from exc
        except SpecError:
            raise
        except Exception as exc:
            if _is_control_flow(exc):
                raise
            message = f"{type(exc).__name__}: {exc}"
            raise _located(EvalError(message), e, self.spec) from exc

    def text(self, node: ast.Node) -> str:
        return source_text(node, self.spec)

    def bool_of(self, e: ast.Expr, what: str) -> bool:
        v = self.eval(e)
        if not _is_bool(v):
            raise _located(
                EvalError(f"{what} must be a bool, but it is {format_value(v)}"), e, self.spec
            )
        return v

    def type_of(self, e: ast.Expr) -> Type | None:
        t = e.ty
        if t is not None and self.env.tenv:
            t = substitute(t, self.env.tenv)
        return t

    def bind(self, binder: ast.Node, value: Any) -> object:
        previous = self.locals.get(binder, _UNBOUND)
        self.locals[binder] = value
        return previous

    def unbind(self, binder: ast.Node, previous: object) -> None:
        if previous is _UNBOUND:
            self.locals.pop(binder, None)
        else:
            self.locals[binder] = previous

    # -- literals ------------------------------------------------------------

    def Num(self, e: ast.Num) -> Any:
        return e.value

    def Str(self, e: ast.Str) -> Any:
        return e.value

    def BoolLit(self, e: ast.BoolLit) -> Any:
        return e.value

    def NoneLit(self, e: ast.NoneLit) -> Any:
        return None

    def ListLit(self, e: ast.ListLit) -> Any:
        return tuple(self.eval(x) for x in e.elems)

    def TupleLit(self, e: ast.TupleLit) -> Any:
        return tuple(self.eval(x) for x in e.elems)

    def SetLit(self, e: ast.SetLit) -> Any:
        raise EvalError("{...} is a partition set: it has no value in a clause")

    # -- names ---------------------------------------------------------------

    def handle_for_fields(self) -> Handle:
        h = self.env.fields
        if h is None:
            h = self.env.values.get("self")
        if not isinstance(h, Handle):
            raise EvalError("field names need the handle whose fields they are (Env.fields)")
        return h

    def value_named(self, name: str, what: str) -> Any:
        try:
            return self.env.values[name]
        except KeyError:
            raise EvalError(f"no value for {what} {name}") from None

    def Name(self, e: ast.Name) -> Any:
        r = self.spec.resolution.get(e)
        if r is None:
            raise EvalError(f"{e.id} has no value: the checker did not resolve it")
        kind = r.kind
        if kind == "local":
            v = self.locals.get(r.detail, _UNBOUND)
            if v is _UNBOUND:
                return self.value_named(e.id, "the local")
            return v
        if kind == "param":
            return self.value_named(e.id, "the parameter")
        if kind == "result":
            return self.value_named("result", "the")
        if kind == "self":
            v = self.env.values.get("self", _UNBOUND)
            if v is _UNBOUND:
                if self.env.fields is not None:
                    return self.env.fields
                raise EvalError("no value for self")
            return v
        if kind == "field":
            return self.ctx.observe(self.handle_for_fields(), e.id, ())
        if kind == "enum_member":
            return r.name
        if kind == "class":
            cls = r.detail
            if isinstance(cls, ast.PartitionClass) and isinstance(cls.expr.ty, BoolT):
                return self.eval(cls.expr)
            raise EvalError(f"class {e.id} is a partition set: it has no value in a clause")
        raise EvalError(f"{e.id} ({kind}) cannot be evaluated as a value")

    # -- operators -----------------------------------------------------------

    def Unary(self, e: ast.Unary) -> Any:
        if e.op == "not":
            return not self.bool_of(e.operand, "the operand of not")
        v = self.eval(e.operand)
        return _numeric_result(_reals.neg(v), self.type_of(e))

    def Binary(self, e: ast.Binary) -> Any:
        op = e.op
        if op == "implies":
            if not self.bool_of(e.left, "the left operand of implies"):
                return True
            return self.bool_of(e.right, "the right operand of implies")
        if op == "and":
            if not self.bool_of(e.left, "the left operand of and"):
                return False
            return self.bool_of(e.right, "the right operand of and")
        if op == "or":
            if self.bool_of(e.left, "the left operand of or"):
                return True
            return self.bool_of(e.right, "the right operand of or")
        t = self.type_of(e)
        if op in ("|", "&") or isinstance(t, SetT):
            raise EvalError(f"{op} combines partition sets: it has no value in a clause")
        a = self.eval(e.left)
        b = self.eval(e.right)
        if op != "in" and (isinstance(a, QError) or isinstance(b, QError)):
            return _qerr_binary(op, a, b)
        if op == "==":
            return _floats.same(a, b)
        if op == "!=":
            return not _floats.same(a, b)
        if op in _COMPARE:
            return _COMPARE[op](_collections.compare_values(a, b, op, promote=True))
        if op == "in":
            return _contains(b, a)
        if op == "+":
            joined = _concat(a, b)
            if joined is not None:
                return joined
        fn = _ARITH.get(op)
        if fn is None:
            raise EvalError(f"unknown operator {op}")
        return _numeric_result(fn(a, b), t)

    def If(self, e: ast.If) -> Any:
        if self.bool_of(e.cond, "the condition of if"):
            return self.eval(e.then)
        return self.eval(e.else_)

    def Let(self, e: ast.Let) -> Any:
        previous = self.bind(e, self.eval(e.value))
        try:
            return self.eval(e.body)
        finally:
            self.unbind(e, previous)

    def items(self, e: ast.Comprehension) -> Iterable[Any]:
        """What a comprehension ranges over: a collection's elements, or a set's members."""
        t = self.type_of(e.iterable)
        if isinstance(t, SetT):
            members, _ = self.members(e.iterable, t.elem)
            return members
        return _elements(self.eval(e.iterable), f"{e.kind}(...)")

    def members(self, iterable: ast.Expr, elem: Type) -> tuple[Iterable[Any], bool]:
        members = getattr(self.ctx, "members", None)
        if members is None:
            raise EvalError(f"ranging over a set of {elem} values needs ctx.members")
        return members(_compiled_set(iterable, elem, self.spec), elem)

    def Comprehension(self, e: ast.Comprehension) -> Any:
        kind = e.kind
        items = self.items(e)
        what = f"the body of {kind}(...)"
        previous = self.locals.get(e, _UNBOUND)
        try:
            if kind == "all":
                for x in items:
                    self.locals[e] = x
                    if not self.bool_of(e.body, what):
                        return False
                return True
            if kind == "exists":
                for x in items:
                    self.locals[e] = x
                    if self.bool_of(e.body, what):
                        return True
                return False
            if kind == "count":
                n = 0
                for x in items:
                    self.locals[e] = x
                    if self.bool_of(e.body, what):
                        n += 1
                return n
            if kind == "filter":
                kept = []
                for x in items:
                    self.locals[e] = x
                    if self.bool_of(e.body, what):
                        kept.append(x)
                return tuple(kept)
            if kind == "map":
                out = []
                for x in items:
                    self.locals[e] = x
                    out.append(self.eval(e.body))
                return tuple(out)
            if kind == "sum":
                t = self.type_of(e)
                total: Any = QError.ZERO if isinstance(t, QErrT) else 0
                for x in items:
                    self.locals[e] = x
                    total = _add_term(total, self.eval(e.body))
                return _numeric_result(total, t)
            if kind == "max":
                best: Any = _UNBOUND
                for x in items:
                    self.locals[e] = x
                    v = _term(self.eval(e.body))
                    best = v if best is _UNBOUND else _larger(best, v)
                if best is _UNBOUND:
                    raise EvalError("max(...) of no elements has no value")
                return _numeric_result(best, self.type_of(e))
            raise EvalError(f"unknown comprehension {kind}")
        finally:
            self.unbind(e, previous)

    # -- indexing --------------------------------------------------------------

    def Index(self, e: ast.Index) -> Any:
        v = self.eval(e.value)
        i = self.eval(e.index)
        if isinstance(v, MapValue):
            return _map_lookup(v, i)
        if not isinstance(v, (tuple, list, str, bytes)):
            raise EvalError(f"cannot index {format_value(v)}")
        if not _is_int(i):
            raise EvalError(f"an index must be an integer, but it is {format_value(i)}")
        if not 0 <= i < len(v):
            raise EvalError(f"index {i} is out of range for {_kind(v)}")
        return v[i]

    def Slice(self, e: ast.Slice) -> Any:
        v = self.eval(e.value)
        a = self.eval(e.start)
        b = self.eval(e.stop)
        if not isinstance(v, (tuple, list, str, bytes)):
            raise EvalError(f"cannot slice {format_value(v)}")
        for bound in (a, b):
            if not _is_int(bound):
                raise EvalError(
                    f"a slice bound must be an integer, but it is {format_value(bound)}"
                )
        if not 0 <= a <= b <= len(v):
            raise EvalError(
                f"slice [{a}:{b}] is out of range for {_kind(v)} (need 0 <= a <= b <= len)"
            )
        out = v[a:b]
        return tuple(out) if isinstance(out, list) else out

    def TupleIndex(self, e: ast.TupleIndex) -> Any:
        v = self.eval(e.value)
        if not isinstance(v, (tuple, list)):
            raise EvalError(f".{e.index} needs a tuple, but the value is {format_value(v)}")
        if not 0 <= e.index < len(v):
            raise EvalError(f".{e.index} is out of range for a tuple of {len(v)} elements")
        return v[e.index]

    # -- attributes --------------------------------------------------------------

    def Attribute(self, e: ast.Attribute) -> Any:
        r = self.spec.resolution.get(e)
        kind = r.kind if r is not None else None
        if kind == "enum_member":
            return r.name  # type: ignore[union-attr]
        if kind == "type_const":
            if isinstance(e.ty, SetT):
                raise EvalError(
                    f"{source_text(e, self.spec)} is a partition set: it has no value in a clause"
                )
            return _prelude.type_const(r.detail, e.attr)  # type: ignore[union-attr]
        if kind == "observer":
            h = self.eval(e.value)
            if not isinstance(h, Handle):
                raise EvalError(f"observer {e.attr} needs a handle, but got {format_value(h)}")
            return self.ctx.observe(h, e.attr, ())
        if kind == "record_field":
            rec = self.eval(e.value)
            if not isinstance(rec, RecordValue):
                raise EvalError(f".{e.attr} needs a record, but got {format_value(rec)}")
            try:
                return rec.get(e.attr)
            except KeyError:
                raise EvalError(f"record {rec.name} has no field {e.attr}") from None
        if kind == "set_ctor":
            raise EvalError(f"{source_text(e, self.spec)} is a partition set constructor")
        if kind == "prelude":
            raise EvalError(f"{r.name} is a function: call it")  # type: ignore[union-attr]
        raise EvalError(f".{e.attr} cannot be evaluated: the checker did not resolve it")

    # -- calls -----------------------------------------------------------------

    def Call(self, e: ast.Call) -> Any:
        r = self.spec.resolution.get(e) or self.spec.resolution.get(e.func)
        if r is None:
            raise EvalError("this call cannot be evaluated: the checker did not resolve it")
        kind = r.kind
        if kind == "prelude":
            return self.call_prelude(e, r.name)
        if kind == "old":
            return self.call_old(e)
        if kind == "spec_fn":
            return self.call_spec_fn(e, r.name, r.detail)
        if kind == "observer":
            if not isinstance(e.func, ast.Attribute):
                raise EvalError(f"observer call {r.name} has no handle")
            h = self.eval(e.func.value)
            return self.call_observer(e, h, r.detail, r.name)
        if kind == "field":
            return self.call_observer(e, self.handle_for_fields(), r.detail, r.name)
        if kind == "set_ctor":
            raise EvalError(f"{source_text(e.func, self.spec)}(...) is a partition set")
        raise EvalError(f"a {kind} cannot be called")

    def type_arg(self, texpr: ast.AnyTypeExpr) -> Type:
        tenv = self.env.tenv
        if isinstance(texpr, ast.TypeExpr) and not texpr.args:
            if texpr.name in tenv:
                return tenv[texpr.name]
            st = scalar_type(texpr.name)
            if st is not None:
                return st
        if not tenv and texpr in _TYPE_ARGS:
            return _TYPE_ARGS[texpr]
        tvars = {n: TypeVarT(n) for n in tenv}
        try:
            t = self.spec.resolve_type(texpr, tvars)
        except SpecError as exc:
            raise EvalError(f"cannot resolve the type argument: {exc}") from None
        if not tenv:
            _TYPE_ARGS[texpr] = t
            return t
        return substitute(t, tenv)

    def call_prelude(self, e: ast.Call, name: str) -> Any:
        args = [self.eval(a) for a in e.args]
        kwargs = {k: self.eval(v) for k, v in e.kwargs}
        type_args = [self.type_arg(t) for t in e.type_args]
        arg_types = [self.type_of(a) for a in e.args]
        return _prelude.call(
            name, args, kwargs=kwargs, type_args=type_args, arg_types=arg_types, ctx=self.ctx
        )

    def call_old(self, e: ast.Call) -> Any:
        if e not in self.env.olds:
            raise EvalError(
                "old(...) has no snapshot of the state before the call "
                "(snapshot_olds must run before the call)"
            )
        v = self.env.olds[e]
        if isinstance(v, BaseException):
            raise v.with_traceback(None)
        return v

    def bound_args(
        self, e: ast.Call, params: Sequence[ast.Param], ptypes: Sequence[Type], what: str
    ) -> tuple[Any, ...]:
        if len(e.args) > len(params):
            raise EvalError(f"{what} takes {len(params)} argument(s), but {len(e.args)} are given")
        values: dict[str, Any] = {}
        for p, a in zip(params, e.args, strict=False):
            values[p.name] = self.eval(a)
        for k, v in e.kwargs:
            values[k] = self.eval(v)
        out = []
        for p, t in zip(params, ptypes, strict=False):
            if p.name in values:
                v = values[p.name]
            elif p.default is not None:
                v = default_value(p, self.spec)
            else:
                raise EvalError(f"{what} needs argument {p.name}")
            out.append(coerce_arg(v, t, f"argument {p.name} of {what}"))
        return tuple(out)

    def call_spec_fn(self, e: ast.Call, name: str, fn: Any) -> Any:
        if not isinstance(fn, ast.FnDecl) or fn not in self.spec.signature:
            raise EvalError(f"{name} is not a spec function of this spec")
        sig = self.spec.signature[fn]
        args = self.bound_args(e, fn.params, sig.params, name)
        return self.ctx.call_spec_fn(name, args)

    def call_observer(self, e: ast.Call, h: Any, model: str, name: str) -> Any:
        if not isinstance(h, Handle):
            raise EvalError(f"observer {name} needs a handle, but got {format_value(h)}")
        try:
            obs = self.spec.observers(model)[name]
        except KeyError:
            raise EvalError(f"{model} has no observer {name}") from None
        sig = self.spec.signature.get(obs)
        ptypes = sig.params if sig is not None else tuple(None for _ in obs.params)
        args = self.bound_args(e, obs.params, ptypes, f"{model}.{name}")  # type: ignore[arg-type]
        return self.ctx.observe(h, name, args)


_UNBOUND = object()
_TYPE_ARGS: weakref.WeakKeyDictionary[ast.Node, Type] = weakref.WeakKeyDictionary()
_DEFAULTS: weakref.WeakKeyDictionary[ast.Param, Any] = weakref.WeakKeyDictionary()

_DISPATCH: dict[type, Callable[[_Evaluator, Any], Any]] = {
    cls: getattr(_Evaluator, cls.__name__)
    for cls in (
        ast.Num, ast.Str, ast.BoolLit, ast.NoneLit, ast.ListLit, ast.TupleLit, ast.SetLit,
        ast.Name, ast.Unary, ast.Binary, ast.If, ast.Let, ast.Comprehension, ast.Index,
        ast.Slice, ast.TupleIndex, ast.Attribute, ast.Call,
    )
}  # fmt: skip


def _contains(container: Any, x: Any) -> bool:
    if isinstance(container, (tuple, list)):
        return any(_floats.same(x, y) for y in container)
    if isinstance(container, MapValue):
        return any(_floats.same(x, k) for k, _ in container.items)
    if isinstance(container, str):
        if not isinstance(x, str):
            raise EvalError(f"in on a string looks for a substring, not {format_value(x)}")
        return x in container
    if isinstance(container, bytes):
        if _is_int(x) or isinstance(x, bytes):
            return x in container
        raise EvalError(f"in on bytes looks for a byte or a byte string, not {format_value(x)}")
    raise EvalError(f"in needs a list, map or string on the right, not {format_value(container)}")


def _qerr_parts(v: Any) -> tuple[Any, int]:
    """(steps, nans) of a qerr; a number c reads as c + 0·nan."""
    if isinstance(v, QError):
        return v.steps, v.nans
    if isinstance(v, FloatValue):
        return _floats.to_real(v, "qerr comparison"), 0
    if _is_int(v) or isinstance(v, Fraction) or is_infinity(v):
        return v, 0
    raise EvalError(f"a qerr compares with a qerr or a number, not {format_value(v)}")


def _qerr_binary(op: str, a: Any, b: Any) -> Any:
    """qerr + qerr, and comparisons of a qerr with a qerr or a number (componentwise)."""
    if op == "+":
        if isinstance(a, QError) and isinstance(b, QError):
            return a + b
        raise EvalError(f"+ adds two qerr values, not {format_value(a)} and {format_value(b)}")
    if op in ("==", "!=") and isinstance(a, QError) and isinstance(b, QError):
        return _floats.same(a, b) == (op == "==")
    if op not in ("==", "!=", "<", "<=", ">", ">="):
        raise EvalError(f"{op} is not defined on qerr values")
    (sa, na), (sb, nb) = _qerr_parts(a), _qerr_parts(b)
    c = _reals.compare(sa, sb, op)
    equal = c == 0 and na == nb
    if op == "==":
        return equal
    if op == "!=":
        return not equal
    below = c <= 0 and na <= nb
    above = c >= 0 and na >= nb
    if op == "<=":
        return below
    if op == ">=":
        return above
    return (below if op == "<" else above) and not equal


def _term(v: Any) -> Any:
    """A sum or max term: a qerr or a number (a float promotes; NaN is an EvalError)."""
    if isinstance(v, FloatValue):
        return _floats.to_real(v, "a term")
    if isinstance(v, QError) or _is_int(v) or isinstance(v, Fraction) or is_infinity(v):
        return v
    raise EvalError(f"a term must be a number or a qerr, but it is {format_value(v)}")


def _add_term(total: Any, v: Any) -> Any:
    v = _term(v)
    if isinstance(total, QError) or isinstance(v, QError):
        if not (isinstance(total, QError) and isinstance(v, QError)):
            raise EvalError(f"cannot add {format_value(v)} to the qerr {format_value(total)}")
        return total + v
    return _reals.add(total, v)


def _larger(a: Any, b: Any) -> Any:
    if isinstance(a, QError) and isinstance(b, QError):
        return a.max(b)
    return b if _reals.compare(a, b, "max") < 0 else a


_SETS: weakref.WeakKeyDictionary[ast.Node, Any] = weakref.WeakKeyDictionary()


def _compiled_set(expr: ast.Expr, elem: Type, spec: Spec) -> Any:
    """The BDDSet a set expression denotes (cached per node)."""
    s = _SETS.get(expr)
    if s is None:
        from spectest import sets

        try:
            s = sets.compile_set(expr, elem, aliases=spec.aliases)
        except sets.SetError as exc:
            raise EvalError(f"cannot compile the set: {exc.message}") from None
        _SETS[expr] = s
    return s


def _concat(a: Any, b: Any) -> Any:
    if isinstance(a, (tuple, list)) and isinstance(b, (tuple, list)):
        return tuple(a) + tuple(b)
    if isinstance(a, str) and isinstance(b, str):
        return a + b
    if isinstance(a, bytes) and isinstance(b, bytes):
        return a + b
    return None


# ---------------------------------------------------------------------------
# Public entry points


def evaluate(expr: ast.Expr, env: Env, spec: Spec, ctx: Any) -> Any:
    """The value of a checked expression; raises EvalError (or another SpecError) or SkipClause."""
    return _Evaluator(env, spec, ctx).eval(expr)


def holds(clause: ast.Clause, env: Env, spec: Spec, ctx: Any) -> bool:
    """Does the clause's condition hold? A raises/may_raise without ``when`` always holds.

    An aggregate clause is judged by evaluate_aggregate (env is not used).
    """
    if clause.kind == "aggregate":
        return evaluate_aggregate(clause, spec, ctx).holds
    if clause.expr is None:
        if clause.kind in ("raises", "may_raise"):
            return True
        raise EvalError(f"{clause.id or clause.kind}: a {clause.kind} clause has no condition")
    ev = _Evaluator(env, spec, ctx)
    v = ev.eval(clause.expr)
    if not _is_bool(v):
        raise _located(
            EvalError(f"the clause must evaluate to a bool, but it is {format_value(v)}"),
            clause.expr,
            spec,
        )
    return v


@dataclass
class AggregateResult:
    """The verdict of an aggregate clause over the members of its set.

    ``value`` is the sum or max of the evaluated terms (a QError or a number;
    None for a max whose terms were all skipped), or for ``all(...)`` the number
    of members where the predicate is false. ``bound`` is the constant c (0 for
    ``all`` and ``== 0``). ``worst`` holds (member, term) pairs with the largest
    non-zero terms, largest first and in visiting order among equals (for
    ``all``: the failing members, with term False), at most WORST_LIMIT.
    ``total`` is the number of members of the set, ``evaluated + skipped`` the
    number visited, and ``sampled`` says whether they were a sample.
    """

    holds: bool
    value: Any
    bound: Any
    evaluated: int
    skipped: int
    total: int
    sampled: bool
    worst: list[tuple[Any, Any]] = field(default_factory=list)


def _aggregate_parts(clause: ast.Clause) -> tuple[ast.Comprehension, str | None, ast.Expr | None]:
    e = clause.expr
    if isinstance(e, ast.Comprehension) and e.kind == "all":
        return e, None, None
    if (
        isinstance(e, ast.Binary)
        and isinstance(e.left, ast.Comprehension)
        and e.left.kind in ("sum", "max")
        and e.op in ("<=", "<", "==")
    ):
        return e.left, e.op, e.right
    raise EvalError(
        f"{clause.id or 'aggregate'}: an aggregate clause is sum(v in S: e) <= c, < c or == 0, "
        "max(v in S: e) <= c or < c, or all(v in S: p)"
    )


def _rank(term: Any) -> tuple[Any, ...]:
    if isinstance(term, QError):
        return (term.nans, term.steps)
    if is_infinity(term):
        return (term.sign, 0)
    return (0, term)


def _is_zero_term(term: Any) -> bool:
    return (
        term == QError.ZERO if isinstance(term, QError) else (not is_infinity(term) and term == 0)
    )


def evaluate_aggregate(clause: ast.Clause, spec: Spec, ctx: Any) -> AggregateResult:
    """Evaluate an aggregate clause term by term over the members ``ctx.members`` gives.

    A term whose planned call raises SkipClause is skipped and counted; a
    negative term, or a max over no members, is an EvalError.
    """
    top, op, bound_expr = _aggregate_parts(clause)
    ev = _Evaluator(Env({}), spec, ctx)
    bound: Any = 0 if bound_expr is None else ev.eval(bound_expr)
    t = ev.type_of(top.iterable)
    if isinstance(t, SetT):
        from spectest import sets

        try:
            s = _compiled_set(top.iterable, t.elem, spec)
            members, sampled = ev.members(top.iterable, t.elem)
        except EvalError as exc:
            raise _located(exc, top.iterable, spec) from exc
        total = sets.set_size(s)
    else:
        members = _elements(ev.eval(top.iterable), f"{top.kind}(...)")
        sampled, total = False, len(members)
    kind = top.kind
    acc: Any = QError.ZERO if isinstance(ev.type_of(top), QErrT) else 0
    best: Any = None
    failures = evaluated = skipped = 0
    worst: list[tuple[Any, Any]] = []
    heap: list[tuple[tuple[Any, ...], int, Any, Any]] = []
    for i, member in enumerate(members):
        ev.locals[top] = member
        try:
            term = ev.eval(top.body)
        except SkipClause:
            skipped += 1
            continue
        evaluated += 1
        if kind == "all":
            if not _is_bool(term):
                raise _located(
                    EvalError(f"the body of all(...) must be a bool, not {format_value(term)}"),
                    top.body,
                    spec,
                )
            if not term:
                failures += 1
                if len(worst) < WORST_LIMIT:
                    worst.append((member, False))
            continue
        try:
            term = _term(term)
            if not isinstance(term, QError) and _reals.compare(term, 0) < 0:
                raise EvalError(
                    f"the term {format_value(term)} for {top.var} = {format_value(member)} is "
                    f"negative: the terms of an aggregate {kind}(...) are non-negative"
                )
        except EvalError as exc:
            raise _located(exc, top.body, spec) from exc
        if kind == "sum":
            acc = _add_term(acc, term)
        else:
            best = term if best is None else _larger(best, term)
        if not _is_zero_term(term):
            entry = (_rank(term), -i, member, term)
            if len(heap) < WORST_LIMIT:
                heapq.heappush(heap, entry)
            elif entry[:2] > heap[0][:2]:
                heapq.heapreplace(heap, entry)
    if kind == "all":
        return AggregateResult(
            failures == 0, failures, 0, evaluated, skipped, total, sampled, worst
        )
    worst = [(m, v) for _, _, m, v in sorted(heap, key=lambda x: x[:2], reverse=True)]
    if kind == "sum":
        value = _numeric_result(acc, ev.type_of(top))
    elif best is None:
        if evaluated + skipped == 0:
            raise _located(EvalError("max(...) over a set with no members has no value"), top, spec)
        value = None
    else:
        value = _numeric_result(best, ev.type_of(top))
    ok = True if value is None else _compare_bound(op or "<=", value, bound)
    return AggregateResult(ok, value, bound, evaluated, skipped, total, sampled, worst)


def _compare_bound(op: str, value: Any, bound: Any) -> bool:
    if isinstance(value, QError) or isinstance(bound, QError):
        return _qerr_binary(op, value, bound)
    c = _reals.compare(value, bound, op)
    return c < 0 if op == "<" else c <= 0 if op == "<=" else c == 0


def old_calls(expr: ast.Expr | None, spec: Spec | None = None) -> list[ast.Call]:
    """The old(...) calls in an expression, in source order.

    With a spec, calls are those the checker resolved as "old"; without one,
    calls of the reserved name ``old``.
    """
    if expr is None:
        return []
    out: list[ast.Call] = []
    for node in ast.walk(expr):
        if not isinstance(node, ast.Call):
            continue
        if spec is not None:
            r = spec.resolution.get(node)
            if r is not None and r.kind == "old":
                out.append(node)
        elif isinstance(node.func, ast.Name) and node.func.id == "old":
            out.append(node)
    return out


def _inner_local(arg: ast.Expr, spec: Spec) -> tuple[str, ast.Node] | None:
    """A variable that old(arg) uses but the clause binds outside arg, if any."""
    inside = {id(n) for n in ast.walk(arg)}
    for node in ast.walk(arg):
        if isinstance(node, ast.Name):
            r = spec.resolution.get(node)
            if r is not None and r.kind == "local" and id(r.detail) not in inside:
                return node.id, r.detail
    return None


OldPlan = list[tuple[ast.Call, str | None]]
_OLD_PLANS: weakref.WeakKeyDictionary[ast.Node, tuple[Any, OldPlan]] = (
    weakref.WeakKeyDictionary()
)


def _old_plan(expr: ast.Expr, spec: Spec) -> OldPlan:
    """The old(...) calls of a clause expression, each with the reason it cannot be
    evaluated before the call (None when it can). Computed once per expression and spec."""
    cached = _OLD_PLANS.get(expr)
    if cached is not None and cached[0]() is spec:
        return cached[1]
    plan: OldPlan = []
    for call in old_calls(expr, spec):
        if len(call.args) != 1:
            plan.append((call, "old takes one expression"))
            continue
        inner = _inner_local(call.args[0], spec)
        if inner is None:
            plan.append((call, None))
            continue
        name, binder = inner
        how = f"{binder.kind}(...)" if isinstance(binder, ast.Comprehension) else "let"
        problem = (
            f"old(...) cannot be evaluated before the call: its argument uses "
            f"{name}, which {how} binds inside the clause. Take old(...) of "
            f"the state itself, e.g. let xs = old(self.items) in ..."
        )
        plan.append((call, problem))
    _OLD_PLANS[expr] = (weakref.ref(spec), plan)
    return plan


def snapshot_olds(
    clauses: Iterable[ast.Clause], env: Env, spec: Spec, ctx: Any
) -> dict[ast.Call, Any]:
    """Evaluate every old(e) of the clauses on the pre-state.

    Each call maps to its value, or to the EvalError (or other SpecError,
    or SkipClause) that evaluating it raised; evaluating old(...) later
    re-raises it. Which calls a clause has is worked out once per clause.
    """
    out: dict[ast.Call, Any] = {}
    for clause in clauses:
        if clause.expr is None:
            continue
        for call, problem in _old_plan(clause.expr, spec):
            if call in out:
                continue
            if problem is not None:
                out[call] = _located(EvalError(problem), call, spec)
                continue
            try:
                out[call] = evaluate(call.args[0], env, spec, ctx)
            except (SpecError, SkipClause) as exc:
                out[call] = exc
    return out


def _param_type(param: ast.Param, spec: Spec) -> Type | None:
    for node, sig in spec.signature.items():
        params = getattr(node, "params", None)
        if not params:
            continue
        for i, p in enumerate(params):
            if p is param and i < len(sig.params):
                return sig.params[i]
    try:
        return spec.resolve_type(param.type)
    except SpecError:
        return None


def default_value(param: ast.Param, spec: Spec) -> Any:
    """The value of a parameter's default (a constant expression), as its parameter type."""
    if param.default is None:
        raise EvalError(f"parameter {param.name} has no default")
    if param in _DEFAULTS:
        return _DEFAULTS[param]
    v = evaluate(param.default, Env({}), spec, NullContext())
    t = _param_type(param, spec)
    v = v if t is None else coerce_arg(v, t, f"the default of {param.name}")
    _DEFAULTS[param] = v
    return v


# ---------------------------------------------------------------------------
# Coercion to parameter types


def _needs_coercion(t: Type) -> bool:
    if isinstance(t, (FixedIntT, FloatT)):
        return True
    if isinstance(t, (ListT, OptionT)):
        return _needs_coercion(t.elem)
    if isinstance(t, MapT):
        return _needs_coercion(t.key) or _needs_coercion(t.value)
    if isinstance(t, TupleT):
        return any(_needs_coercion(x) for x in t.elems)
    if isinstance(t, RecordT):
        return any(_needs_coercion(ft) for _, ft in t.fields)
    return False


def _to_float(value: Any, t: FloatT, what: str) -> FloatValue:
    if isinstance(value, FloatValue):
        if value.fmt == t.fmt:
            return value
        converted = _floats.convert(value, t)
        if _floats.convert(converted, value.fmt) == value:
            return converted
        raise EvalError(
            f"{what}: {format_value(value)} ({value.fmt}) is not exactly representable as {t}"
        )
    if is_infinity(value):
        return _floats.inf(t, value.sign < 0)
    if _is_int(value) or isinstance(value, Fraction):
        if _floats.fits(Fraction(value), t):
            return _floats.round_to(value, t)
        raise EvalError(f"{what}: {format_value(value)} is not exactly representable as {t}")
    raise EvalError(f"{what}: expected a number for {t}, got {format_value(value)}")


def _to_int(value: Any, t: FixedIntT, what: str) -> int:
    n: int | None = None
    if _is_int(value):
        n = value
    elif isinstance(value, Fraction) and value.denominator == 1:
        n = int(value)
    if n is None:
        raise EvalError(f"{what}: expected an integer for {t}, got {format_value(value)}")
    if not t.min <= n <= t.max:
        raise EvalError(f"{what}: {n} is out of range for {t} ({t.min} to {t.max})")
    return n


def coerce_arg(value: Any, t: Type | None, what: str = "argument") -> Any:
    """A value passed to a parameter of type t, made exact for fixed-width types.

    Fixed-width ints must be integers in range; floats must be exactly
    representable (ints, reals and floats of other formats convert).
    Collections are coerced element by element; every other type passes
    the value through. Raises EvalError when the value does not fit.
    """
    if t is None or not _needs_coercion(t):
        return value
    if isinstance(t, FixedIntT):
        return _to_int(value, t, what)
    if isinstance(t, FloatT):
        return _to_float(value, t, what)
    if isinstance(t, ListT) and isinstance(value, (tuple, list)):
        return tuple(coerce_arg(x, t.elem, what) for x in value)
    if isinstance(t, OptionT) and isinstance(value, Some):
        return Some(coerce_arg(value.value, t.elem, what))
    if isinstance(t, TupleT) and isinstance(value, (tuple, list)) and len(value) == len(t.elems):
        return tuple(coerce_arg(x, xt, what) for x, xt in zip(value, t.elems, strict=True))
    if isinstance(t, MapT) and isinstance(value, MapValue):
        return MapValue(
            tuple(
                (coerce_arg(k, t.key, what), coerce_arg(v, t.value, what)) for k, v in value.items
            )
        )
    if isinstance(t, RecordT) and isinstance(value, RecordValue):
        types = dict(t.fields)
        return RecordValue(
            value.name,
            tuple((n, coerce_arg(v, types.get(n), what)) for n, v in value.fields),
        )
    return value


# ---------------------------------------------------------------------------
# Formatting


_ESCAPES = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _escape_ascii(c: int) -> str:
    """An ASCII character inside a string or bytes literal: both use the same escapes."""
    ch = chr(c)
    if ch in _ESCAPES:
        return _ESCAPES[ch]
    if c < 0x20 or c == 0x7F:
        return f"\\x{c:02x}"
    return ch


def _quote(s: str) -> str:
    """A string literal: ASCII as in bytes, then ``\\u{..}`` for non-printable code points
    and for U+FFFD, so a replacement character is never mistaken for the original."""
    out = []
    for ch in s:
        c = ord(ch)
        if c < 0x80:
            out.append(_escape_ascii(c))
        elif not ch.isprintable() or ch == "\ufffd":
            out.append(f"\\u{{{c:x}}}")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _quote_bytes(b: bytes) -> str:
    return 'b"' + "".join(_escape_ascii(c) if c < 0x80 else f"\\x{c:02x}" for c in b) + '"'


def _format_fraction(r: Fraction) -> str:
    if r.denominator == 1:
        return str(r.numerator)
    text = _reals.format_real(r)
    if not text.startswith("~"):
        return text
    ratio = f"{r.numerator}/{r.denominator}"
    return f"{ratio} ({text})" if len(ratio) <= 24 else text


def _elem_types(t: Type | None, n: int) -> list[Type | None]:
    if isinstance(t, TupleT) and len(t.elems) == n:
        return list(t.elems)
    if isinstance(t, ListT):
        return [t.elem] * n
    return [None] * n


def _format(value: Any, t: Type | None, top: bool) -> str:
    if isinstance(t, TypeVarT):
        t = None
    if value is True or value is False:
        return "true" if value else "false"
    if value is None:
        return "unit" if isinstance(t, UnitT) else "none"
    if isinstance(value, FloatValue):
        if top:
            from spectest.sets import format_value as format_scalar

            return format_scalar(value)
        return _floats.format_float(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, Fraction):
        return _format_fraction(value)
    if is_infinity(value):
        return "+inf" if value.sign > 0 else "-inf"
    if isinstance(value, str):
        return value if isinstance(t, EnumT) else _quote(value)
    if isinstance(value, bytes):
        return _quote_bytes(value)
    if isinstance(value, (tuple, list)):
        types = _elem_types(t, len(value))
        inner = ", ".join(_format(x, xt, False) for x, xt in zip(value, types, strict=True))
        return f"({inner})" if isinstance(t, TupleT) else f"[{inner}]"
    if isinstance(value, Some):
        elem = t.elem if isinstance(t, OptionT) else None
        return f"some({_format(value.value, elem, False)})"
    if isinstance(value, MapValue):
        kt = t.key if isinstance(t, MapT) else None
        vt = t.value if isinstance(t, MapT) else None
        items = ", ".join(
            f"{_format(k, kt, False)}: {_format(v, vt, False)}" for k, v in value.items
        )
        return "{" + items + "}"
    if isinstance(value, RecordValue):
        types = dict(t.fields) if isinstance(t, RecordT) else {}
        body = ", ".join(f"{n}: {_format(v, types.get(n), False)}" for n, v in value.fields)
        return f"{value.name} {{ {body} }}" if body else f"{value.name} {{}}"
    if isinstance(value, Handle):
        return f"<{value.model} #{value.id}>"
    if isinstance(value, QError):
        return str(value)
    if isinstance(t, SetT):
        return f"<set of {t.elem}>"
    return repr(value)


def format_value(value: Any, t: Type | None = None) -> str:
    """A human-readable rendering of a runtime value for reports and messages.

    Floats show their shortest decimal and bit pattern (nested floats only the
    decimal), strings are quoted, bytes print as b"..", lists in brackets,
    tuples in parentheses, options as some(..) / none, handles as <Model #id>,
    reals as exact decimals when short and terminating, else a/b with an
    approximation.
    """
    try:
        return _format(value, t, True)
    except (TypeError, ValueError, LookupError, AttributeError, ArithmeticError, RecursionError):
        return repr(value)


# ---------------------------------------------------------------------------
# Explanations


class _Failure:
    """The error a sub-expression raised while it was being explained."""

    def __init__(self, exc: BaseException) -> None:
        self.exc = exc

    def __str__(self) -> str:
        if isinstance(self.exc, SkipClause):
            return f"skipped: {self.exc}"
        return f"error: {self.exc}"


_LITERALS = (ast.Num, ast.Str, ast.BoolLit, ast.NoneLit)
_COMPARISONS = ("==", "!=", "<", "<=", ">", ">=", "in")


def _is_literal(e: ast.Expr) -> bool:
    if isinstance(e, _LITERALS):
        return True
    if isinstance(e, ast.Unary) and e.op == "-":
        return _is_literal(e.operand)
    if isinstance(e, (ast.ListLit, ast.TupleLit)):
        return all(_is_literal(x) for x in e.elems)
    return False


def _chain(e: ast.Expr, op: str) -> list[ast.Expr]:
    if isinstance(e, ast.Binary) and e.op == op:
        return [*_chain(e.left, op), *_chain(e.right, op)]
    return [e]


class _Explainer:
    def __init__(self, ev: _Evaluator, limit: int) -> None:
        self.ev = ev
        self.limit = limit
        self.pairs: list[tuple[str, str]] = []
        self.seen: set[str] = set()

    def full(self) -> bool:
        return len(self.pairs) >= self.limit

    def value(self, e: ast.Expr) -> Any:
        try:
            return self.ev.eval(e)
        except (SpecError, SkipClause) as exc:
            return _Failure(exc)

    def add_text(self, text: str, value: Any, t: Type | None) -> None:
        if text in self.seen or self.full():
            return
        self.seen.add(text)
        shown = str(value) if isinstance(value, _Failure) else format_value(value, t)
        self.pairs.append((text, _short(shown, EXPLAIN_VALUE_CHARS)))

    def add(self, e: ast.Expr, value: Any = _UNBOUND) -> Any:
        text = self.ev.text(e)
        if text in self.seen or self.full():
            return value
        if value is _UNBOUND:
            value = self.value(e)
        self.add_text(text, value, self.ev.type_of(e))
        return value

    def operand(self, e: ast.Expr) -> None:
        """Show an operand's value, with the values that feed it when that helps."""
        if _is_literal(e):
            return
        if isinstance(e, ast.Call) and not self.is_old(e):
            for a in e.args:
                if not _is_literal(a):
                    self.add(a)
        elif isinstance(e, ast.Index):
            self.add(e.value)
            if not _is_literal(e.index):
                self.add(e.index)
        elif isinstance(e, ast.Slice):
            self.add(e.value)
            for bound in (e.start, e.stop):
                if not _is_literal(bound):
                    self.add(bound)
        elif isinstance(e, ast.If):
            self.add(e.cond)
        self.add(e)

    def is_old(self, e: ast.Call) -> bool:
        r = self.ev.spec.resolution.get(e)
        return r is not None and r.kind == "old"

    def walk(self, e: ast.Expr, value: Any) -> None:
        if self.full():
            return
        if isinstance(e, ast.Binary):
            if e.op in ("and", "or"):
                return self.walk_chain(e, value)
            if e.op == "implies":
                if value is False:
                    return self.walk(e.right, False)
                left = self.value(e.left)
                if left is False:
                    return self.walk(e.left, False)
                if isinstance(left, _Failure):
                    self.add(e.left, left)
                    return None
                return self.walk(e.right, self.value(e.right))
            if e.op in _COMPARISONS:
                self.operand(e.left)
                self.operand(e.right)
                return None
        if isinstance(e, ast.Unary) and e.op == "not":
            inner = self.value(e.operand)
            if isinstance(inner, _Failure) or not _is_bool(inner):
                self.add(e.operand, inner)
                return None
            return self.walk(e.operand, inner)
        if isinstance(e, ast.If):
            cond = self.add(e.cond)
            if _is_bool(cond):
                branch = e.then if cond else e.else_
                return self.walk(branch, value)
            return None
        if isinstance(e, ast.Let):
            return self.walk_let(e, value)
        if isinstance(e, ast.Comprehension) and e.kind in ("all", "exists"):
            return self.walk_quantifier(e, value)
        if isinstance(e, ast.Call) and not self.is_old(e):
            for a in e.args:
                if not _is_literal(a):
                    self.add(a)
            self.add(e, value)
            return None
        if isinstance(e, ast.BoolLit):
            return None
        self.add(e, value)
        return None

    def walk_chain(self, e: ast.Binary, value: Any) -> None:
        parts = _chain(e, e.op)
        decisive = value is False if e.op == "and" else value is True
        for part in parts:
            v = self.value(part)
            if isinstance(v, _Failure) or not _is_bool(v):
                self.add(part, v)
                return
            if decisive:
                if v is value:
                    self.walk(part, v)
                    return
            else:
                self.walk(part, v)

    def walk_let(self, e: ast.Let, value: Any) -> None:
        bound = self.value(e.value)
        if isinstance(bound, _Failure):
            self.add(e.value, bound)
            return
        self.add_text(e.name, bound, self.ev.type_of(e.value))
        previous = self.ev.bind(e, bound)
        try:
            self.walk(e.body, self.value(e.body))
        finally:
            self.ev.unbind(e, previous)

    def walk_quantifier(self, e: ast.Comprehension, value: Any) -> None:
        witness = (e.kind == "all" and value is False) or (e.kind == "exists" and value is True)
        is_set = isinstance(self.ev.type_of(e.iterable), SetT)
        coll = None if is_set else self.value(e.iterable)
        if not witness or isinstance(coll, _Failure):
            if not _is_literal(e.iterable) and not is_set:
                self.add(e.iterable, coll)
            return
        try:
            items = self.ev.items(e) if is_set else _elements(coll, f"{e.kind}(...)")
        except EvalError as exc:
            self.add(e.iterable, _Failure(exc))
            return
        previous = self.ev.locals.get(e, _UNBOUND)
        try:
            for x in items:
                self.ev.locals[e] = x
                v = self.value(e.body)
                if v is value or isinstance(v, _Failure):
                    elem_t = _iter_elem_type(self.ev.type_of(e.iterable))
                    self.add_text(e.var, x, elem_t)
                    if isinstance(v, _Failure):
                        self.add(e.body, v)
                    else:
                        self.walk(e.body, v)
                    return
        finally:
            self.ev.unbind(e, previous)


def _iter_elem_type(t: Type | None) -> Type | None:
    if isinstance(t, (ListT, SetT)):
        return t.elem
    if isinstance(t, (StringT, LiteralT)):
        return t
    if isinstance(t, BytesT):
        return IntT()
    if isinstance(t, MapT):
        return t.key
    return None


def explain(
    expr: ast.Expr, env: Env, spec: Spec, ctx: Any, *, limit: int = EXPLAIN_LIMIT
) -> list[tuple[str, str]]:
    """Why a boolean clause has its value: (sub-expression text, value) pairs.

    For a false clause it follows the failing structure: the consequent of
    implies, the first false conjunct, operands of comparisons, arguments of
    calls, values bound by let and the element where all(...) fails. It
    never raises.
    """
    ev = _Evaluator(env, spec, ctx)
    ex = _Explainer(ev, limit)
    try:
        value = ex.value(expr)
        if isinstance(value, _Failure) or not _is_bool(value):
            ex.add(expr, value)
        else:
            ex.walk(expr, value)
            if not ex.pairs:
                ex.add(expr, value)
    except Exception as exc:  # noqa: BLE001
        ex.pairs.append(("<explain>", _short(f"could not explain: {exc}", EXPLAIN_VALUE_CHARS)))
    return ex.pairs
