"""Builds the extension module once per session; the tests drive it with the real
driver."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).parent))


@pytest.fixture(scope="session", autouse=True)
def host_module() -> object:
    import build_host

    build_host.build()
    from spectest import _host

    return _host
