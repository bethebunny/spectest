"""A fake ``spectest._host`` with the API of docs/v2/host-api.md and canned results.

``FakeHost`` is installed as ``spectest._host`` by the ``fake_host`` fixture
(tests/specs/conftest.py). A spec file's items come from ``FakeHost.specs`` by the
file's stem; a run judges the clauses of the declaration, each passing unless
``FakeHost.verdicts`` has an entry for its clause id. A spec file whose text contains
``BROKEN`` fails to load, as a spec with errors does.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any


class FakeSpecError(ValueError):
    """What the real host raises for a spec that does not load."""


def item(
    decl: str,
    name: str,
    *,
    kind: str = "ensures",
    tparams: tuple[str, ...] = (),
    line: int = 1,
) -> dict[str, Any]:
    clause_id = f"{decl}#{name}" if kind in ("type", "raises") else f"{decl}.{name}"
    return {
        "decl": decl,
        "clause_id": clause_id,
        "kind": kind,
        "text": f"{kind} {name}: ...",
        "line": line,
        "tparams": list(tparams),
    }


COUNTEREXAMPLE = {
    "inputs": {"x": "0.5"},
    "observation": "result = 0.8775825618903728",
    "partitions": {"x": "moderate"},
    "explanation": [["qe(result, cr.cos(x))", "2"]],
    "seed": 1234,
    "reproduce": "uv run pytest ...",
}

VERDICTS: dict[str, dict[str, Any]] = {
    "pass": {"counts": {"pass": 10}},
    "fail": {"counts": {"pass": 9, "fail": 1}, "counterexample": COUNTEREXAMPLE, "failing_inputs": 1},
    "error": {
        "counts": {"pass": 3, "spec_error": 1},
        "spec_errors": ["math.cos.accurate: cr.cos is undefined"],
    },
    "skip": {"counts": {"skip": 5}, "skips": {"requires": 5}},
    "inconclusive": {"counts": {"inconclusive": 2}},
}

DEFAULT_SPECS: dict[str, list[dict[str, Any]]] = {
    "demo": [
        item("math.cos", "accurate", line=3),
        item("math.cos", "type", kind="type", line=3),
        item("math.sqrt", "exact", line=9),
    ],
    "generic": [
        item("sort", "ordered", tparams=("T",), line=2),
        item("sort", "stable", tparams=("T",), line=2),
        item("first", "head", line=8),
    ],
}


class FakeHost:
    def __init__(self) -> None:
        self.specs = {k: list(v) for k, v in DEFAULT_SPECS.items()}
        self.verdicts: dict[str, str] = {}
        self.calls: list[tuple[Any, ...]] = []
        self.drivers: list[Any] = []
        self._loaded: dict[int, str] = {}
        self._next = 1

    # -- the host API -------------------------------------------------------

    def load(self, path: str, driver: Any) -> int:
        self.calls.append(("load", Path(path).name))
        text = Path(path).read_text(encoding="utf-8")
        if "BROKEN" in text:
            raise FakeSpecError(f"{path}:2:5: unknown name 'frobnicate'\n{path}:7:1: bad clause")
        handle = self._next
        self._next += 1
        self._loaded[handle] = Path(path).stem
        self.drivers.append(driver)
        return handle

    def items(self, spec: int) -> list[dict[str, Any]]:
        return [dict(i) for i in self.specs[self._loaded[spec]]]

    def run(self, spec: int, decl: str, options: dict[str, Any]) -> dict[str, Any]:
        self.calls.append(("run", decl, dict(options)))
        log = os.environ.get("FAKE_HOST_LOG")
        if log:  # runs in xdist workers are seen through a file
            with open(log, "a", encoding="utf-8") as f:
                f.write(f"{decl} {sorted(options.get('instantiation', {}).items())}\n")
        clauses = []
        for it in self.specs[self._loaded[spec]]:
            if it["decl"] != decl:
                continue
            verdict = VERDICTS[self.verdicts.get(it["clause_id"], "pass")]
            clauses.append(
                {
                    "item_id": "",
                    "clause_id": it["clause_id"],
                    "clause_text": it["text"],
                    "kind": it["kind"],
                    "decl": decl,
                    "instantiation": dict(options.get("instantiation", {})),
                    "mode": "hypothesis",
                    "duration": 0.001,
                    **verdict,
                }
            )
        return {
            "decl": decl,
            "mode": "search",
            "examples": 10,
            "invalid": 0,
            "seconds": 0.001,
            "clauses": clauses,
        }

    def unload(self, spec: int) -> None:
        self.calls.append(("unload", spec))
        self._loaded.pop(spec, None)

    # -- for the tests ------------------------------------------------------

    def runs(self) -> list[tuple[str, dict[str, Any]]]:
        """The (declaration, options) of each run, in order."""
        return [(c[1], c[2]) for c in self.calls if c[0] == "run"]
