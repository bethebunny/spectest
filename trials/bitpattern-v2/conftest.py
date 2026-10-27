"""Converters for classes of bitpattern whose objects the spec reads as plain values."""

import pytest
import spectest

_registered = False


def _register() -> None:
    """Register the converters (once). bitpattern is imported here, at the first run of
    a test, so that collecting the spec does not import it."""
    global _registered
    if _registered:
        return
    _registered = True
    from bitpattern.dlpack import DType

    # codec.dtype() results are read as the member's name: "INT8", "UINT16", ...
    @spectest.marshal(DType)
    def dtype_to_wire(d: DType) -> str:
        return d.name


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_setup(item: pytest.Item) -> None:
    _register()
