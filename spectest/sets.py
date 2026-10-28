"""Partition sets over fixed-width scalars.

A class of a partition of an ``f16``..``f64``, ``i8``..``u64`` or ``bool``
parameter is a set expression. ``compile_set`` turns one into a bitpattern
``BDDSet`` over the type's raw bit patterns, so signed zeros and NaN payloads
are exact. ``check_partitions`` proves the classes of every such partition
disjoint and covering. The sampling helpers draw and enumerate members as
runtime values: ``FloatValue`` for floats, ``int`` for integers, ``bool``.
"""

from __future__ import annotations

import functools
import math
from collections.abc import Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from fractions import Fraction
from typing import Any

import hypothesis
from bitpattern import BDD, BDDSet, Codec, IntSet
from bitpattern import codecs as bp
from hypothesis import strategies as st
from hypothesis.errors import InvalidArgument

from spectest import ast
from spectest.types import (
    BOOL,
    FLOAT_FORMATS,
    BoolT,
    FixedIntT,
    FloatT,
    SetT,
    Type,
    is_fixed_width,
    scalar_type,
)
from spectest.values import FloatValue, SpecError

__all__ = [
    "BoolBits",
    "Diagnostic",
    "FloatBits",
    "SetError",
    "aggregate_set",
    "check_partitions",
    "classify",
    "codec_for",
    "compile_partition",
    "compile_set",
    "domain",
    "domain_size",
    "elem_type",
    "enumerate_domain",
    "enumerate_set",
    "float_range",
    "format_value",
    "index_of",
    "index_strategy",
    "int_range",
    "member",
    "named_set",
    "param_type",
    "partition_sets",
    "partition_strategy",
    "requires_set",
    "set_size",
    "strategy_for_set",
    "tagged_partition_strategy",
]

Real = int | Fraction
Classes = Sequence[tuple[str, BDDSet]] | Mapping[str, BDDSet]


class SetError(SpecError):
    """A partition set expression is malformed or does not fit its type."""

    def __init__(self, message: str, span: ast.Span = ast.NO_SPAN) -> None:
        super().__init__(message)
        self.message = message
        self.span = span


@dataclass(frozen=True)
class Diagnostic:
    """A finding of the partition checks; severity is "error" or "warning"."""

    span: ast.Span
    message: str
    severity: str = "error"

    def __str__(self) -> str:
        return f"{self.span}: {self.severity}: {self.message}"


# ---------------------------------------------------------------------------
# Float layouts and codecs


def _pow2(k: int) -> Fraction:
    return Fraction(1 << k) if k >= 0 else Fraction(1, 1 << -k)


@dataclass(frozen=True)
class _Layout:
    """Bit layout of an IEEE format; magnitudes are bit patterns with the sign clear."""

    fmt: str
    width: int
    man_bits: int
    bias: int

    @property
    def sign(self) -> int:
        return 1 << (self.width - 1)

    @property
    def inf_mag(self) -> int:
        return ((1 << (self.width - 1 - self.man_bits)) - 1) << self.man_bits

    @property
    def qnan(self) -> int:
        return self.inf_mag | 1 << (self.man_bits - 1)

    @property
    def one(self) -> int:
        return self.bias << self.man_bits

    @property
    def max_value(self) -> Fraction:
        return self.value(self.inf_mag - 1)

    def value(self, mag: int) -> Fraction:
        """The exact value of a finite magnitude."""
        exp, frac = mag >> self.man_bits, mag & ((1 << self.man_bits) - 1)
        if exp:
            frac |= 1 << self.man_bits
        return frac * _pow2(max(exp, 1) - self.bias - self.man_bits)

    def at_least(self, r: Fraction) -> int:
        """The smallest magnitude whose value is >= r (r >= 0); inf_mag stands for +inf."""
        lo, hi = 0, self.inf_mag
        while lo < hi:
            mid = (lo + hi) // 2
            if self.value(mid) >= r:
                hi = mid
            else:
                lo = mid + 1
        return lo

    def above(self, r: Fraction) -> int:
        """The smallest magnitude whose value is > r (r >= 0)."""
        mag = self.at_least(r)
        return mag + 1 if mag < self.inf_mag and self.value(mag) == r else mag

    def exact(self, r: Real) -> int | None:
        """The bits of a finite real if it is exactly representable (0 gives +0)."""
        mag = self.at_least(abs(Fraction(r)))
        if mag >= self.inf_mag or self.value(mag) != abs(r):
            return None
        return mag | self.sign if r < 0 else mag

    def nearest(self, r: Real) -> int:
        """The bits of a finite real rounded to nearest, ties to even."""
        target = abs(Fraction(r))
        mag = self.at_least(target)
        if mag and not (mag < self.inf_mag and self.value(mag) == target):
            below = self.value(mag - 1)
            above = self.value(mag) if mag < self.inf_mag else _pow2(self.bias + 1)
            excess = (target - below) - (above - target)
            if excess < 0 or excess == 0 and mag % 2:
                mag -= 1
        return mag | self.sign if r < 0 else mag


LAYOUTS: dict[str, _Layout] = {
    fmt: _Layout(fmt, 1 + exp + man, man, (1 << (exp - 1)) - 1)
    for fmt, (exp, man) in FLOAT_FORMATS.items()
}


