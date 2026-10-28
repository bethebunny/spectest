"""spectest: formal specs for Python components, checked by generated tests.

``spectest.load`` reads a spec; ``spectest.conformance`` binds it to
implementations, and the pytest plugin runs every clause. The public names
load lazily, so importing spectest (as the plugin does) stays cheap.
"""

from __future__ import annotations

import importlib
from typing import TYPE_CHECKING, Any

__version__ = "0.0.1"

_EXPORTS = {
    "load": "spectest.runtime.binding",
    "conformance": "spectest.runtime.binding",
    "Conformance": "spectest.runtime.binding",
    "ConformanceError": "spectest.runtime.binding",
    "ModelBinding": "spectest.runtime.binding",
    "InterfaceBinding": "spectest.runtime.binding",
    "Unrepresentable": "spectest.values",
    "marshal": "spectest.driver.convert",
    "check": "spectest.specs",
    "NotAValue": "spectest.values",
}

__all__ = [
    "Conformance",
    "ConformanceError",
    "InterfaceBinding",
    "ModelBinding",
    "NotAValue",
    "Unrepresentable",
    "__version__",
    "check",
    "conformance",
    "load",
    "marshal",
]

if TYPE_CHECKING:
    from spectest.runtime.binding import (
        Conformance,
        ConformanceError,
        InterfaceBinding,
        ModelBinding,
        conformance,
        load,
    )
    from spectest.values import NotAValue, Unrepresentable


def __getattr__(name: str) -> Any:
    module = _EXPORTS.get(name)
    if module is None:
        raise AttributeError(f"module 'spectest' has no attribute {name!r}")
    value = getattr(importlib.import_module(module), name)
    globals()[name] = value
    return value


def __dir__() -> list[str]:
    return sorted({*globals(), *_EXPORTS})
