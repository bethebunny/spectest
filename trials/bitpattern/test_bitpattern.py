"""bitpattern conformance: bitpattern.spec bound to the installed bitpattern 0.3.0.

Every spec function is bound to a small adapter that builds its inputs from plain values (a set
from a list of ints and a width, a pattern from its quartets, a diagram from a list of bit
characters), makes one call into bitpattern, and returns what the spec observes. Sets come back
as handles of two models: IntSet (its class name, width, size and members) and CodecSet (a
BDDSet seen through its storage). The spec's comments say what each adapter passes.

The conformances are split by section of the informal specification. A relates clause's planned
calls go to the same conformance, so every function such a clause calls is bound next to it.
"""

from __future__ import annotations

import copy
import ctypes
import dataclasses
import enum
import importlib
import ipaddress
import operator
import pickle
import random
import uuid
from datetime import date, datetime, time, timedelta, timezone, tzinfo
from fractions import Fraction
from functools import cache
from typing import Any

import hypothesis.strategies
import numpy as np

import bitpattern
import bitpattern.bdd as bdd
import bitpattern.codecs as codecs
import bitpattern.dlpack as dlpack
import bitpattern.strategies as strategies
import spectest
from bitpattern import BDD, IntSet, Pattern

spec = spectest.load("bitpattern.spec")

# ---------------------------------------------------------------------------
# Models

# The IntSet model lists every member, so a result must stay small; a larger one is a fault of
# this binding (every function that returns an IntSet keeps its inputs small), not of bitpattern.
MAX_LISTED = 1 << 17


def _members(s: IntSet) -> list[int]:
    if s.size > MAX_LISTED:
        raise RuntimeError(f"refusing to list {s.size} members")
    return list(s)


INTSET = spectest.ModelBinding(
    observers={
        "kind": lambda s: type(s).__name__,
        "width": lambda s: s.width,
        "size": lambda s: s.size,
        "members": _members,
    },
    accepts=lambda obj: isinstance(obj, IntSet),
)

CODECSET = spectest.ModelBinding(
    observers={
        "codec": lambda s: repr(s.codec),
        "codec_width": lambda s: s.codec.width,
        "width": lambda s: s.storage.width,
        "size": lambda s: s.size,
        "has": lambda s, e: e in s.storage,
    },
    accepts=lambda obj: isinstance(obj, codecs.BDDSet),
)

MODELS = {"IntSet": INTSET, "CodecSet": CODECSET}

# FrozenInstanceError is an AttributeError, so it comes first.
ERRORS: dict[type[BaseException], str] = {
    dataclasses.FrozenInstanceError: "FrozenInstanceError",
    TypeError: "TypeError",
    ValueError: "ValueError",
    IndexError: "IndexError",
    OverflowError: "OverflowError",
    AttributeError: "AttributeError",
    BufferError: "BufferError",
    NotImplementedError: "NotImplementedError",
}

# ---------------------------------------------------------------------------
# Shared helpers

OMIT = object()

OPS = {"&": operator.and_, "|": operator.or_, "-": operator.sub, "^": operator.xor}
CMP = {"<=": operator.le, "<": operator.lt, ">=": operator.ge, ">": operator.gt}
EQ = {"==": operator.eq, "!=": operator.ne}
CONTAINERS = {"list": list, "tuple": tuple, "set": set, "frozenset": frozenset}


def build(cls: str, items: list[int], width: int) -> IntSet:
    """IntSet(items, width=width), or the same set as a Pattern."""
    s = IntSet(items, width=width)
    return s if cls == "IntSet" else Pattern.from_bdd(s.bdd, s.width)


def text(quartets: list[list[str]]) -> str:
    return ".".join("".join(q) for q in quartets)


def as_pattern(items: list[int], width: int) -> Pattern:
    s = IntSet(items, width=width)
    return Pattern.from_bdd(s.bdd, s.width)


def codec(name: str) -> Any:
    return getattr(codecs, name)


def diagram(bits: list[str]) -> BDD:
    return bdd.diagram("".join(bits))


def node(items: list[int], width: int) -> BDD:
    return IntSet(items, width=width).bdd


def source(cls: str, items: list[int]) -> Any:
    """A set to export or draw from: an IntSet, a Pattern, or a uint8 BDDSet."""
    return codecs.uint8.set(items) if cls == "BDDSet" else build(cls, items, 0)


def attempt(fn: Any) -> tuple[Any, str | None]:
    """(fn(), None), or (None, message) when fn raises ValueError."""
    try:
        return fn(), None
    except ValueError as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# 0. Surface


def module_names(module: str) -> list[str]:
    return dir(importlib.import_module(module))


def reexported(name: str, home: str) -> bool:
    return getattr(bitpattern, name) is getattr(importlib.import_module(home), name)


def version() -> str:
    return bitpattern.__version__


# ---------------------------------------------------------------------------
# 1. IntSet


def intset(iterable: Any = OMIT, width: Any = OMIT) -> IntSet:
    args = [] if iterable is OMIT else [iterable]
    kwargs = {} if width is OMIT else {"width": width}
    return IntSet(*args, **kwargs)


BAD_ITEMS = {"float": 1.5, "string": "1", "none": None, "bytes": b"1"}


def intset_with_bad_item(iterable: list[int], bad: str, at: int) -> IntSet:
    items: list[Any] = list(iterable)
    items.insert(min(at, len(items)), BAD_ITEMS[bad])
    return IntSet(items)


def intset_of_numpy(iterable: list[int]) -> IntSet:
    return IntSet([np.int64(x) for x in iterable])


def set_attribute(name: str) -> None:
    setattr(IntSet([1]), name, 1)


def intset_range(start: int, stop: int, width: Any = OMIT) -> IntSet:
    if width is OMIT:
        return IntSet.range(start, stop)
    return IntSet.range(start, stop, width=width)


def range_size(start: int, stop: int) -> tuple[int, bool]:
    s = IntSet.range(start, stop)
    return s.size, bool(s)


def range_ends(start: int, stop: int) -> tuple[int | None, int | None]:
    s = IntSet.range(start, stop)
    return next(iter(s), None), next(reversed(s), None)


def from_diagram(cls: str, bits: list[str], width: int) -> IntSet:
    return (IntSet if cls == "IntSet" else Pattern).from_bdd(diagram(bits), width)


def measures(cls: str, iterable: list[int], width: int) -> tuple[int, bool]:
    s = build(cls, iterable, width)
    return len(s), bool(s)


def contains(cls: str, iterable: list[int], width: int, x: Any) -> bool:
    return x in build(cls, iterable, width)


def float_lookups(cls: str, iterable: list[int], width: int, x: float) -> tuple[bool, int]:
    s = build(cls, iterable, width)
    return x in s, s.count(x)


def contains_items(cls: str, iterable: list[int], width: int) -> tuple[list[bool], list[bool]]:
    s = build(cls, iterable, width)
    return [x in s for x in iterable], [float(x) in s for x in iterable]


def iterate(cls: str, iterable: list[int], width: int) -> tuple[list[int], list[int]]:
    s = build(cls, iterable, width)
    return list(iter(s)), list(reversed(s))


def at(cls: str, iterable: list[int], width: int, i: Any) -> int:
    return build(cls, iterable, width)[i]


def slice_(cls: str, iterable: list[int], width: int, start: Any, stop: Any, step: Any = OMIT) -> IntSet:
    s = build(cls, iterable, width)
    return s[start:stop] if step is OMIT else s[start:stop:step]