@dataclass(frozen=True, repr=False)
class FloatBits(Codec[FloatValue]):
    """A float format's values as FloatValues, encoded as their raw bits."""

    fmt: str

    def encode(self, value: object) -> int:
        if not isinstance(value, FloatValue):
            raise TypeError(f"{self} can't encode a {type(value).__name__}")
        if value.fmt != self.fmt:
            raise ValueError(f"{self} can't encode a {value.fmt} value")
        return value.bits

    def decode(self, bits: int) -> FloatValue:
        return FloatValue(self.fmt, bits)


@dataclass(frozen=True, repr=False)
class BoolBits(Codec[bool]):
    """false and true as 0 and 1."""

    def encode(self, value: object) -> int:
        if not isinstance(value, bool):
            raise TypeError(f"{self} can't encode a {type(value).__name__}")
        return int(value)

    def decode(self, bits: int) -> bool:
        return bool(bits)


FLOAT_CODECS: dict[str, FloatBits] = {
    fmt: FloatBits(layout.width, fmt, fmt) for fmt, layout in LAYOUTS.items()
}
INT_CODECS: dict[str, bp.Int] = {
    "i8": bp.int8,
    "i16": bp.int16,
    "i32": bp.int32,
    "i64": bp.int64,
    "u8": bp.uint8,
    "u16": bp.uint16,
    "u32": bp.uint32,
    "u64": bp.uint64,
}
BOOL_CODEC = BoolBits(1, "bool")
_BP_FLOATS = {"f16": bp.float16, "bf16": bp.bfloat16, "f32": bp.float32, "f64": bp.float64}


def codec_for(elem: Type) -> Codec[Any]:
    """The codec of a fixed-width scalar type's sets."""
    if isinstance(elem, FloatT):
        return FLOAT_CODECS[elem.fmt]
    if isinstance(elem, FixedIntT):
        return INT_CODECS[elem.name]
    if isinstance(elem, BoolT):
        return BOOL_CODEC
    raise TypeError(f"{elem} is not a fixed-width scalar type")


def elem_type(s: BDDSet) -> Type:
    """The scalar type a compiled set holds values of."""
    codec = s.codec
    if isinstance(codec, FloatBits):
        return FloatT(codec.fmt)
    if isinstance(codec, BoolBits):
        return BOOL
    if isinstance(codec, bp.Int):
        return FixedIntT(codec.width, codec.signed)
    raise TypeError(f"{codec} sets are not partition sets")


def domain(elem: Type) -> BDDSet:
    """Every value of a fixed-width scalar type."""
    return codec_for(elem).all


@functools.cache
def _named_sets(elem: Type) -> dict[str, BDDSet]:
    codec = codec_for(elem)
    if isinstance(elem, FloatT):
        source = _BP_FLOATS[elem.fmt]

        def raw(s: BDDSet) -> BDDSet:
            return BDDSet(codec, s.storage)

        zero, subnormal, finite = raw(source.zeros), raw(source.subnormal), raw(source.finite)
        return {
            "nan": raw(source.nan),
            "inf": raw(source.infinities),
            "zero": zero,
            "subnormal": subnormal,
            "normal": finite - subnormal - zero,
            "finite": finite,
            "positive": raw(source.sign_clear),
            "negative": raw(source.sign_set),
            "all": codec.all,
        }
    if isinstance(elem, FixedIntT):
        return {
            "zero": codec.set([0]),
            "positive": int_range(elem, 0, None),
            "negative": int_range(elem, None, 0),
            "all": codec.all,
        }
    return {"all": codec.all}


def named_set(elem: Type, name: str) -> BDDSet | None:
    """``T.<name>`` (``f64.nan``, ``i32.negative``, ...), or None if T has no such set."""
    return _named_sets(elem).get(name)


def _interval(lo: int, hi: int, width: int) -> IntSet:
    return IntSet.range(lo, max(lo, hi), width=width)


def float_range(elem: FloatT, lo: Real | None, hi: Real | None) -> BDDSet:
    """Non-NaN values v with lo <= v < hi by numeric value, so -0 and +0 are both 0.

    A bound of None leaves that end open, including its infinity.
    """
    layout, top = LAYOUTS[elem.fmt], LAYOUTS[elem.fmt].inf_mag + 1
    pos_lo = 0 if lo is None or lo <= 0 else layout.at_least(Fraction(lo))
    pos_hi = top if hi is None else 0 if hi <= 0 else layout.at_least(Fraction(hi))
    neg_lo = 0 if hi is None or hi > 0 else layout.above(Fraction(-hi))
    neg_hi = top if lo is None else 0 if lo > 0 else layout.above(Fraction(-lo))
    storage = _interval(pos_lo, pos_hi, layout.width) | _interval(
        layout.sign + neg_lo, layout.sign + neg_hi, layout.width
    )
    return BDDSet(FLOAT_CODECS[elem.fmt], storage)


def int_range(elem: FixedIntT, lo: int | None, hi: int | None) -> BDDSet:
    """Integers in [lo, hi), clamped to the type; None leaves that end open."""
    codec = INT_CODECS[elem.name]
    lo = elem.min if lo is None else max(lo, elem.min)
    hi = elem.max + 1 if hi is None else min(hi, elem.max + 1)
    return codec.range(lo, hi) if lo < hi else codec.none


