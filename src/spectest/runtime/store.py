"""Exact JSON encoding of spec values, and the counterexample store under ``.spectest/``.

The encoding is self-describing, so a value decodes without its type; a type,
when given, is checked against the decoded value. JSON scalars carry bools,
ints, strings and none; everything else is a one-key tagged object:

| Value                     | JSON                                                     |
| ------------------------- | -------------------------------------------------------- |
| list or tuple             | ``[...]`` (decodes to a tuple)                           |
| FloatValue                | ``{"$float": "f64:0x8000000000000000"}``                 |
| real (Fraction, +-inf)    | ``{"$real": "1/3"}``, ``{"$real": "inf"}``               |
| bytes                     | ``{"$bytes": "00ff"}``                                   |
| some(x)                   | ``{"$some": x}``                                         |
| QError (qerr)             | ``{"$qerr": [steps, nans]}``                             |
| MapValue                  | ``{"$map": [[k, v], ...]}``                              |
| RecordValue               | ``{"$record": "R", "fields": [["f", v], ...]}``          |
| GeneratedModel            | ``{"$model": "M", "targs": ["i64"], "fields": {...}}``   |
| DEFAULT (omit argument)   | ``{"$default": true}``                                   |
| plain dict                | ``{"$dict": [[k, v], ...]}``                             |
"""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import re
import tempfile
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from fractions import Fraction
from functools import cache
from pathlib import Path
from typing import Any

from spectest import types, values
from spectest.types import (
    FLOAT_FORMATS,
    BoolT,
    BytesT,
    EnumT,
    FixedIntT,
    FloatT,
    IntT,
    ListT,
    LiteralT,
    MapT,
    ModelT,
    OptionT,
    RealT,
    RecordT,
    StringT,
    TupleT,
    Type,
    UnitT,
    scalar_type,
)
from spectest.values import (
    NEG_INF,
    POS_INF,
    FloatValue,
    Handle,
    MapValue,
    RecordValue,
    Some,
    is_infinity,
)

JSON = Any
FORMAT_VERSION = 1
MAX_ENTRIES = 50


class DecodeError(ValueError):
    """A JSON document is not an encoding of a spec value."""


@cache
def generate_module() -> Any:
    try:
        return importlib.import_module("spectest.generate")
    except ModuleNotFoundError as e:
        if e.name in ("spectest.generate", "spectest"):
            return None
        raise


def qerror_class() -> type | None:
    """spectest.values.QError, the values of ``qerr``, once the contract defines it."""
    return getattr(values, "QError", None)


def qerr_type() -> type | None:
    """spectest.types.QErrT, once the contract defines it."""
    return getattr(types, "QErrT", None)


def is_qerror(v: Any) -> bool:
    cls = qerror_class()
    return cls is not None and isinstance(v, cls)


def is_default(v: Any) -> bool:
    gen = generate_module()
    return gen is not None and v is getattr(gen, "DEFAULT", object())


def is_generated_model(v: Any) -> bool:
    gen = generate_module()
    cls = getattr(gen, "GeneratedModel", None) if gen is not None else None
    if cls is not None:
        return isinstance(v, cls)
    return type(v).__name__ == "GeneratedModel" and hasattr(v, "fields")


def encode_value(
    v: Any,
    t: Type | None = None,
    *,
    canonical: bool = False,
    handle: Callable[[Handle], JSON] | None = None,
) -> JSON:
    """A JSON-safe, exact encoding of a spec value.

    ``canonical`` sorts map entries, so equal maps encode equally whatever their
    order (for digests). Handles cannot be stored: they raise ValueError unless
    ``handle`` encodes them.
    """
    if t is not None:
        _check(v, t, "")
    return _encode(v, canonical, handle)