def index_value(cls: str, iterable: list[int], width: int, value: int, start: Any = OMIT, stop: Any = OMIT) -> int:
    s = build(cls, iterable, width)
    if stop is not OMIT:
        return s.index(value, 0 if start is OMIT else start, stop)
    if start is not OMIT:
        return s.index(value, start)
    return s.index(value)


def positions(cls: str, iterable: list[int], width: int) -> tuple[list[int], list[int]]:
    s = build(cls, iterable, width)
    return [s.index(x) for x in iterable], [s.count(x) for x in iterable]


def count_value(cls: str, iterable: list[int], width: int, value: Any) -> int:
    return build(cls, iterable, width).count(value)


def index_float(cls: str, iterable: list[int], width: int, value: float) -> int:
    return build(cls, iterable, width).index(value)


def choice_seeded(cls: str, iterable: list[int], width: int, seed: int) -> tuple[int, int]:
    s = build(cls, iterable, width)
    return s.choice(rng=random.Random(seed)), s.choice(rng=random.Random(seed))


def choice_default(cls: str, iterable: list[int], width: int) -> int:
    return build(cls, iterable, width).choice()


def widened(cls: str, iterable: list[int], width: int, new_width: int) -> IntSet:
    return build(cls, iterable, width).widened(new_width)


def combine(op: str, cls_a: str, a: list[int], wa: int, cls_b: str, b: list[int], wb: int) -> IntSet:
    return OPS[op](build(cls_a, a, wa), build(cls_b, b, wb))


def combine_iterable(op: str, cls: str, a: list[int], wa: int, b: list[int], container: str) -> IntSet:
    return OPS[op](build(cls, a, wa), CONTAINERS[container](b))


def combine_reflected(op: str, container: str, a: list[int], cls: str, b: list[int], wb: int) -> IntSet:
    return OPS[op](CONTAINERS[container](a), build(cls, b, wb))


def combine_ints(op: str, cls: str, a: list[int], wa: int, b: list[int]) -> IntSet:
    return OPS[op](build(cls, a, wa), list(b))


BAD_OPERANDS: dict[str, Any] = {"int": 5, "float": 1.5, "none": None, "floats": [1.5], "strings": ["1"]}


def combine_bad(op: str, cls: str, a: list[int], wa: int, bad: str) -> IntSet:
    return OPS[op](build(cls, a, wa), BAD_OPERANDS[bad])


def complement(cls: str, iterable: list[int], width: int) -> IntSet:
    return ~build(cls, iterable, width)


def compare(op: str, cls_a: str, a: list[int], wa: int, cls_b: str, b: list[int], wb: int) -> bool:
    return CMP[op](build(cls_a, a, wa), build(cls_b, b, wb))


def _sides(fn: Any, mine: Any, other: Any, side: str) -> Any:
    return fn(mine, other) if side == "right" else fn(other, mine)


def compare_other(op: str, cls: str, a: list[int], wa: int, b: list[int], container: str, side: str) -> bool:
    return _sides(CMP[op], build(cls, a, wa), CONTAINERS[container](b), side)


def equality(op: str, cls_a: str, a: list[int], wa: int, cls_b: str, b: list[int], wb: int) -> bool:
    return EQ[op](build(cls_a, a, wa), build(cls_b, b, wb))


def equality_other(op: str, cls: str, a: list[int], wa: int, b: list[int], container: str, side: str) -> bool:
    return _sides(EQ[op], build(cls, a, wa), CONTAINERS[container](b), side)


def rebuilt(cls_a: str, a: list[int], wa: int, cls_b: str, wb: int) -> tuple[bool, bool]:
    x, y = build(cls_a, a, wa), build(cls_b, a, wb)
    return x == y, hash(x) == hash(y)


def isdisjoint(cls: str, a: list[int], wa: int, b: list[int], container: str) -> bool:
    other = IntSet(b) if container == "IntSet" else CONTAINERS[container](b)
    return build(cls, a, wa).isdisjoint(other)


def intset_repr_eval(iterable: list[int], width: int) -> Any:
    return eval(repr(IntSet(iterable, width=width)), {"__builtins__": {}, "IntSet": IntSet})


INTSET_IMPLS = {
    "module_names": module_names,
    "reexported": reexported,
    "version": version,
    "intset": intset,
    "intset_of_ints": IntSet,
    "intset_with_bad_item": intset_with_bad_item,
    "intset_of_bools": IntSet,
    "intset_of_numpy": intset_of_numpy,
    "set_attribute": set_attribute,
    "intset_range": intset_range,
    "intset_range_float_stop": lambda start, stop: IntSet.range(start, stop),
    "range_size": range_size,
    "range_len": lambda start, stop: len(IntSet.range(start, stop)),
    "range_clipped_size": lambda start, stop: IntSet.range(start, stop, width=128).size,
    "range_ends": range_ends,
    "range_at": lambda start, stop, i: IntSet.range(start, stop)[i],
    "range_index": lambda start, stop, value: IntSet.range(start, stop).index(value),
    "range_contains": lambda start, stop, x: x in IntSet.range(start, stop),
    "from_diagram": from_diagram,
    "measures": measures,
    "contains": contains,
    "contains_bool": contains,
    "contains_text": contains,
    "float_lookups": float_lookups,
    "contains_items": contains_items,
    "iterate": iterate,
    "at": at,
    "at_bool": at,
    "at_float": at,
    "slice": slice_,
    "index_value": index_value,
    "positions": positions,
    "count_value": count_value,
    "index_float": index_float,
    "choice_seeded": choice_seeded,
    "choice_default": choice_default,
    "widened": widened,
    "combine": combine,
    "combine_iterable": combine_iterable,
    "combine_reflected": combine_reflected,
    "combine_ints": combine_ints,
    "combine_bad": combine_bad,
    "complement": complement,
    "compare": compare,
    "compare_other": compare_other,
    "equality": equality,
    "equality_other": equality_other,
    "rebuilt": rebuilt,
    "isdisjoint": isdisjoint,
    "intset_repr": lambda iterable, width: repr(IntSet(iterable, width=width)),
    "intset_repr_eval": intset_repr_eval,
    "range_repr": lambda start, stop: repr(IntSet.range(start, stop)),
    "count_repr": bdd.count_repr,
}