def _float_equal(elem: FloatT, c: Real) -> BDDSet:
    """The values numerically equal to c: both zeros for 0."""
    codec = FLOAT_CODECS[elem.fmt]
    if c == 0:
        return named_set(elem, "zero")
    bits = LAYOUTS[elem.fmt].exact(c)
    return codec.none if bits is None else codec.set([codec.decode(bits)])


# ---------------------------------------------------------------------------
# Compiling set expressions


def _norm(v: Real) -> Real:
    if isinstance(v, Fraction) and v.denominator == 1:
        return int(v)
    return v


def _real_text(v: Real) -> str:
    if isinstance(v, int):
        return str(v)
    if float(v) == v:
        return repr(float(v))
    return f"{v.numerator}/{v.denominator}"


def _kind(e: ast.Expr) -> str:
    match e:
        case ast.Binary(op=op) | ast.Unary(op=op):
            return f"the operator {op}"
        case ast.Call(func=ast.Name(id=name)) | ast.Call(func=ast.Attribute(attr=name)):
            return f"a call to {name}"
        case ast.Num(text=text):
            return f"the number {text}"
        case ast.Attribute(attr=attr):
            return f".{attr}"
        case ast.Name(id=name):
            return name
    return type(e).__name__


class _Compiler:
    def __init__(
        self,
        elem: Type,
        classes: Mapping[str, BDDSet],
        aliases: Mapping[str, Type],
    ) -> None:
        self.elem = elem
        self.codec = codec_for(elem)
        self.classes = classes
        self.aliases = aliases

    def type_named(self, e: ast.Expr) -> Type | None:
        if not isinstance(e, ast.Name):
            return None
        t = scalar_type(e.id) or self.aliases.get(e.id)
        return t if t is not None and is_fixed_width(t) else None

    def owner(self, e: ast.Expr, member: str, whole: ast.Expr) -> tuple[Type, str]:
        if not isinstance(e, ast.Name) or (t := self.type_named(e)) is None:
            raise SetError(f"{_kind(e)}.{member} is not a partition set", whole.span)
        name = e.id
        if t != self.elem:
            raise SetError(
                f"{name}.{member} is a set of {t} values, but this partition is of {self.elem}",
                whole.span,
            )
        return t, name

    def set(self, e: ast.Expr) -> BDDSet:
        match e:
            case ast.Binary(op="|" | "&" | "-" as op, left=left, right=right):
                a, b = self.set(left), self.set(right)
                return a | b if op == "|" else a & b if op == "&" else a - b
            case ast.Name(id=name):
                if name in self.classes:
                    s = self.classes[name]
                    if s.codec != self.codec:
                        raise SetError(f"class {name} is a set of {elem_type(s)} values", e.span)
                    return s
                if self.type_named(e) is not None:
                    raise SetError(f"{name} is a type; write {name}.all for all of it", e.span)
                raise SetError(
                    f"unknown class {name} (a class can only use classes defined before it)",
                    e.span,
                )
            case ast.Attribute(value=value, attr=attr):
                _, tname = self.owner(value, attr, e)
                if attr in ("min", "max"):
                    raise SetError(
                        f"{tname}.{attr} is a value, not a set; write {{{tname}.{attr}}}", e.span
                    )
                s = named_set(self.elem, attr)
                if s is None:
                    names = ", ".join(_named_sets(self.elem))
                    raise SetError(f"{tname} has no set {attr} (its sets are {names})", e.span)
                return s
            case ast.Call(func=ast.Attribute(value=value, attr="range" | "pattern" as attr)):
                _, tname = self.owner(value, attr, e)
                return self.range(e, tname) if attr == "range" else self.pattern(e, tname)
            case ast.SetLit(elems=elems):
                bits = [self.member_bits(x) for x in elems]
                return BDDSet(self.codec, IntSet(bits, width=self.codec.width))
        raise SetError(
            f"expected a set expression, got {_kind(e)}. Classes of a {self.elem} parameter "
            f'are sets: {self.elem}.nan, {self.elem}.range(a, b), {self.elem}.pattern("..."), '
            "{v, ...} or earlier classes, combined with |, & and -",
            e.span,
        )

    def range(self, call: ast.Call, tname: str) -> BDDSet:
        if not isinstance(self.elem, FloatT | FixedIntT):
            raise SetError(f"{tname} has no range", call.span)
        if len(call.args) != 2 or call.kwargs or call.type_args:
            raise SetError(f"{tname}.range takes two bounds: {tname}.range(start, stop)", call.span)
        lo, hi = (self.bound(arg, tname) for arg in call.args)
        if isinstance(self.elem, FloatT):
            return float_range(self.elem, lo, hi)
        return int_range(self.elem, lo, hi)  # type: ignore[arg-type]

    def bound(self, e: ast.Expr, tname: str) -> Real | None:
        if isinstance(e, ast.NoneLit):
            return None
        v = self.const(e)
        text = e.text if isinstance(e, ast.Num) else _real_text(v)
        if isinstance(self.elem, FloatT):
            if LAYOUTS[self.elem.fmt].exact(v) is None:
                raise SetError(
                    f"{tname}.range bound {text} is not exactly representable in {self.elem}",
                    e.span,
                )
            return v
        if isinstance(self.elem, FixedIntT):
            if not isinstance(v, int):
                raise SetError(f"{tname}.range bound {text} is not an integer", e.span)
            if not self.elem.min <= v <= self.elem.max + 1:
                raise SetError(
                    f"{tname}.range bound {text} is outside {self.elem}: bounds lie in "
                    f"[{tname}.min, {tname}.max + 1]",
                    e.span,
                )
        return v

    def pattern(self, call: ast.Call, tname: str) -> BDDSet:
        if len(call.args) != 1 or not isinstance(call.args[0], ast.Str) or call.kwargs:
            raise SetError(f'{tname}.pattern takes one string: {tname}.pattern("...")', call.span)
        try:
            return self.codec.pattern(call.args[0].value)
        except ValueError as err:
            raise SetError(f"{tname}.pattern: {err}", call.args[0].span) from None

    def member_bits(self, e: ast.Expr) -> int:
        if isinstance(self.elem, BoolT):
            if not isinstance(e, ast.BoolLit):
                raise SetError(f"a bool set holds true and false, not {_kind(e)}", e.span)
            return int(e.value)
        v = self.const(e)
        text = e.text if isinstance(e, ast.Num) else _real_text(v)
        if isinstance(self.elem, FixedIntT):
            if not isinstance(v, int) or not self.elem.min <= v <= self.elem.max:
                raise SetError(f"{text} is not a {self.elem} value", e.span)
            return self.codec.encode(v)
        assert isinstance(self.elem, FloatT)
        if isinstance(e, ast.Unary) and e.op == "-" and v == 0:
            raise SetError(
                f"-0 is the number 0, which is +0.0 as a {self.elem}; write "
                f"{self.elem}.zero & {self.elem}.negative for -0.0, or 0 for +0.0",
                e.span,
            )
        bits = LAYOUTS[self.elem.fmt].exact(v)
        if bits is None:
            raise SetError(f"{text} is not exactly representable in {self.elem}", e.span)
        return bits

    def const(self, e: ast.Expr) -> Real:
        match e:
            case ast.Num(value=value):
                return _norm(Fraction(value) if isinstance(value, float) else value)
            case ast.Unary(op="-", operand=operand):
                return -self.const(operand)
            case ast.Binary(op="+" | "-" | "*" | "/" as op, left=left, right=right):
                a, b = self.const(left), self.const(right)
                if op == "+":
                    return a + b
                if op == "-":
                    return a - b
                if op == "*":
                    return a * b
                if b == 0:
                    raise SetError("division by zero", e.span)
                return _norm(Fraction(a) / b)
            case ast.Attribute(value=ast.Name(id=tname) as value, attr="min" | "max" as attr):
                t = self.type_named(value)
                if isinstance(t, FixedIntT):
                    return t.min if attr == "min" else t.max
                if isinstance(t, FloatT):
                    top = _norm(LAYOUTS[t.fmt].max_value)
                    return -top if attr == "min" else top
                if t is not None:
                    raise SetError(f"{tname} has no {attr}", e.span)
        raise SetError(
            f"expected a constant, got {_kind(e)}: bounds and members are numbers combined "
            "with +, -, * and /, or T.min and T.max",
            e.span,
        )


