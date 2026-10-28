"""The Python driver of spectest v2: resolves names, calls the code under test, and
converts between its objects and wire values (docs/v2/protocol.md)."""

from spectest.driver.convert import marshal
from spectest.driver.driver import Driver

__all__ = ["Driver", "marshal"]