TEN = list(range(10))
INTSET_EXAMPLES: dict[str, list[dict[str, Any]]] = {
    "intset": [
        {},
        {"iterable": [0]},
        {"iterable": [5, 1, 3]},
        {"iterable": [300], "width": 2},
        {"iterable": [1], "width": 1},
        {"iterable": [1], "width": 8},
        {"width": 9},
    ],
    "set_attribute": [{"name": "width"}, {"name": "bdd"}, {"name": "size"}, {"name": "colour"}],
    "intset_range": [
        {"start": 0, "stop": 0},
        {"start": 0, "stop": 2},
        {"start": 5, "stop": 3},
        {"start": 3, "stop": 17, "width": 3},
        {"start": -1, "stop": 3},
        {"start": 0, "stop": 4, "width": -1},
    ],
    "range_size": [{"start": 0, "stop": 2**100}, {"start": 0, "stop": 2**64}],
    "range_len": [{"start": 0, "stop": 2**63 - 1}, {"start": 0, "stop": 2**63}, {"start": 0, "stop": 2**64}],
    "range_clipped_size": [{"start": 0, "stop": 2**100}, {"start": 5, "stop": 2**200}],
    "range_ends": [{"start": 0, "stop": 2**64}],
    "range_at": [{"start": 0, "stop": 2**100, "i": 2**70}, {"start": 0, "stop": 2**100, "i": -1}],
    "float_lookups": [{"cls": "IntSet", "iterable": [1], "width": 0, "x": 1.0}],
    "slice": [
        {"cls": "IntSet", "iterable": TEN, "width": 0, "start": None, "stop": None, "step": -1},
        {"cls": "IntSet", "iterable": TEN, "width": 0, "start": 2, "stop": 5},
    ],
    "complement": [
        {"cls": "IntSet", "iterable": [1, 3], "width": 2},
        {"cls": "IntSet", "iterable": [], "width": 0},
        {"cls": "Pattern", "iterable": [0, 1, 2, 3], "width": 4},
    ],
    "equality": [
        {"op": "==", "cls_a": "IntSet", "a": [1], "wa": 1, "cls_b": "IntSet", "b": [1], "wb": 8},
        {"op": "==", "cls_a": "IntSet", "a": [], "wa": 0, "cls_b": "IntSet", "b": [], "wb": 9},
        {"op": "==", "cls_a": "Pattern", "a": [1, 3], "wa": 3, "cls_b": "IntSet", "b": [1, 3], "wb": 0},
    ],
    "equality_other": [
        {"op": "==", "cls": "IntSet", "a": [1], "wa": 0, "b": [1], "container": "set", "side": "right"},
        {"op": "==", "cls": "IntSet", "a": [1], "wa": 0, "b": [1], "container": "frozenset", "side": "left"},
    ],
    "combine_reflected": [
        {"op": "|", "container": "set", "a": [7], "cls": "Pattern", "b": [1], "wb": 3},
        {"op": "&", "container": "list", "a": [7], "cls": "Pattern", "b": [7], "wb": 3},
        {"op": "-", "container": "set", "a": [7, 1], "cls": "Pattern", "b": [1], "wb": 3},
    ],
    "intset_repr": [
        {"iterable": list(range(20)), "width": 0},
        {"iterable": [], "width": 0},
        {"iterable": [1, 3], "width": 2},
    ],
    "range_repr": [{"start": 0, "stop": 2**64}],
    "count_repr": [{"total": 512}, {"total": 1024}, {"total": 2**63}, {"total": 2**64 - 1}],
}

test_intset = spectest.conformance(
    spec, impls=INTSET_IMPLS, models=MODELS, errors=ERRORS, examples=INTSET_EXAMPLES
)

# ---------------------------------------------------------------------------
# 2. Pattern


def pattern_view(quartets: list[list[str]]) -> dict[str, Any]:
    p = Pattern(text(quartets))
    return {"bits": p.bits, "free": p.free, "branches": list(p.branches), "text": str(p), "shown": repr(p)}


def pattern_parts(iterable: list[int], width: int) -> dict[str, Any]:
    p = as_pattern(iterable, width)
    bits, error = attempt(lambda: p.bits)
    free, _ = attempt(lambda: p.free)
    return {"branches": list(p.branches), "bits": bits, "free": free, "error": error}


def pattern_texts(iterable: list[int], width: int) -> dict[str, Any]:
    p = as_pattern(iterable, width)
    return {"branches": list(p.branches), "text": str(p), "shown": repr(p)}


def pattern_repr_eval(iterable: list[int], width: int) -> Any:
    shown = repr(as_pattern(iterable, width))
    if not shown.startswith("Pattern("):
        return None
    return eval(shown, {"__builtins__": {}, "Pattern": Pattern})


def pattern_shape(quartets: list[list[str]]) -> tuple[int, int]:
    p = Pattern(text(quartets))
    return p.width, p.size


PATTERN_IMPLS = {
    "pattern": lambda quartets: Pattern(text(quartets)),
    "pattern_padded": lambda quartets, before, after: Pattern("".join(before) + text(quartets) + "".join(after)),
    "pattern_text": Pattern,
    "pattern_shape": pattern_shape,
    "pattern_view": pattern_view,
    "branches": lambda iterable, width: list(as_pattern(iterable, width).branches),
    "pattern_parts": pattern_parts,
    "pattern_texts": pattern_texts,
    "pattern_repr_eval": pattern_repr_eval,
}


def quartets(written: str) -> list[list[str]]:
    """The quartets argument for a pattern text: "*1.0000" -> [["*", "1"], ["0", "0", "0", "0"]]."""
    return [list(q) for q in written.split(".")] if written else []


def quartet_examples(*texts: str) -> list[dict[str, Any]]:
    return [{"quartets": quartets(t)} for t in texts]


def set_examples(*sets: tuple[list[int], int]) -> list[dict[str, Any]]:
    return [{"iterable": items, "width": width} for items, width in sets]


DOCUMENTED_SETS = set_examples(
    ([2, 3, 5, 6, 7], 3), ([5, 7], 5), ([0, 1], 4), (list(range(4, 16)), 4), ([], 4), ([1, 3], 0), ([5, 7], 3)
)

PATTERN_EXAMPLES: dict[str, list[dict[str, Any]]] = {
    "pattern": quartet_examples("*1.0000", "1.*", "1?1", "1*1", "*", "11111", "1.1", ".1111", "1111.", "**", "")
    + [{"quartets": [["1", "*", "1", "1", "1"]]}],
    "pattern_text": [{"text": t} for t in ("1|0", "", "   ", "1.1", "11111", " *1.0000\n", "0000 | 0001", "1?1")],
    "pattern_shape": quartet_examples("*1.*.*.0000.1111.?01?", "*1.0000"),
    "pattern_view": quartet_examples("*1.0000", "1.*", "1?1"),
    "branches": DOCUMENTED_SETS,
    "pattern_parts": DOCUMENTED_SETS,
    "pattern_texts": DOCUMENTED_SETS,
}

test_pattern = spectest.conformance(
    spec, impls=PATTERN_IMPLS, models=MODELS, errors=ERRORS, examples=PATTERN_EXAMPLES
)

# ---------------------------------------------------------------------------
# 3. Codecs


def codecs_equal(x: str, y: str) -> tuple[bool, bool]:
    a, b = codec(x), codec(y)
    return a == b, hash(a) == hash(b)


def codec_name(c: str) -> tuple[str, str, int]:
    k = codec(c)
    return repr(k), k.name, k.width


def codec_assign(c: str, field: str) -> None:
    # On a copy, so that a codec that does not refuse is not changed for the other items.
    setattr(copy.copy(codec(c)), field, 1)


def codec_pickle(c: str) -> tuple[bool, bool]:
    k = codec(c)
    return pickle.loads(pickle.dumps(k)) == k, pickle.loads(pickle.dumps(k.all)) == k.all


def base_codec(width: int) -> tuple[Any, int, int]:
    k = codecs.Codec(width=width, name="base")
    return k.dtype().value, k.all.size, k.none.size


def int_codec_fields(w1: int, n1: str, s1: bool, w2: int, n2: str, s2: bool) -> tuple[bool, bool]:
    a, b = codecs.Int(w1, n1, s1), codecs.Int(w2, n2, s2)
    try:
        a.none | b.none
    except TypeError:
        combine = False
    else:
        combine = True
    return a == b, combine


def codec_pattern_message(c: str, quartets: list[list[str]]) -> str:
    _, error = attempt(lambda: codec(c).pattern(text(quartets)))
    return error if error is not None else ""


def codec_set_order(c: str, values: list[int]) -> tuple[list[int], list[int]]:
    s = codec(c).set(values)
    return list(s), list(reversed(s))