def compile_set(
    expr: ast.Expr,
    elem: Type,
    classes: Mapping[str, BDDSet] | None = None,
    *,
    aliases: Mapping[str, Type] | None = None,
) -> BDDSet:
    """Compile a partition class's set expression over ``elem``'s bit patterns.

    ``classes`` holds the earlier classes a bare name may refer to, and
    ``aliases`` the spec's type aliases. Raises SetError with the offending span.
    """
    return _Compiler(elem, classes or {}, aliases or {}).set(expr)


def compile_partition(
    partition: ast.Partition,
    elem: Type,
    *,
    aliases: Mapping[str, Type] | None = None,
) -> list[tuple[str, BDDSet]]:
    """Compile every class of a partition in order; raises SetError at the first failure."""
    classes: dict[str, BDDSet] = {}
    for cls in partition.classes:
        try:
            classes[cls.name] = compile_set(cls.expr, elem, classes, aliases=aliases)
        except SetError as err:
            span = err.span if err.span != ast.NO_SPAN else cls.span
            raise SetError(f"class {cls.name}: {err.message}", span) from None
    return list(classes.items())


# ---------------------------------------------------------------------------
# requires clauses as sets


class _NotASet(Exception):
    pass


_FLIPPED = {"<": ">", "<=": ">=", ">": "<", ">=": "<=", "==": "==", "!=": "!="}
_FLOAT_TESTS = {
    "is_nan": "nan",
    "is_inf": "inf",
    "is_finite": "finite",
    "is_zero": "zero",
    "is_subnormal": "subnormal",
    "signbit": "negative",
}

Verdicts = tuple[BDDSet, BDDSet]


