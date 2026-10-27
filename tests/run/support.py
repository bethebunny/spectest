"""Helpers for the runner's end-to-end tests: write a spec, load it with a real
driver, run declarations and read the results."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from spectest import _host
from spectest.driver import Driver


class Loaded:
    """A spec loaded into the host, with the driver it runs against."""

    def __init__(self, path: Path, driver: Driver | None = None) -> None:
        self.driver = driver or Driver()
        self.handle = _host.load(str(path), self.driver)

    def items(self) -> list[dict[str, Any]]:
        return _host.items(self.handle)

    def run(self, decl: str, **options: Any) -> Result:
        options.setdefault("seed", 1)
        return Result(_host.run(self.handle, decl, options))

    def close(self) -> None:
        _host.unload(self.handle)


class Result:
    def __init__(self, data: dict[str, Any]) -> None:
        self.data = data
        self.clauses = {c["clause_id"]: c for c in data["clauses"]}

    def __getitem__(self, clause_id: str) -> dict[str, Any]:
        return self.clauses[clause_id]

    def counts(self, clause_id: str) -> dict[str, int]:
        return self.clauses[clause_id]["counts"]

    def failed(self) -> list[str]:
        return [i for i, c in self.clauses.items() if c["counts"]["fail"] > 0]

    def spec_errors(self) -> list[str]:
        return [e for c in self.data["clauses"] for e in c["spec_errors"]]

    def passed_all(self) -> bool:
        return not self.failed() and not self.spec_errors()

    def cx(self, clause_id: str) -> dict[str, Any]:
        cx = self.clauses[clause_id]["counterexample"]
        assert cx is not None, f"{clause_id} has no counterexample: {self.clauses[clause_id]}"
        return cx

    def __getattr__(self, name: str) -> Any:
        try:
            return self.data[name]
        except KeyError:
            raise AttributeError(name) from None


def write_spec(tmp_path: Path, text: str, name: str = "t.spec") -> Path:
    path = tmp_path / name
    path.write_text(text)
    return path


def load(tmp_path: Path, text: str, driver: Driver | None = None) -> Loaded:
    return Loaded(write_spec(tmp_path, text), driver)