def codec_set_measures(c: str, values: list[int]) -> tuple[int, int, bool]:
    s = codec(c).set(values)
    return s.size, len(s), bool(s)


def codec_set_lookup(c: str, values: list[int], x: Any) -> tuple[bool, int]:
    s = codec(c).set(values)
    return x in s, s.count(x)


WRONG_VALUES: dict[str, Any] = {"float": 1.0, "string": "1", "none": None, "bytes": b"\x01"}


def codec_set_choice(c: str, values: list[int], seed: int) -> tuple[Any, Any]:
    s = codec(c).set(values)
    return s.choice(rng=random.Random(seed)), s.choice(rng=random.Random(seed))


def codec_set_combine(op: str, c: str, a: list[int], d: str, b: list[int]) -> Any:
    return OPS[op](codec(c).set(a), codec(d).set(b))


def other_operand(kind: str, values: list[int], s: Any) -> Any:
    return s.storage if kind == "IntSet" else CONTAINERS[kind](values)


def codec_set_combine_other(op: str, c: str, a: list[int], other: str, side: str) -> Any:
    s = codec(c).set(a)
    return _sides(OPS[op], s, other_operand(other, a, s), side)


SET_CMP = {**CMP, "isdisjoint": lambda x, y: x.isdisjoint(y)}


def codec_set_compare(op: str, c: str, a: list[int], d: str, b: list[int]) -> bool:
    return SET_CMP[op](codec(c).set(a), codec(d).set(b))


def codec_set_compare_other(op: str, c: str, a: list[int], other: str, side: str) -> bool:
    s = codec(c).set(a)
    return _sides(SET_CMP[op], s, other_operand(other, a, s), side)


def codec_set_equal(c: str, a: list[int], d: str, b: list[int]) -> tuple[bool, bool]:
    x, y = codec(c).set(a), codec(d).set(b)
    return x == y, hash(x) == hash(y)


def codec_set_equal_other(c: str, a: list[int], other: str, side: str) -> bool:
    s = codec(c).set(a)
    return _sides(operator.eq, s, other_operand(other, a, s), side)


def int_codec_info(c: str) -> dict[str, Any]:
    k = codec(c)
    return {
        "width": k.width,
        "signed": k.signed,
        "min": k.min,
        "max": k.max,
        "dtype": k.dtype().value,
        "all": k.all.size,
    }


BAD_INTS: dict[str, Any] = {"float": 1.0, "string": "1", "none": None}


def custom_int(width: int, signed: bool) -> tuple[tuple[int, int], Any]:
    k = codecs.Int(width, "custom", signed)
    return (k.min, k.max), k.dtype().value


def float_codec_info(c: str) -> dict[str, Any]:
    k = codec(c)
    return {
        "kind": type(k).__name__,
        "width": k.width,
        "exponent": k.exponent,
        "max": k.max,
        "min": k.min,
        "dtype": k.dtype().value,
    }


BAD_FLOATS: dict[str, Any] = {"string": "1.0", "none": None, "bytes": b"1"}

FLOAT_SETS = (
    "sign_clear", "sign_set", "zeros", "positive", "negative", "nonnegative",
    "subnormal", "infinities", "nan", "finite",
)  # fmt: skip


def float_set_sizes(c: str) -> dict[str, int]:
    k = codec(c)
    return {"total": k.all.size, **{name: getattr(k, name).size for name in FLOAT_SETS}}


def float_classes(c: str, b: int) -> dict[str, bool]:
    k = codec(c)
    return {name: b in getattr(k, name).storage for name in FLOAT_SETS}


def f16_range_ends(start: float | None, stop: float | None) -> tuple[float, float] | None:
    s = codecs.float16.range(start, stop)
    return (s[0], s[-1]) if s.size else None


def char_category_pair(major: str, minor: str) -> tuple[bool, int]:
    m = codecs.char.category(minor)
    return codecs.char.category(major) >= m, m.size


def ip(family: str) -> Any:
    return codecs.ipv4 if family == "ipv4" else codecs.ipv6


def address(family: str, v: int) -> Any:
    return ipaddress.IPv4Address(v) if family == "ipv4" else ipaddress.IPv6Address(v)


def bad_ip_value(family: str, bad: str) -> Any:
    v4 = family == "ipv4"
    return {
        "float": 1.0,
        "bytes": bytes(4 if v4 else 16),
        "other_family": ipaddress.IPv6Address(1) if v4 else ipaddress.IPv4Address(1),
        "slash": "10.0.0.1/8" if v4 else "::1/64",
        "interface": ipaddress.IPv4Interface("10.0.0.1/8") if v4 else ipaddress.IPv6Interface("::1/64"),
    }[bad]


def ip_decode(family: str, b: int) -> tuple[str, str]:
    a = ip(family).decode(b)
    return type(a).__name__, str(a)


def ip_bounds(family: str) -> tuple[str, str]:
    k = ip(family)
    return str(k.min), str(k.max)


def ip_cidr(octets: list[int], prefix: int | None) -> Any:
    written = ".".join(map(str, octets)) + ("" if prefix is None else f"/{prefix}")
    return codecs.ipv4.cidr(written)


def networks(k: Any, s: Any) -> list[tuple[int, int]]:
    return [(int(n.network_address), n.prefixlen) for n in k.networks(s)]


def ip_networks_wrong(iterate: bool) -> int:
    listed = codecs.ipv4.networks(codecs.ipv6.all)
    return len(list(listed)) if iterate else 0


def mac_text(octets: list[int], style: str, upper: bool) -> str:
    pairs = [f"{o:02x}" for o in octets]
    if style == "dot":
        digits = "".join(pairs)
        written = ".".join(digits[i : i + 4] for i in range(0, len(digits), 4))
    else:
        written = (":" if style == "colon" else "-").join(pairs)
    return written.upper() if upper else written


def mac_named(name: str, b: int) -> tuple[int, bool]:
    s = getattr(codecs.mac, name)
    return s.size, b in s.storage


def mac_oui(octets: list[int], sep: str, upper: bool) -> Any:
    written = sep.join(f"{o:02x}" for o in octets)
    return codecs.mac.oui(written.upper() if upper else written)


def date_decode(b: int) -> tuple[int, int, int]:
    d = codecs.dates.decode(b)
    return d.year, d.month, d.day


def date_bounds() -> tuple[tuple[int, int, int], tuple[int, int, int], int]:
    lo, hi = codecs.dates.min, codecs.dates.max
    return (lo.year, lo.month, lo.day), (hi.year, hi.month, hi.day), codecs.dates.all.size


class NoOffset(tzinfo):
    """A tzinfo whose utcoffset() is None: a datetime carrying it counts as naive."""

    def utcoffset(self, dt: datetime | None) -> None:
        return None

    def dst(self, dt: datetime | None) -> None:
        return None

    def tzname(self, dt: datetime | None) -> None:
        return None


def datetime_codec_of(zone: int | None) -> Any:
    return codecs.DateTime(None if zone is None else timezone(timedelta(minutes=zone)))


def datetime_encode(zone: int | None, ordinal: int, micros: int, offset: int | None, opaque: bool) -> int:
    local = datetime.combine(date.fromordinal(ordinal), time()) + timedelta(microseconds=micros)
    if opaque:
        tz: tzinfo | None = NoOffset()
    elif offset is not None:
        tz = timezone(timedelta(minutes=offset))
    else:
        tz = None
    return datetime_codec_of(zone).encode(local.replace(tzinfo=tz))