class _Predicate:
    """A predicate over one parameter as the sets where it is true and where it is false.

    Values in neither set make evaluation fail (NaN promoted to real).
    """

    def __init__(self, param: str, elem: Type, aliases: Mapping[str, Type]) -> None:
        self.param = param
        self.elem = elem
        self.codec = codec_for(elem)
        self.consts = _Compiler(elem, {}, aliases)
        self.all = self.codec.all
        self.none = self.codec.none

    def compile(self, e: ast.Expr) -> Verdicts | None:
        try:
            return self.pred(e)
        except (_NotASet, SetError):
            return None

    def admitted(self, e: ast.Expr) -> list[BDDSet]:
        """Sets that contain every value the clause admits, splitting top-level ``and``."""
        if (verdicts := self.compile(e)) is not None:
            return [verdicts[0]]
        if isinstance(e, ast.Binary) and e.op == "and":
            return self.admitted(e.left) + self.admitted(e.right)
        return []

    def is_param(self, e: ast.Expr) -> bool:
        match e:
            case ast.Name(id=name):
                return name == self.param
            case ast.Call(func=ast.Name(id="real"), args=[arg], kwargs=[], type_args=[]):
                return self.is_param(arg)
        return False

    def pred(self, e: ast.Expr) -> Verdicts:
        match e:
            case ast.BoolLit(value=value):
                return (self.all, self.none) if value else (self.none, self.all)
            case ast.Name() if isinstance(self.elem, BoolT) and self.is_param(e):
                true = self.codec.set([True])
                return true, self.all - true
            case ast.Unary(op="not", operand=operand):
                true, false = self.pred(operand)
                return false, true
            case ast.Binary(op="and" | "or" | "implies" as op, left=left, right=right):
                ta, fa = self.pred(left)
                tb, fb = self.pred(right)
                if op == "and":
                    return ta & tb, fa | (ta & fb)
                if op == "or":
                    return ta | (fa & tb), fa & fb
                return fa | (ta & tb), ta & fb
            case ast.If(cond=cond, then=then, else_=else_):
                tc, fc = self.pred(cond)
                ta, fa = self.pred(then)
                tb, fb = self.pred(else_)
                return (tc & ta) | (fc & tb), (tc & fa) | (fc & fb)
            case ast.Call(func=ast.Name(id=fn), args=[arg], kwargs=[]) if self.is_param(arg):
                true = self.test(fn, e)
                return true, self.all - true
            case ast.Binary(
                op="in", left=left, right=ast.ListLit(elems=elems) | ast.SetLit(elems=elems)
            ):
                if not self.is_param(left) or not isinstance(self.elem, FixedIntT):
                    raise _NotASet
                true = self.none
                for x in elems:
                    true = true | self.int_compare("==", self.consts.const(x))
                return true, self.all - true
            case ast.Binary(op=op, left=left, right=right) if op in _FLIPPED:
                if self.is_param(left):
                    return self.compare(op, self.consts.const(right))
                if self.is_param(right):
                    return self.compare(_FLIPPED[op], self.consts.const(left))
        raise _NotASet

    def test(self, fn: str, call: ast.Call) -> BDDSet:
        if isinstance(self.elem, FloatT) and fn in _FLOAT_TESTS and not call.type_args:
            return named_set(self.elem, _FLOAT_TESTS[fn])
        if isinstance(self.elem, FixedIntT) and fn == "fits" and len(call.type_args) == 1:
            texpr = call.type_args[0]
            if isinstance(texpr, ast.TypeExpr) and not texpr.args:
                t = self.consts.type_named(ast.Name(texpr.name))
                if isinstance(t, FixedIntT):
                    return int_range(self.elem, t.min, t.max + 1)
        raise _NotASet

    def compare(self, op: str, c: Real) -> Verdicts:
        if isinstance(self.elem, FixedIntT):
            true = self.int_compare(op, c)
            return true, self.all - true
        if not isinstance(self.elem, FloatT) or op in ("==", "!="):
            raise _NotASet
        ordered = self.all - named_set(self.elem, "nan")
        below = float_range(self.elem, None, c)
        at_most = below | _float_equal(self.elem, c)
        true = {"<": below, "<=": at_most, ">": ordered - at_most, ">=": ordered - below}[op]
        return true, ordered - true

    def int_compare(self, op: str, c: Real) -> BDDSet:
        assert isinstance(self.elem, FixedIntT)
        below = int_range(self.elem, None, math.ceil(c))
        at_most = int_range(self.elem, None, math.floor(c) + 1)
        equal = at_most - below
        return {
            "<": below,
            "<=": at_most,
            ">": self.all - at_most,
            ">=": self.all - below,
            "==": equal,
            "!=": self.all - equal,
        }[op]


def requires_set(
    decl: ast.Callable_,
    param: str,
    elem: Type,
    *,
    aliases: Mapping[str, Type] | None = None,
) -> BDDSet | None:
    """A superset of the values of ``param`` that the callable's requires clauses admit.

    Each requires clause (or top-level conjunct) that is a predicate on ``param``
    alone narrows the set; the rest are ignored. None when no clause narrows it.
    """
    pred = _Predicate(param, elem, aliases or {})
    target: BDDSet | None = None
    for clause in decl.clauses:
        if clause.kind != "requires" or clause.expr is None:
            continue
        for admitted in pred.admitted(clause.expr):
            target = admitted if target is None else target & admitted
    return target


# ---------------------------------------------------------------------------
# Checking partitions


def _values(source: Any) -> list[Any]:
    if source is None:
        return []
    if isinstance(source, Mapping):
        return list(source.values())
    return list(source)


def _aliases(spec: Any) -> dict[str, Type]:
    aliases = getattr(spec, "aliases", None)
    if isinstance(aliases, Mapping):
        return dict(aliases)
    found: dict[str, Type] = {}
    for decl in getattr(spec, "decls", None) or []:
        if isinstance(decl, ast.AliasDecl) and isinstance(decl.type, ast.TypeExpr):
            t = scalar_type(decl.type.name) or found.get(decl.type.name)
            if t is not None and not decl.type.args:
                found[decl.name] = t
    return found