def _encode(v: Any, canonical: bool, handle: Callable[[Handle], JSON] | None) -> JSON:
    def enc(x: Any) -> JSON:
        return _encode(x, canonical, handle)

    if v is None or isinstance(v, (bool, str)):
        return v
    if isinstance(v, int):
        return int(v)
    if isinstance(v, FloatValue):
        width = 1 + sum(FLOAT_FORMATS[v.fmt])
        return {"$float": f"{v.fmt}:0x{v.bits:0{width // 4}x}"}
    if isinstance(v, Fraction):
        return {"$real": f"{v.numerator}/{v.denominator}"}
    if is_infinity(v):
        return {"$real": "inf" if v.sign > 0 else "-inf"}
    if isinstance(v, (bytes, bytearray, memoryview)):
        return {"$bytes": bytes(v).hex()}
    if isinstance(v, (tuple, list)):
        return [enc(x) for x in v]
    if isinstance(v, Some):
        return {"$some": enc(v.value)}
    if is_qerror(v):
        return {"$qerr": [int(v.steps), int(v.nans)]}
    if isinstance(v, MapValue):
        items = [[enc(k), enc(x)] for k, x in v.items]
        if canonical:
            items.sort(key=_canonical_text)
        return {"$map": items}
    if isinstance(v, RecordValue):
        return {"$record": v.name, "fields": [[k, enc(x)] for k, x in v.fields]}
    if isinstance(v, Handle):
        if handle is None:
            raise ValueError(f"cannot encode the handle {v!r}: handles live in the implementation")
        return handle(v)
    if is_default(v):
        return {"$default": True}
    if is_generated_model(v):
        return {
            "$model": v.model,
            "targs": [str(a) for a in v.targs],
            "fields": {name: enc(x) for name, x in v.fields.items()},
        }
    if isinstance(v, dict):
        items = [[enc(k), enc(x)] for k, x in v.items()]
        if canonical:
            items.sort(key=_canonical_text)
        return {"$dict": items}
    raise ValueError(f"cannot encode {type(v).__name__} {v!r} as a spec value")


def _canonical_text(obj: JSON) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def canonical_json(obj: JSON) -> str:
    """Compact JSON text with sorted keys: equal encodings give equal text."""
    return _canonical_text(obj)


def decode_value(obj: JSON, t: Type | None = None, *, spec: Any = None) -> Any:
    """The spec value of an ``encode_value`` encoding; DecodeError if malformed.

    With ``t``, the value must have that type. Type arguments of a generated
    model come from ``t`` when it is that model's type, else from ``spec``
    (or are built-in scalar names).
    """
    v = _decode(obj, t, spec)
    if t is not None:
        _check(v, t, "")
    return v


def _decode(obj: JSON, t: Type | None, spec: Any) -> Any:
    if obj is None or isinstance(obj, (bool, str)):
        return obj
    if isinstance(obj, int):
        return obj
    if isinstance(obj, list):
        elems = _elem_types(t, len(obj))
        return tuple(_decode(x, et, spec) for x, et in zip(obj, elems))
    if not isinstance(obj, dict) or len(obj) == 0:
        raise DecodeError(f"not a spec value encoding: {obj!r}")
    if "$float" in obj:
        return _decode_float(obj["$float"])
    if "$real" in obj:
        text = obj["$real"]
        if text == "inf":
            return POS_INF
        if text == "-inf":
            return NEG_INF
        return Fraction(_str(text, "$real"))
    if "$bytes" in obj:
        return bytes.fromhex(_str(obj["$bytes"], "$bytes"))
    if "$qerr" in obj:
        steps, nans = _expect(obj["$qerr"], list, "$qerr")
        cls = qerror_class()
        if cls is None:
            raise DecodeError("decoding a qerr needs spectest.values.QError")
        return cls(_expect(steps, int, "$qerr steps"), _expect(nans, int, "$qerr nans"))
    if "$some" in obj:
        inner = t.elem if isinstance(t, OptionT) else None
        return Some(_decode(obj["$some"], inner, spec))
    if "$map" in obj:
        kt, vt = (t.key, t.value) if isinstance(t, MapT) else (None, None)
        return MapValue(
            tuple((_decode(k, kt, spec), _decode(x, vt, spec)) for k, x in _pairs(obj["$map"]))
        )
    if "$record" in obj:
        ftypes = dict(t.fields) if isinstance(t, RecordT) else {}
        return RecordValue(
            _str(obj["$record"], "$record"),
            tuple(
                (_str(k, "field"), _decode(x, ftypes.get(k), spec))
                for k, x in _pairs(obj.get("fields", []))
            ),
        )
    if "$default" in obj:
        gen = generate_module()
        if gen is None or not hasattr(gen, "DEFAULT"):
            raise DecodeError("decoding DEFAULT needs spectest.generate")
        return gen.DEFAULT
    if "$model" in obj:
        return _decode_model(obj, t, spec)
    if "$dict" in obj:
        return {_decode(k, None, spec): _decode(x, None, spec) for k, x in _pairs(obj["$dict"])}
    raise DecodeError(f"not a spec value encoding: {obj!r}")


def _expect(x: Any, kind: type, what: str) -> Any:
    if isinstance(x, kind):
        return x
    raise DecodeError(f"{what}: expected {kind.__name__}, got {x!r}")


def _str(x: Any, what: str) -> str:
    return _expect(x, str, what)


def _pairs(x: Any) -> list[tuple[Any, Any]]:
    if not isinstance(x, list) or not all(isinstance(p, list) and len(p) == 2 for p in x):
        raise DecodeError(f"expected a list of pairs, got {x!r}")
    return [(p[0], p[1]) for p in x]