BAD_DATETIMES: dict[str, Any] = {"date": date(2024, 1, 1), "string": "2024-01-01T00:00", "int": 0}


def datetime_codec(zone: int | None) -> tuple[str, int, int, bool]:
    k = datetime_codec_of(zone)
    return k.name, k.width, k.all.size, k == codecs.datetimes


def datetime_decode(zone: int | None, b: int) -> tuple[int, int, int | None]:
    v = datetime_codec_of(zone).decode(b)
    micros = ((v.hour * 60 + v.minute) * 60 + v.second) * 1_000_000 + v.microsecond
    off = v.utcoffset()
    return v.date().toordinal(), micros, None if off is None else off // timedelta(minutes=1)


def uuid_encode(hi: int, lo: int, form: str) -> int:
    u = uuid.UUID(int=(hi << 64) | lo)
    value = {"object": u, "hyphens": str(u), "hex": u.hex, "braces": "{" + str(u) + "}", "urn": u.urn}[form]
    return codecs.uuid128.encode(value)


def uuid_rfc9562(hi: int, lo: int) -> tuple[int, bool]:
    s = codecs.uuid128.rfc9562
    return s.size, ((hi << 64) | lo) in s.storage


def uuid_version(n: int, hi: int, lo: int) -> tuple[int, bool]:
    s = codecs.uuid128.version(n)
    return s.size, ((hi << 64) | lo) in s.storage


@cache
def enum_of(n: int, alias: int | None = None) -> type[enum.Enum]:
    """The Enum E with members M0 ... M(n-1) of values 0 ... n-1 (and an alias A of member alias)."""
    names = [(f"M{i}", i) for i in range(n)]
    if alias is not None:
        names.append(("A", alias))
    if not names:

        class E(enum.Enum):
            pass

        return E
    return enum.Enum("E", names)


@cache
def int_enum_of(n: int) -> type[enum.IntEnum]:
    if n == 0:

        class IE(enum.IntEnum):
            pass

        return IE
    return enum.IntEnum("IE", [(f"M{i}", 100 + i) for i in range(n)])


class Perm(enum.Flag):
    R = 4
    W = 2
    X = 1


class Tree(enum.Flag):
    LEAF = 4
    CHAIN = 12
    LOW = 1


FLAG_CLASSES: dict[str, type[enum.Flag]] = {"Perm": Perm, "Tree": Tree}


def members_codec(n: int) -> tuple[int, int, str]:
    k = codecs.Members(enum_of(n))
    return k.width, k.all.size, k.name


def members_encode(n: int, i: int, alias: bool) -> tuple[int, int]:
    e = enum_of(n, i if alias else None)
    k = codecs.Members(e)
    member = e["A"] if alias else e[f"M{i}"]
    return k.encode(member), k.all.size


def members_decode(n: int, i: int) -> int:
    e = enum_of(n)
    return list(e).index(codecs.Members(e).decode(i))


class Other(enum.Enum):
    X = 0


def members_encode_bad(n: int, bad: str) -> int:
    if bad == "flag_combination":
        return codecs.Members(Perm).encode(Perm.R | Perm.W)
    if bad == "int_enum_int":
        return codecs.Members(int_enum_of(n)).encode(100)
    e = enum_of(n)
    value = e["M0"].value if bad == "value" else Other.X
    return codecs.Members(e).encode(value)


def picked(e: type[enum.Enum], picks: list[bool]) -> list[Any]:
    return [m for i, m in enumerate(e) if i < len(picks) and picks[i]]


def members_complement(n: int, picks: list[bool]) -> list[int]:
    e = enum_of(n)
    members = list(e)
    return [members.index(m) for m in ~codecs.Members(e).set(picked(e, picks))]


def flags_codec(cls: str) -> tuple[int, list[int], str]:
    k = codecs.Flags(FLAG_CLASSES[cls])
    return k.width, list(k.all.storage), k.name


def flags_having(cls: str, mask: int, lacking: bool) -> list[int]:
    c = FLAG_CLASSES[cls]
    k = codecs.Flags(c)
    s = k.lacking(c(mask)) if lacking else k.having(c(mask))
    return list(s.storage)


def plain_codec_attributes(kind: str) -> list[bool]:
    k = {
        "Members": codecs.Members(enum_of(3)),
        "Flags": codecs.Flags(Perm),
        "Tuple": codecs.Tuple(codecs.uint8),
    }[kind]
    return [hasattr(k, a) for a in ("min", "max", "range")]


def tuple_codec(fields: list[str]) -> tuple[int, str, int]:
    k = codecs.Tuple(*[codec(f) for f in fields])
    return k.width, k.name, k.all.size


def pair_codec() -> Any:
    return codecs.Tuple(codecs.uint8, codecs.int8)


def product_none() -> tuple[int, str]:
    s = codecs.product()
    return s.size, repr(s.codec)


def product_operator(a: list[int], b: list[int], c: list[int]) -> tuple[bool, list[Any]]:
    x, y, z = codecs.uint8.set(a), codecs.int8.set(b), codecs.uint8.set(c)
    return x * y == codecs.product(x, y), list(x * y * z)


def product_operator_bad(a: list[int], other: str) -> Any:
    x = codecs.uint8.set(a)
    return x * {"IntSet": IntSet(a), "list": list(a), "int": 1, "set": set(a)}[other]