def _callables(spec: Any) -> Iterator[tuple[str, ast.Callable_, set[str]]]:
    decls = getattr(spec, "decls", None)
    if decls is not None:
        fns = [d for d in decls if isinstance(d, ast.FnDecl)]
        interfaces = [d for d in decls if isinstance(d, ast.InterfaceDecl)]
    else:
        fns = _values(getattr(spec, "fns", None))
        interfaces = _values(getattr(spec, "interfaces", None))
    for fn in fns:
        yield fn.name, fn, {tp.name for tp in getattr(fn, "tparams", [])}
    for iface in interfaces:
        tvars = {tp.name for tp in getattr(iface, "tparams", [])}
        for decl in [*getattr(iface, "ctors", []), *getattr(iface, "methods", [])]:
            yield f"{iface.name}.{decl.name}", decl, tvars


def param_type(
    decl: ast.Callable_,
    param: str,
    tvars: Iterable[str] = (),
    aliases: Mapping[str, Type] | None = None,
) -> Type | None:
    """The fixed-width scalar type of a parameter, or None if it is not one."""
    for p in decl.params:
        if p.name != param:
            continue
        texpr = p.type
        if not isinstance(texpr, ast.TypeExpr) or texpr.args or texpr.name in set(tvars):
            return None
        t = scalar_type(texpr.name) or (aliases or {}).get(texpr.name)
        return t if t is not None and is_fixed_width(t) else None
    return None


def partition_sets(
    decl: ast.Callable_,
    param: str,
    spec: Any = None,
    tvars: Iterable[str] = (),
) -> list[tuple[str, BDDSet]] | None:
    """The compiled classes of decl's partition of a fixed-width parameter.

    None when the parameter has no partition or is not fixed-width. Raises SetError.
    """
    tvars = {*tvars, *(tp.name for tp in getattr(decl, "tparams", []))}
    aliases = _aliases(spec) if spec is not None else {}
    elem = param_type(decl, param, tvars, aliases)
    if elem is None:
        return None
    for part in decl.partitions:
        if part.param == param:
            return compile_partition(part, elem, aliases=aliases)
    return None


def _count(n: int) -> str:
    if n < 1 << 20:
        text = f"{n:,}"
    elif n & (n - 1) == 0:
        text = f"2^{n.bit_length() - 1}"
    else:
        text = f"about 2^{math.log2(n):.1f}"
    return f"{text} value" if n == 1 else f"{text} values"


def _uses(expr: ast.Expr, names: set[str]) -> bool:
    return any(isinstance(n, ast.Name) and n.id in names for n in ast.walk(expr))


def _check_partition(
    where: str,
    decl: ast.Callable_,
    part: ast.Partition,
    elem: Type,
    aliases: Mapping[str, Type],
) -> list[Diagnostic]:
    label = f"partition {part.param} of {where}"
    out: list[Diagnostic] = []
    classes: dict[str, BDDSet] = {}
    compiled: list[tuple[ast.PartitionClass, BDDSet]] = []
    failed: set[str] = set()
    for cls in part.classes:
        if cls.name in classes or cls.name in failed:
            out.append(Diagnostic(cls.span, f"{label}: class {cls.name} is defined twice"))
            failed.add(cls.name)
            continue
        if _uses(cls.expr, failed):
            failed.add(cls.name)
            continue
        try:
            s = compile_set(cls.expr, elem, classes, aliases=aliases)
        except SetError as err:
            span = err.span if err.span != ast.NO_SPAN else cls.span
            out.append(Diagnostic(span, f"{label}: class {cls.name}: {err.message}"))
            failed.add(cls.name)
            continue
        classes[cls.name] = s
        compiled.append((cls, s))
    if failed:
        return out

    def example(s: BDDSet) -> str:
        return f"{part.param} = {format_value(member(s, 0))}"

    union = codec_for(elem).none
    for i, (cls, s) in enumerate(compiled):
        if not s:
            out.append(Diagnostic(cls.span, f"{label}: class {cls.name} is empty", "warning"))
        for other, t in compiled[:i]:
            if common := t & s:
                out.append(
                    Diagnostic(
                        cls.span,
                        f"{label}: classes {other.name} and {cls.name} overlap on "
                        f"{_count(common.size)}, e.g. {example(common)}",
                    )
                )
        union = union | s

    target = requires_set(decl, part.param, elem, aliases=aliases)
    if target is None:
        if missing := domain(elem) - union:
            out.append(
                Diagnostic(
                    part.span,
                    f"{label} does not cover every {elem}: {_count(missing.size)} "
                    f"in no class, e.g. {example(missing)}",
                )
            )
        return out
    if missing := target - union:
        out.append(
            Diagnostic(
                part.span,
                f"{label} does not cover the values requires admits: {_count(missing.size)} "
                f"in no class, e.g. {example(missing)}",
            )
        )
    for cls, s in compiled:
        if s and (outside := s - target):
            out.append(
                Diagnostic(
                    cls.span,
                    f"{label}: class {cls.name} has {_count(outside.size)} that requires "
                    f"rejects, e.g. {example(outside)}",
                    "warning",
                )
            )
    return out