def _elem_types(t: Type | None, n: int) -> list[Type | None]:
    if isinstance(t, ListT):
        return [t.elem] * n
    if isinstance(t, TupleT) and len(t.elems) == n:
        return list(t.elems)
    return [None] * n


_FLOAT_TEXT = re.compile(r"^(f16|bf16|f32|f64):0x([0-9a-fA-F]+)$")


def _decode_float(text: Any) -> FloatValue:
    m = _FLOAT_TEXT.match(_str(text, "$float"))
    if m is None:
        raise DecodeError(f"$float: expected '<format>:0x<bits>', got {text!r}")
    return FloatValue(m.group(1), int(m.group(2), 16))


def _decode_model(obj: dict[str, Any], t: Type | None, spec: Any) -> Any:
    gen = generate_module()
    cls = getattr(gen, "GeneratedModel", None) if gen is not None else None
    if cls is None:
        raise DecodeError("decoding a generated model needs spectest.generate")
    name = _str(obj["$model"], "$model")
    texts = _expect(obj.get("targs", []), list, "$model targs")
    targs: list[Type] = []
    for i, text in enumerate(texts):
        if isinstance(t, ModelT) and t.name == name and len(t.args) == len(texts):
            if str(t.args[i]) != text:
                raise DecodeError(f"$model {name}: type argument {text} is not {t.args[i]}")
            targs.append(t.args[i])
        elif spec is not None:
            targs.append(spec.resolve_type(_str(text, "targs")))
        elif (st := scalar_type(_str(text, "targs"))) is not None:
            targs.append(st)
        else:
            raise DecodeError(
                f"$model {name}: cannot resolve type argument {text!r} without a spec"
            )
    fields = _expect(obj.get("fields", {}), dict, "$model fields")
    return cls(name, tuple(targs), {k: _decode(x, None, spec) for k, x in fields.items()})


def _check(v: Any, t: Type, path: str) -> None:
    """Raise ValueError when v is not a value of type t (models and DEFAULT are accepted)."""

    def bad() -> ValueError:
        where = f" at {path}" if path else ""
        return ValueError(f"{v!r} is not a value of type {t}{where}")

    if is_default(v):
        return
    if isinstance(t, BoolT):
        if not isinstance(v, bool):
            raise bad()
    elif isinstance(t, (IntT, FixedIntT)):
        if isinstance(v, bool) or not isinstance(v, int):
            raise bad()
        if isinstance(t, FixedIntT) and not t.min <= v <= t.max:
            raise bad()
    elif isinstance(t, FloatT):
        if not (isinstance(v, FloatValue) and v.fmt == t.fmt):
            raise bad()
    elif isinstance(t, RealT):
        if not (isinstance(v, Fraction) or is_infinity(v)):
            raise bad()
    elif (qt := qerr_type()) is not None and isinstance(t, qt):
        if not is_qerror(v):
            raise bad()
    elif isinstance(t, StringT):
        if not isinstance(v, str):
            raise bad()
    elif isinstance(t, BytesT):
        if not isinstance(v, bytes):
            raise bad()
    elif isinstance(t, (LiteralT, EnumT)):
        members = t.values if isinstance(t, LiteralT) else t.members
        if not (isinstance(v, str) and v in members):
            raise bad()
    elif isinstance(t, UnitT):
        if v is not None:
            raise bad()
    elif isinstance(t, OptionT):
        if v is not None:
            if not isinstance(v, Some):
                raise bad()
            _check(v.value, t.elem, f"{path}.some")
    elif isinstance(t, ListT):
        if not isinstance(v, (tuple, list)):
            raise bad()
        for i, x in enumerate(v):
            _check(x, t.elem, f"{path}[{i}]")
    elif isinstance(t, TupleT):
        if not (isinstance(v, (tuple, list)) and len(v) == len(t.elems)):
            raise bad()
        for i, (x, et) in enumerate(zip(v, t.elems)):
            _check(x, et, f"{path}.{i}")
    elif isinstance(t, MapT):
        if not isinstance(v, MapValue):
            raise bad()
        for k, x in v.items:
            _check(k, t.key, f"{path}[key]")
            _check(x, t.value, f"{path}[{k!r}]")
    elif isinstance(t, RecordT):
        if not (isinstance(v, RecordValue) and v.name == t.name):
            raise bad()
        if [k for k, _ in v.fields] != [k for k, _ in t.fields]:
            raise bad()
        for (k, x), (_, ft) in zip(v.fields, t.fields):
            _check(x, ft, f"{path}.{k}")
    elif isinstance(t, ModelT) and (
        not (isinstance(v, Handle) or is_generated_model(v)) or v.model != t.name
    ):
        raise bad()