CODEC_IMPLS = {
    "codecs_equal": codecs_equal,
    "codec_name": codec_name,
    "codec_assign": codec_assign,
    "codec_pickle": codec_pickle,
    "base_codec": base_codec,
    "base_codec_encode": lambda width, value: codecs.Codec(width=width, name="base").encode(value),
    "int_codec_fields": int_codec_fields,
    "codec_pattern": lambda c, quartets: codec(c).pattern(text(quartets)),
    "codec_pattern_message": codec_pattern_message,
    "bddset_new": lambda c, iterable, width: codecs.BDDSet(codec(c), IntSet(iterable, width=width)),
    "codec_set": lambda c, values: codec(c).set(values),
    "codec_set_order": codec_set_order,
    "codec_set_measures": codec_set_measures,
    "codec_set_at": lambda c, values, i: codec(c).set(values)[i],
    "codec_set_slice": lambda c, values, start, stop: codec(c).set(values)[start:stop],
    "codec_set_lookup": codec_set_lookup,
    "codec_set_lookup_other": lambda c, values, x: codec_set_lookup(c, values, WRONG_VALUES[x]),
    "codec_set_index": lambda c, values, x: codec(c).set(values).index(x),
    "codec_set_index_other": lambda c, values, x: codec(c).set(values).index(WRONG_VALUES[x]),
    "codec_set_choice": codec_set_choice,
    "codec_set_combine": codec_set_combine,
    "codec_set_combine_other": codec_set_combine_other,
    "codec_set_compare": codec_set_compare,
    "codec_set_compare_other": codec_set_compare_other,
    "codec_set_equal": codec_set_equal,
    "codec_set_equal_other": codec_set_equal_other,
    "codec_set_complement": lambda c, values: ~codec(c).set(values),
    "char_complement": lambda t: ~codecs.char.set(set(t)),
    "codec_set_repr": lambda c, values: repr(codec(c).set(values)),
    "all_repr": lambda c: repr(codec(c).all),
    "int_codec_info": int_codec_info,
    "int_encode": lambda c, v: codec(c).encode(v),
    "int_encode_bool": lambda c, v: codec(c).encode(v),
    "int_encode_numpy": lambda c, v: codec(c).encode(np.int64(v)),
    "int_encode_bad": lambda c, bad: codec(c).encode(BAD_INTS[bad]),
    "int_decode": lambda c, b: codec(c).decode(b),
    "int_range": lambda c, start, stop: codec(c).range(start, stop),
    "int_range_values": lambda c, start, span: list(codec(c).range(start, start + span)),
    "int_range_float": lambda c, bound: codec(c).range(bound, None),
    "custom_int": custom_int,
    "float_codec_info": float_codec_info,
    "f16_decode": lambda b: codecs.float16.decode(b),
    "f16_encode": lambda x: codecs.float16.encode(x),
    "float_encode": lambda c, x: codec(c).encode(x),
    "float_encode_int": lambda c, v: codec(c).encode(v),
    "float_encode_bool": lambda c, v: codec(c).encode(v),
    "float_encode_fraction": lambda c, num, den: codec(c).encode(Fraction(num, den)),
    "float_encode_bad": lambda c, bad: codec(c).encode(BAD_FLOATS[bad]),
    "float_decode": lambda c, b: codec(c).decode(b),
    "float_decode_out_of_range": lambda c, b: codec(c).decode(b),
    "float8_decode": lambda c, b: codec(c).decode(b),
    "float8_encode": lambda c, x: codec(c).encode(x),
    "float_set_sizes": float_set_sizes,
    "float_classes": float_classes,
    "f16_set_order": lambda xs: list(codecs.float16.set(xs)),
    "f16_range_has": lambda start, stop, x: x in codecs.float16.range(start, stop),
    "float_range_size": lambda c, start, stop: codec(c).range(start, stop).size,
    "f16_range_ends": f16_range_ends,
    "floatfn_dtype": lambda width, exponent: codecs.FloatFN(width, "custom", exponent).dtype().value,
    "char_encode": lambda s: codecs.char.encode(s),
    "char_encode_codepoint": lambda cp: codecs.char.encode(chr(cp)),
    "char_encode_narrow": lambda width, s: codecs.Char(width, "narrow").encode(s),
    "char_encode_bad": lambda bad: codecs.char.encode({"int": 65, "bytes": b"A", "none": None}[bad]),
    "char_decode": lambda b: codecs.char.decode(b),
    "char_all": lambda width: codecs.Char(width, "narrow").all,
    "char_bounds": lambda: (codecs.char.min, codecs.char.max),
    "char_range": lambda start, stop: codecs.char.range(start, stop),
    "char_category": lambda name: codecs.char.category(name),
    "char_category_pair": char_category_pair,
    "char_category_ascii": lambda name: "".join(codecs.char.category(name) & codecs.char.range("\0", "\x80")),
    "ip_encode_int": lambda family, v: ip(family).encode(v),
    "ip_encode_address": lambda family, v: ip(family).encode(address(family, v)),
    "ip_encode_text": lambda family, t: ip(family).encode(t),
    "ip_encode_dotted": lambda octets: codecs.ipv4.encode(".".join(map(str, octets))),
    "ip_encode_groups": lambda groups: codecs.ipv6.encode(":".join(f"{g:x}" for g in groups)),
    "ip_encode_bad": lambda family, bad: ip(family).encode(bad_ip_value(family, bad)),
    "ip_decode": ip_decode,
    "ip_bounds": ip_bounds,
    "ip_range": lambda family, start, stop: ip(family).range(start, stop),
    "ip_cidr": ip_cidr,
    "ip_networks": lambda start, span: networks(codecs.ipv4, codecs.ipv4.range(start, start + span)),
    "ip_networks_all": lambda family: networks(ip(family), ip(family).all),
    "ip_networks_wrong": ip_networks_wrong,
    "mac_encode": lambda octets, style, upper: codecs.mac.encode(mac_text(octets, style, upper)),
    "mac_encode_text": lambda t: codecs.mac.encode(t),
    "mac_encode_bad": lambda bad: codecs.mac.encode({"int": 1, "bytes": bytes(6), "none": None}[bad]),
    "mac_decode": lambda b: codecs.mac.decode(b),
    "mac_named": mac_named,
    "mac_oui": mac_oui,
    "mac_oui_text": lambda t: codecs.mac.oui(t),
    "date_encode": lambda year, month, day: codecs.dates.encode(date(year, month, day)),
    "date_encode_bad": lambda bad: codecs.dates.encode(
        {"datetime": datetime(2024, 1, 1), "string": "2024-01-01", "int": 738886}[bad]
    ),
    "date_decode": date_decode,
    "date_bounds": date_bounds,
    "date_range_size": lambda y1, m1, d1, y2, m2, d2: codecs.dates.range(date(y1, m1, d1), date(y2, m2, d2)).size,
    "datetime_encode": datetime_encode,
    "datetime_encode_bad": lambda zone, bad: datetime_codec_of(zone).encode(BAD_DATETIMES[bad]),
    "datetime_codec": datetime_codec,
    "datetime_decode": datetime_decode,
    "uuid_encode": uuid_encode,
    "uuid_encode_bad": lambda bad: codecs.uuid128.encode({"int": 1, "bytes": bytes(16), "none": None}[bad]),
    "uuid_encode_text": lambda t: codecs.uuid128.encode(t),
    "uuid_decode": lambda b: str(codecs.uuid128.decode(b)),
    "uuid_rfc9562": uuid_rfc9562,
    "uuid_version": uuid_version,
    "uuid4_member": lambda: uuid.uuid4() in codecs.uuid128.version(4),
    "members_codec": members_codec,
    "members_encode": members_encode,
    "members_decode": members_decode,
    "members_encode_bad": members_encode_bad,
    "members_complement": members_complement,
    "flags_codec": flags_codec,
    "flags_encode": lambda cls, mask: codecs.Flags(FLAG_CLASSES[cls]).encode(FLAG_CLASSES[cls](mask)),
    "flags_decode": lambda cls, b: codecs.Flags(FLAG_CLASSES[cls]).decode(b).value,
    "flags_encode_int": lambda cls, v: codecs.Flags(FLAG_CLASSES[cls]).encode(v),
    "flags_having": flags_having,
    "plain_codec_attributes": plain_codec_attributes,
    "tuple_codec": tuple_codec,
    "tuple_encode": lambda a, b, x, y: codecs.Tuple(codec(a), codec(b)).encode((x, y)),
    "tuple_encode_shape": lambda values, as_list: codecs.Tuple(codecs.int8, codecs.int8).encode(
        list(values) if as_list else tuple(values)
    ),
    "tuple_decode": lambda a, b, e: tuple(codecs.Tuple(codec(a), codec(b)).decode(e)),
    "tuple_set_order": lambda pairs: list(pair_codec().set(pairs)),
    "product_of": lambda a, b: codecs.product(codecs.uint8.set(a), codecs.int8.set(b)),
    "product_none": product_none,
    "product_operator": product_operator,
    "product_operator_bad": product_operator_bad,
    "product_example": lambda: codecs.product(codecs.ipv4.cidr("10.0.0.0/8"), codecs.uint16.range(1024, 65536)).size,
    "product_contains": lambda octets, port: (".".join(map(str, octets)), port)
    in codecs.product(codecs.ipv4.all, codecs.uint16.all),
    "project_of": lambda pairs, index: list(codecs.project(pair_codec().set(pairs), index)),
    "project_bad": lambda values: list(codecs.project(codecs.uint8.set(values), 0)),
}

