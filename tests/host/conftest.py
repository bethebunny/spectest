"""Runs the Mojo test files under tests/host as pytest items, one item per file.

A test file is a Mojo program named ``test_*.mojo`` whose ``main`` runs a
``TestSuite``. It is compiled and run with the venv's ``mojo``, with ``host/`` and
the vendored bitpattern core on the include path, so ``from wire.value import
Value`` and ``from arena import Arena`` both work. A compile error or a failing test
fails the item, with mojo's output as the report.

``uv run pytest tests/host/wire`` runs one package's tests. Mojo caches compiled
code, so a file that hasn't changed (nor anything it imports) reruns in about a
second; a cold compile takes several.
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
INCLUDES = [ROOT / "host", ROOT / "host" / "vendor" / "bitpattern"]
# A cold compile of a large test file plus its run, with room to spare.
TIMEOUT = 600


def mojo_command(path: Path) -> list[str]:
    mojo = Path(sys.executable).parent / "mojo"
    includes = [arg for p in INCLUDES for arg in ("-I", str(p))]
    return [str(mojo), "run", *includes, str(path)]


def pytest_collect_file(parent: pytest.Collector, file_path: Path) -> pytest.File | None:
    if file_path.suffix == ".mojo" and file_path.name.startswith("test_"):
        return MojoFile.from_parent(parent, path=file_path)
    return None


class MojoFile(pytest.File):
    def collect(self) -> Iterator[pytest.Item]:
        yield MojoTest.from_parent(self, name=self.path.stem)


class MojoTestFailed(Exception):
    pass


class MojoTest(pytest.Item):
    def runtest(self) -> None:
        proc = subprocess.run(
            mojo_command(self.path),
            capture_output=True,
            text=True,
            check=False,
            timeout=TIMEOUT,
            cwd=ROOT,
        )
        if proc.returncode != 0:
            raise MojoTestFailed(proc.stdout + proc.stderr)

    def repr_failure(self, excinfo: pytest.ExceptionInfo[BaseException]) -> str:
        if isinstance(excinfo.value, MojoTestFailed):
            return str(excinfo.value)
        return super().repr_failure(excinfo)

    def reportinfo(self) -> tuple[Path, int, str]:
        return self.path, 0, f"mojo {self.path.name}"