def aggregate_set(
    clause: ast.Clause, aliases: Mapping[str, Type] | None = None
) -> tuple[BDDSet, Type] | None:
    """The set a checked aggregate clause ranges over, compiled, with its element type.

    None when the clause's top comprehension ranges over a list. Raises SetError.
    """
    e = clause.expr
    top = e.left if isinstance(e, ast.Binary) else e
    if not isinstance(top, ast.Comprehension) or not isinstance(top.iterable.ty, SetT):
        return None
    elem = top.iterable.ty.elem
    return compile_set(top.iterable, elem, aliases=aliases), elem


def _check_aggregates(
    where: str, decl: ast.Callable_, aliases: dict[str, Type]
) -> list[Diagnostic]:
    out: list[Diagnostic] = []
    for c in decl.clauses:
        if c.kind != "aggregate" or c.expr is None:
            continue
        label = f"{where}: aggregate {c.label or c.id or ''}".rstrip()
        try:
            found = aggregate_set(c, aliases)
        except SetError as err:
            span = err.span if err.span != ast.NO_SPAN else c.span
            out.append(Diagnostic(span, f"{label}: {err.message}"))
            continue
        if found is not None and not found[0]:
            out.append(Diagnostic(c.span, f"{label}: the set it ranges over is empty", "warning"))
    return out


def check_partitions(spec: Any) -> list[Diagnostic]:
    """Check every partition of a fixed-width parameter in a Spec (or SpecFile).

    Each class must compile; classes must be pairwise disjoint and their union
    must cover the parameter's type, or the set its requires clauses admit.
    Empty classes and classes reaching outside requires are warnings. The set
    an aggregate clause ranges over must compile too (an empty one is a warning).
    """
    aliases = _aliases(spec)
    out: list[Diagnostic] = []
    for where, decl, tvars in _callables(spec):
        for part in getattr(decl, "partitions", []):
            elem = param_type(decl, part.param, tvars, aliases)
            if elem is not None:
                out.extend(_check_partition(where, decl, part, elem, aliases))
        out.extend(_check_aggregates(where, decl, aliases))
    return out


# ---------------------------------------------------------------------------
# Members, sampling and enumeration


@dataclass(frozen=True)
class _Order:
    """Index order of a set's members: simple values first, then by magnitude.

    ``specials`` (0, 1, -1, the quiet NaNs) come first, then ``head`` ascending,
    then ``tail`` descending, so negative integers run -1, -2, ... .
    """

    specials: tuple[int, ...]
    head: IntSet
    tail: IntSet
    head_size: int
    size: int

    def bits(self, i: int) -> int:
        if not 0 <= i < self.size:
            raise IndexError(f"index {i} is outside a set of {self.size} values")
        n = len(self.specials)
        if i < n:
            return self.specials[i]
        i -= n
        if i < self.head_size:
            return self.head[i]
        return self.tail[self.size - n - 1 - i]

    def index(self, bits: int) -> int:
        n = len(self.specials)
        if bits in self.specials:
            return self.specials.index(bits)
        if bits in self.head:
            return n + self.head.index(bits)
        if bits in self.tail:
            return self.size - 1 - self.tail.index(bits)
        raise ValueError(f"{bits:#x} is not in the set")


def _special_bits(codec: Codec[Any]) -> tuple[int, ...]:
    if isinstance(codec, FloatBits):
        layout = LAYOUTS[codec.fmt]
        sign = layout.sign
        return (0, sign, layout.one, sign | layout.one, layout.qnan, sign | layout.qnan)
    if isinstance(codec, bp.Int) and codec.signed:
        return (0, 1, (1 << codec.width) - 1)
    return (0, 1)


@functools.lru_cache(maxsize=4096)
def _order(s: BDDSet) -> _Order:
    storage, width = s.storage, s.codec.width
    specials = tuple(b for b in _special_bits(s.codec) if b in storage)
    rest = storage - IntSet(specials, width=width)
    if isinstance(s.codec, bp.Int) and s.codec.signed:
        nonnegative = IntSet.range(0, 1 << (width - 1), width=width)
        head, tail = rest & nonnegative, rest - nonnegative
    else:
        head, tail = rest, IntSet.from_bdd(BDD.REJECT, width)
    return _Order(specials, head, tail, head.size, storage.size)


def set_size(s: BDDSet) -> int:
    """How many values the set holds."""
    return s.size


def member(s: BDDSet, i: int) -> Any:
    """The i-th member as a runtime value; low indices are the simplest values."""
    return s.codec.decode(_order(s).bits(i))


def index_of(s: BDDSet, value: Any) -> int:
    """The index of a member, the inverse of ``member``. ValueError if absent."""
    try:
        bits = s.codec.encode(value)
    except (TypeError, ValueError) as err:
        raise ValueError(f"not a member: {err}") from None
    return _order(s).index(bits)


def _check_elem(s: BDDSet, elem: Type | None) -> None:
    if elem is not None and elem_type(s) != elem:
        raise TypeError(f"a set of {elem_type(s)} values, not {elem}")


_FAR = 1 << 128


def _far_integers_are_uniform() -> bool:
    try:
        from hypothesis.internal.conjecture import providers
    except ImportError:
        return False
    return hasattr(providers, "INTEGERS_DISTRIBUTION")


FAR_INTEGERS_ARE_UNIFORM = _far_integers_are_uniform()