ALL_FLOATS = ["float16", "bfloat16", "float32", "float64", "float8_e5m2", "float8_e4m3fn"]

CODEC_EXAMPLES: dict[str, list[dict[str, Any]]] = {
    "codec_set_order": [{"c": "int8", "values": [-1, 0, 1, -128, 127]}],
    "codec_set_lookup_other": [{"c": "uint8", "values": [1], "x": "float"}],
    "codec_set_equal": [{"c": "uint8", "a": [1], "d": "int8", "b": [1]}],
    "all_repr": [{"c": "uint8"}],
    "int_range": [{"c": "int8", "start": -200, "stop": 200}, {"c": "int8", "start": 5, "stop": 3}],
    "custom_int": [{"width": 5, "signed": True}],
    "float_encode": [
        {"c": "float16", "x": 1 + 2**-11},
        {"c": "float16", "x": 1 + 3 * 2**-11},
        {"c": "float16", "x": -1e-10},
        {"c": "float16", "x": 65520.0},
        {"c": "float16", "x": 65504.0},
    ],
    "float8_encode": [
        {"c": "float8_e4m3fn", "x": 464.0},
        {"c": "float8_e4m3fn", "x": 465.0},
        {"c": "float8_e4m3fn", "x": 0.3},
        {"c": "float8_e4m3fn", "x": float("inf")},
    ],
    "float8_decode": [{"c": "float8_e4m3fn", "b": 0x7E}],
    "float_range_size": [{"c": c, "start": 1.0, "stop": 2.0} for c in ALL_FLOATS]
    + [{"c": "float16", "start": None, "stop": None}, {"c": "float8_e4m3fn", "start": None, "stop": None}]
    + [{"c": "float16", "start": 1e10, "stop": None}, {"c": "float16", "start": -1e10, "stop": -65504.0}],
    "f16_range_has": [
        {"start": 0.0, "stop": None, "x": float("inf")},
        {"start": 0.0, "stop": float("inf"), "x": float("inf")},
        {"start": 0.0, "stop": None, "x": -0.0},
        {"start": -0.0, "stop": None, "x": -0.0},
        {"start": -0.0, "stop": 0.0, "x": -0.0},
        {"start": None, "stop": 0.0, "x": -0.0},
    ],
    "f16_range_ends": [{"start": -1.0, "stop": 1.0}],
    "char_range": [{"start": "퟿", "stop": ""}, {"start": "a", "stop": "ab"}],
    "char_category": [{"name": n} for n in ("lu", "Xx", "L", "Lu", "Cs")],
    "char_category_ascii": [{"name": "Sm"}],
    "char_all": [{"width": 7}, {"width": 21}],
    "ip_decode": [{"family": "ipv6", "b": 1}],
    "ip_cidr": [{"octets": [10, 1, 2, 3], "prefix": 8}, {"octets": [0, 0, 0, 0], "prefix": 0}],
    "ip_networks": [{"start": 0x0A000001, "span": 8}],
    "mac_encode_text": [
        {"text": t}
        for t in (
            "01:23:45:67:89:ab",
            "01-23-45-67-89-AB",
            "0123.4567.89ab",
            "01:Ab:45:67:89:ab",
            "01:23-45:67:89:ab",
            "0123456789ab",
            " 01:23:45:67:89:ab",
            "01:23:45:67:89:ab\n",
        )
    ],
    "mac_oui_text": [{"text": t} for t in ("00:1a:2b", "00-1A-2B", "001a.2b", "00:1a")],
    "mac_named": [{"name": n, "b": 0xFFFFFFFFFFFF} for n in ("broadcast", "multicast", "local")],
    "date_encode": [{"year": 1, "month": 1, "day": 1}],
    "date_range_size": [{"y1": 2024, "m1": 1, "d1": 1, "y2": 2025, "m2": 1, "d2": 1}],
    "datetime_encode": [
        {"zone": 0, "ordinal": 1, "micros": 0, "offset": 60, "opaque": False},
        {"zone": 0, "ordinal": 738886, "micros": 7 * 3600 * 10**6, "offset": -300, "opaque": False},
        {"zone": 0, "ordinal": 738886, "micros": 12 * 3600 * 10**6, "offset": 0, "opaque": False},
    ],
    "datetime_codec": [{"zone": 0}, {"zone": 300}, {"zone": 60}, {"zone": None}],
    "members_complement": [{"n": 3, "picks": [False, True]}],
    "flags_having": [
        {"cls": "Perm", "mask": 2, "lacking": False},
        {"cls": "Perm", "mask": 0, "lacking": False},
        {"cls": "Perm", "mask": 0, "lacking": True},
    ],
    "flags_encode": [{"cls": "Tree", "mask": 8}, {"cls": "Tree", "mask": 12}],
    "tuple_codec": [{"fields": []}],
    "tuple_set_order": [{"pairs": [(2, 0), (1, 5), (1, -1)]}],
    "product_contains": [{"octets": [10, 1, 2, 3], "port": 8080}],
}

test_codecs = spectest.conformance(
    spec, impls=CODEC_IMPLS, models=MODELS, errors=ERRORS, examples=CODEC_EXAMPLES
)

# ---------------------------------------------------------------------------
# 4. bitpattern.bdd


def diagram_node(bits: list[str]) -> tuple[int, bool, int, bool, int, int]:
    d = diagram(bits)
    return d.bit, d.leaf, d.size, bool(d), bdd.node_count(d), bdd.path_count(d)


def bdd_leaves() -> dict[str, Any]:
    a, r = BDD.ACCEPT, BDD.REJECT
    return {
        "accept_bit": a.bit,
        "reject_bit": r.bit,
        "accept_leaf": a.leaf,
        "reject_leaf": r.leaf,
        "accept_size": a.size,
        "reject_size": r.size,
        "accept_true": bool(a),
        "reject_true": bool(r),
        "inverse": (~a) is r,
        "children": a.left is a and a.right is a and r.left is r and r.right is r,
        "match_args": list(BDD.__match_args__),
        "accept_repr": repr(a),
        "reject_repr": repr(r),
    }


def not_bdd(kind: str) -> Any:
    """An operand that is not a BDD, made when needed."""
    return {"int": lambda: 1, "IntSet": IntSet, "none": lambda: None, "string": lambda: "1"}[kind]()


def bdd_node_bad(bit: int, bad: str, side: str) -> bool:
    other = not_bdd(bad)
    BDD(bit, other, BDD.REJECT) if side == "left" else BDD(bit, BDD.REJECT, other)
    return True


def bdd_identity(bit: int, child: list[str]) -> tuple[bool, bool]:
    d = diagram(child)
    return BDD(bit, d, d) is d, diagram(child) is diagram(list(child))


def bdd_operator_bad(op: str, a: list[str], bad: str, side: str) -> bool:
    _sides(OPS[op], diagram(a), not_bdd(bad), side)
    return True


def bdd_equal(a: list[str], b: list[str]) -> tuple[bool, bool]:
    x, y = diagram(a), diagram(b)
    return x == y, hash(x) == hash(y)


def bdd_copies(a: list[str]) -> tuple[bool, bool, bool]:
    d = diagram(a)
    return copy.copy(d) is d, copy.deepcopy(d) is d, pickle.loads(pickle.dumps(d)) is d


def bdd_path_count(iterable: list[int], width: int, extra: int) -> tuple[int, int]:
    s = IntSet(iterable, width=width)
    return bdd.path_count(s.bdd), len(list(bdd.paths(s.bdd, width=s.width + extra)))


