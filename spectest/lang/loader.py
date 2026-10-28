"""Loading spec files: parse, resolve ``use``, check, and check partitions."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

from spectest import ast
from spectest.lang.checker import check
from spectest.lang.errors import SpecCheckError
from spectest.lang.parser import parse
from spectest.lang.spec import Diagnostic, Spec


def _partition_checker() -> Callable[[Spec], list[Any]] | None:
    try:
        from spectest import sets
    except ModuleNotFoundError as e:
        if e.name in ("spectest.sets", "spectest"):
            return None
        raise
    except ImportError:
        return None
    return getattr(sets, "check_partitions", None)


def check_partitions(spec: Spec) -> None:
    """Run the set checks (disjoint, covering) when spectest.sets is available.

    Errors raise SpecCheckError; warnings are kept in ``spec.warnings``.
    """
    checker = _partition_checker()
    if checker is None:
        return
    diags = [Diagnostic.coerce(d, spec.path, spec.source) for d in checker(spec)]
    spec.warnings.extend(d for d in diags if d.severity != "error")
    errors = [d for d in diags if d.severity == "error"]
    if errors:
        raise SpecCheckError(errors)


class _Loader:
    def __init__(self) -> None:
        self.cache: dict[Path, Spec] = {}
        self.active: list[Path] = []

    def load_file(self, path: Path, display: str) -> Spec:
        key = path.resolve()
        if key in self.cache:
            return self.cache[key]
        source = path.read_text(encoding="utf-8")
        spec = self.load_source(source, display, key.parent, key)
        self.cache[key] = spec
        return spec

    def load_source(self, source: str, display: str, base: Path, key: Path | None) -> Spec:
        file = parse(source, display)
        if key is not None:
            self.active.append(key)
        try:
            uses = [self.use(d, file, base) for d in file.decls if isinstance(d, ast.UseDecl)]
        finally:
            if key is not None:
                self.active.pop()
        spec = check(file, uses)
        check_partitions(spec)
        return spec

    def use(self, d: ast.UseDecl, file: ast.SpecFile, base: Path) -> Spec:
        target = (base / d.path).resolve()
        if target in self.active:
            raise SpecCheckError.at(
                file.path, file.source, d.span, f"use {d.path!r} makes a cycle of used files"
            )
        if not target.is_file():
            raise SpecCheckError.at(
                file.path, file.source, d.span, f"cannot find {d.path!r} (looked for {target})"
            )
        display = str(Path(file.path).parent / d.path) if file.path != "<string>" else d.path
        return self.load_file(target, display)


def load(path: str | Path) -> Spec:
    """Load and check a spec file and the files it uses.

    Raises SpecSyntaxError or SpecCheckError (with every diagnostic) on failure.
    """
    p = Path(path)
    return _Loader().load_file(p, str(path))


def load_source(source: str, path: str = "<string>", base: str | Path | None = None) -> Spec:
    """Load a spec from source text; ``use`` paths resolve against base (default: path's folder)."""
    if base is None:
        base = Path(path).parent if path != "<string>" else Path.cwd()
    return _Loader().load_source(source, path, Path(base), None)


__all__ = ["check_partitions", "load", "load_source"]