def index_strategy(n: int, *, far: bool | None = None) -> st.SearchStrategy[int]:
    """Uniform indices in [0, n) that shrink toward 0.

    The range sits at an offset of 2^128: for ranges of at most 2^64 values,
    Hypothesis's integer distribution is flat in float64 there, so it falls
    back to a uniform draw, and it shrinks by binary search toward the lower
    bound. Each choice costs about 18 bytes of the 8 KiB a test case may use.
    Where that does not hold (``far=False``), uniform bytes are scaled into
    the range instead, which shrinks less precisely.
    """
    if far if far is not None else FAR_INTEGERS_ARE_UNIFORM:
        return st.integers(_FAR, _FAR + n - 1).map(lambda i: i - _FAR)
    size = ((n - 1).bit_length() + 7) // 8 + 2
    shift = 8 * size
    return st.binary(min_size=size, max_size=size).map(lambda raw: int.from_bytes(raw) * n >> shift)


SMALL_SET = 256
SPECIAL_ODDS = 128


def strategy_for_set(s: BDDSet, elem: Type | None = None) -> st.SearchStrategy[Any]:
    """Members of ``s``, uniformly over its bit patterns; shrinks toward simple members.

    In sets larger than SMALL_SET, a leading choice picks one of the simple
    members (0, -0, 1, -1, the quiet NaNs) with odds len/SPECIAL_ODDS, so
    shrinking can reach them wherever they sit in the index order.
    """
    _check_elem(s, elem)
    order, decode = _order(s), s.codec.decode
    n = order.size
    if n == 0:
        return st.nothing()
    if n <= SMALL_SET:
        return st.integers(0, n - 1).map(lambda i: decode(order.bits(i)))
    members = index_strategy(n).map(lambda i: decode(order.bits(i)))
    if not order.specials:
        return members
    specials = tuple(decode(b) for b in order.specials)

    @st.composite
    def special_or_member(draw: st.DrawFn) -> Any:
        pick = draw(st.integers(0, SPECIAL_ODDS - 1))
        return specials[pick] if pick < len(specials) else draw(members)

    return special_or_member()


def _pairs(classes: Classes) -> list[tuple[str, BDDSet]]:
    return list(classes.items()) if isinstance(classes, Mapping) else list(classes)


def tagged_partition_strategy(
    classes: Classes, elem: Type | None = None
) -> st.SearchStrategy[tuple[str, Any]]:
    """(class name, member): a non-empty class uniformly, then a member uniformly."""
    live = [(name, s) for name, s in _pairs(classes) if s]
    if not live:
        return st.nothing()
    members = [strategy_for_set(s, elem) for _, s in live]

    @st.composite
    def tagged(draw: st.DrawFn) -> tuple[str, Any]:
        i = draw(st.integers(0, len(live) - 1))
        return live[i][0], draw(members[i])

    return tagged()


def partition_strategy(
    classes: Classes, elem: Type | None = None, *, label: str | None = None
) -> st.SearchStrategy[Any]:
    """Members drawn class-first, recording the class with ``hypothesis.event``."""
    tagged = tagged_partition_strategy(classes, elem)

    @st.composite
    def recorded(draw: st.DrawFn) -> Any:
        name, value = draw(tagged)
        try:
            hypothesis.event(f"{label}: {name}" if label else name)
        except InvalidArgument:
            pass
        return value

    return recorded()


def classify(value: Any, classes: Classes) -> str | None:
    """The name of the first class holding the value, or None."""
    for name, s in _pairs(classes):
        if value in s:
            return name
    return None


def domain_size(types: Sequence[Type]) -> int | None:
    """The number of tuples of the product of fixed-width types, or None."""
    total = 1
    for t in types:
        if not is_fixed_width(t):
            return None
        total <<= codec_for(t).width
    return total


def enumerate_domain(types: Sequence[Type]) -> Iterator[tuple[Any, ...]]:
    """Every tuple of runtime values of fixed-width types, in bit-pattern order."""
    codecs = [codec_for(t) for t in types]

    def tuples(i: int) -> Iterator[tuple[Any, ...]]:
        if i == len(codecs):
            yield ()
            return
        decode = codecs[i].decode
        for bits in range(1 << codecs[i].width):
            value = decode(bits)
            for rest in tuples(i + 1):
                yield (value, *rest)

    if len(codecs) == 1:
        decode, width = codecs[0].decode, codecs[0].width
        return ((decode(bits),) for bits in range(1 << width))
    return tuples(0)


def enumerate_set(s: BDDSet) -> Iterator[Any]:
    """Every member of a set as a runtime value, in bit-pattern order."""
    return map(s.codec.decode, iter(s.storage))


# ---------------------------------------------------------------------------
# Formatting


def _shortest(layout: _Layout, mag: int) -> str:
    double = float(layout.value(mag))
    if layout.fmt == "f64":
        return repr(double)
    for digits in range(1, 18):
        text = repr(float(f"{double:.{digits - 1}e}"))
        if layout.nearest(Fraction(text)) == mag:
            return text
    return repr(double)


def format_value(value: Any) -> str:
    """A runtime scalar for messages: floats as shortest decimal plus their bits."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, FloatValue):
        layout = LAYOUTS[value.fmt]
        mag, sign = value.bits & (layout.sign - 1), "-" if value.bits & layout.sign else ""
        if mag > layout.inf_mag:
            text = "nan"
        elif mag == layout.inf_mag:
            text = "inf"
        else:
            text = _shortest(layout, mag)
        return f"{sign}{text} (0x{value.bits:0{(layout.width + 3) // 4}x})"
    return str(value)
