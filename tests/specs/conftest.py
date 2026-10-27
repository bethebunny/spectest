"""Fixtures of the v2 plugin tests: a fake host, and scratch projects that use it."""

from __future__ import annotations

import sys
from collections.abc import Iterator

import pytest
from fake_spec_host import FakeHost

import spectest
import spectest.driver
import spectest.specs


@pytest.fixture
def fake_host() -> Iterator[FakeHost]:
    """The fake installed as ``spectest._host`` for the test."""
    host = FakeHost()
    saved = sys.modules.get("spectest._host")
    sys.modules["spectest._host"] = host  # type: ignore[assignment]
    had_attr = hasattr(spectest, "_host")
    old_attr = getattr(spectest, "_host", None)
    spectest._host = host  # type: ignore[attr-defined]
    try:
        yield host
    finally:
        if saved is None:
            sys.modules.pop("spectest._host", None)
        else:
            sys.modules["spectest._host"] = saved
        if had_attr:
            spectest._host = old_attr  # type: ignore[attr-defined]
        else:
            del spectest._host


@pytest.fixture
def project(pytester: pytest.Pytester, fake_host: FakeHost) -> pytest.Pytester:
    """A scratch project with the specs ``demo`` and ``generic`` (their text is not read)."""
    pytester.makefile(".spec", demo="spec demo\n", generic="spec generic\n")
    pytester.makefile(".spec", broken="spec broken\nBROKEN\n")
    return pytester