def bdd_narrowed(iterable: list[int], width: int, q: int, value: int) -> tuple[int, bool]:
    m = bdd.narrowed(node(iterable, width), width=q)
    return m.bit, bdd.accepts(m, value)


def bdd_exactly(values: list[int], width: int) -> tuple[int, list[int]]:
    d, w = bdd.exactly_these(values, width=width)
    return w, list(bdd.members(d, width=w))


def bdd_interval(start: int, stop: int, width: int) -> tuple[list[int], bool, bool, list[tuple[int, int]]]:
    d = bdd.interval(start, stop, width=width)
    blocks = [tuple(b) for b in bdd.blocks(d, width=width)]
    return list(bdd.members(d, width=width)), d is BDD.REJECT, d is BDD.ACCEPT, blocks


BDD_IMPLS = {
    "diagram_node": diagram_node,
    "diagram_text": lambda t: bdd.diagram(t).bit,
    "diagram_accepts": lambda bits, value: bdd.accepts(diagram(bits), value),
    "bdd_leaves": bdd_leaves,
    "bdd_node": lambda bit, left, right, value: bdd.accepts(BDD(bit, diagram(left), diagram(right)), value),
    "bdd_identity": bdd_identity,
    "bdd_node_bad": bdd_node_bad,
    "bdd_operator": lambda op, a, b, value: bdd.accepts(OPS[op](diagram(a), diagram(b)), value),
    "bdd_invert": lambda a, value: (bdd.accepts(~diagram(a), value), (~BDD.ACCEPT) is BDD.REJECT),
    "bdd_operator_bad": bdd_operator_bad,
    "bdd_equal": bdd_equal,
    "bdd_equal_other": lambda a, other: diagram(a) == not_bdd(other),
    "bdd_copies": bdd_copies,
    "bdd_repr": lambda bits: repr(diagram(bits)),
    "bdd_count": lambda iterable, width, q: bdd.count(node(iterable, width), width=q),
    "bdd_nth": lambda iterable, width, n, q: bdd.nth(node(iterable, width), n, width=q),
    "bdd_rank": lambda iterable, width, value, q: bdd.rank(node(iterable, width), value, width=q),
    "bdd_members": lambda iterable, width, q: list(bdd.members(node(iterable, width), width=q)),
    "bdd_blocks": lambda iterable, width, q: [tuple(b) for b in bdd.blocks(node(iterable, width), width=q)],
    "bdd_paths": lambda iterable, width, q: list(bdd.paths(node(iterable, width), width=q)),
    "leaf_paths": lambda accept, q: list(bdd.paths(BDD.ACCEPT if accept else BDD.REJECT, width=q)),
    "bdd_path_count": bdd_path_count,
    "bdd_narrowed": bdd_narrowed,
    "bdd_exactly": bdd_exactly,
    "bdd_exactly_ints": lambda values: bdd.exactly_these(values, width=0)[1],
    "bdd_exactly_bad": lambda bad: bdd.exactly_these([{"float": 1.5, "string": "1"}[bad]], width=0)[1],
    "bdd_interval": bdd_interval,
    "bdd_lshift": lambda bits, by, value: bdd.accepts(bdd.lshift(diagram(bits), by), value),
    "bdd_freed": lambda bits, low, high, value: bdd.accepts(
        bdd.freed_between(diagram(bits), low_bit=low, high_bit=high), value
    ),
    "bdd_relations": lambda a, b: (bdd.subset(diagram(a), diagram(b)), bdd.disjoint(diagram(a), diagram(b))),
    "bdd_collect": bdd.collect,
    "bdd_stats": bdd.stats,
}

BDD_EXAMPLES: dict[str, list[dict[str, Any]]] = {
    "diagram_node": [{"bits": ["1", "?", "0"]}, {"bits": []}],
    "diagram_text": [{"text": t} for t in ("", "1*0", "1.0", "1?0")],
    "diagram_accepts": [{"bits": [], "value": 999}],
    "bdd_interval": [{"start": 3, "stop": 17, "width": 5}, {"start": 0, "stop": 32, "width": 5}],
    "leaf_paths": [{"accept": True, "q": 3}, {"accept": True, "q": 0}, {"accept": False, "q": 3}],
}

test_bdd = spectest.conformance(spec, impls=BDD_IMPLS, models=MODELS, errors=ERRORS, examples=BDD_EXAMPLES)

# ---------------------------------------------------------------------------
# 5 and 6. strategies, DLPack and DType

_capsule_name = ctypes.pythonapi.PyCapsule_GetName
_capsule_name.restype = ctypes.c_char_p
_capsule_name.argtypes = [ctypes.py_object]


def exported(s: Any) -> tuple[str, list[Any]]:
    a = np.from_dlpack(s)
    return a.dtype.name, a.tolist()


def dtype_member(name: str) -> tuple[Any, int, int, bool]:
    m = dlpack.DType[name]
    return m.value, m.code, m.bits, isinstance(m, enum.Enum)


def export_members(n: int, picks: list[bool]) -> list[int]:
    e = int_enum_of(n)
    return np.from_dlpack(codecs.Members(e).set(picked(e, picks))).tolist()


def dlpack_errors(cls: str, iterable: list[int], stream: Any, device: Any, copy: Any) -> bool:
    source(cls, iterable).__dlpack__(stream=stream, dl_device=device, copy=copy)
    return True


def dlpack_capsule(cls: str, iterable: list[int], max_version: Any) -> str:
    capsule = source(cls, iterable).__dlpack__(max_version=max_version)
    return _capsule_name(capsule).decode()


EXPORT_IMPLS = {
    "from_set_strategy": lambda cls, iterable: isinstance(
        strategies.from_set(source(cls, iterable)), hypothesis.strategies.SearchStrategy
    ),
    "dtype_member": dtype_member,
    "dlpack_device": lambda cls, iterable, width: tuple(
        (codecs.uint8.set(iterable) if cls == "BDDSet" else build(cls, iterable, width)).__dlpack_device__()
    ),
    "export_intset": lambda iterable, width: exported(IntSet(iterable, width=width)),
    "export_rows": lambda iterable, width: exported(IntSet(iterable, width=width)),
    "export_signed": lambda c, values: exported(codec(c).set(values)),
    "export_int128": lambda values: np.from_dlpack(codecs.int128.set(values)).tolist(),
    "export_f16": lambda xs: exported(codecs.float16.set(xs)),
    "export_members": export_members,
    "dlpack_errors": dlpack_errors,
    "dlpack_capsule": dlpack_capsule,
}

EXPORT_EXAMPLES: dict[str, list[dict[str, Any]]] = {
    "export_intset": [{"iterable": [300, 1, 20], "width": 0}, {"iterable": [], "width": 0}],
    "export_signed": [{"c": "int8", "values": [-1, 0, 1, -128]}],
    "dlpack_errors": [
        {"cls": "IntSet", "iterable": [1], "stream": None, "device": (1, 0), "copy": None},
        {"cls": "IntSet", "iterable": [1], "stream": None, "device": None, "copy": True},
        {"cls": "BDDSet", "iterable": [1], "stream": None, "device": None, "copy": False},
    ],
    "dlpack_capsule": [
        {"cls": "IntSet", "iterable": [1], "max_version": v} for v in (None, (0, 8), (1, 0), (1, 1))
    ],
}

test_export = spectest.conformance(
    spec, impls=EXPORT_IMPLS, models=MODELS, errors=ERRORS, examples=EXPORT_EXAMPLES
)