# ---------------------------------------------------------------------------
# The counterexample store


def _slug(item_id: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", item_id).strip("._")[:80] or "item"
    return f"{safe}-{hashlib.sha256(item_id.encode()).hexdigest()[:12]}"


@contextmanager
def _locked(directory: Path) -> Iterator[None]:
    """An exclusive lock on ``directory`` across processes (``fcntl.flock`` on its ``.lock``
    file); without fcntl, no lock."""
    try:
        import fcntl
    except ImportError:  # pragma: no cover - not POSIX
        yield
        return
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / ".lock", "a+b") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


class CounterexampleStore:
    """Failing inputs per (spec hash, item ID), replayed first on the next run.

    One JSON file per item under ``<root>/counterexamples/<hash prefix>/``.
    The newest example comes first; saving an existing example moves it to the
    front, and at most ``max_entries`` are kept. Processes may share a store (pytest-xdist
    workers, concurrent runs): a file is replaced in one step (written to a temporary
    file, then renamed), so a reader sees it whole, and a save holds a lock on its
    directory while it reads and rewrites the file, so no save is lost.
    """

    def __init__(self, root: str | os.PathLike[str] = ".spectest", max_entries: int = MAX_ENTRIES):
        self.root = Path(root)
        self.max_entries = max_entries

    def __repr__(self) -> str:
        return f"CounterexampleStore({str(self.root)!r})"

    def path(self, spec_hash: str, item_id: str) -> Path:
        return self.root / "counterexamples" / spec_hash[:16] / f"{_slug(item_id)}.json"

    def _read(self, spec_hash: str, item_id: str) -> list[dict[str, Any]]:
        p = self.path(spec_hash, item_id)
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        if (
            not isinstance(data, dict)
            or data.get("spec_hash") != spec_hash
            or data.get("item_id") != item_id
            or not isinstance(data.get("examples"), list)
        ):
            return []
        return [e for e in data["examples"] if isinstance(e, dict) and "inputs" in e]

    def _write(self, spec_hash: str, item_id: str, entries: list[dict[str, Any]]) -> None:
        p = self.path(spec_hash, item_id)
        p.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "format": FORMAT_VERSION,
            "spec_hash": spec_hash,
            "item_id": item_id,
            "examples": entries,
        }
        fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".tmp-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=1)
                f.write("\n")
            os.replace(tmp, p)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise

    def load(
        self,
        spec_hash: str,
        item_id: str,
        types: Mapping[str, Type] | None = None,
        *,
        spec: Any = None,
    ) -> list[dict[str, Any]]:
        """Stored inputs, newest first, decoded to spec values.

        Entries that no longer decode (or do not match ``types``) are dropped.
        """
        out: list[dict[str, Any]] = []
        for entry in self._read(spec_hash, item_id):
            inputs = entry["inputs"]
            if not isinstance(inputs, dict):
                continue
            try:
                out.append(
                    {
                        name: decode_value(x, (types or {}).get(name), spec=spec)
                        for name, x in inputs.items()
                    }
                )
            except (ValueError, KeyError, TypeError, ArithmeticError):
                continue
        return out

    def save(
        self,
        spec_hash: str,
        item_id: str,
        inputs: Mapping[str, Any],
        types: Mapping[str, Type] | None = None,
    ) -> bool:
        """Store failing inputs (spec values by parameter name); False if already stored."""
        encoded = {name: encode_value(x, (types or {}).get(name)) for name, x in inputs.items()}
        key = canonical_json(encoded)
        with _locked(self.path(spec_hash, item_id).parent):
            entries = self._read(spec_hash, item_id)
            kept = [e for e in entries if canonical_json(e["inputs"]) != key]
            new = len(kept) == len(entries)
            if not new and entries and canonical_json(entries[0]["inputs"]) == key:
                return False
            self._write(spec_hash, item_id, [{"inputs": encoded}, *kept][: self.max_entries])
        return new

    def clear(self, spec_hash: str | None = None, item_id: str | None = None) -> None:
        """Remove one item's file, one spec's files, or everything."""
        if spec_hash is not None and item_id is not None:
            self.path(spec_hash, item_id).unlink(missing_ok=True)
            return
        base = self.root / "counterexamples"
        if spec_hash is not None:
            base = base / spec_hash[:16]
        if base.is_dir():
            for f in sorted(base.rglob("*.json")):
                f.unlink(missing_ok=True)


__all__ = [
    "FORMAT_VERSION",
    "MAX_ENTRIES",
    "CounterexampleStore",
    "DecodeError",
    "canonical_json",
    "decode_value",
    "encode_value",
    "generate_module",
    "is_default",
    "is_generated_model",
    "is_qerror",
    "qerr_type",
    "qerror_class",
]
