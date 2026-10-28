"""The host's side of the driver protocol: calls the driver object's methods and
converts arguments and results (docs/v2/protocol.md)."""

from std.python._cpython import PyObjectPtr

from host.driver import Driver
from value.value import Value

from .capi import Py_NewRef, PyDict_New
from .convert import from_python, to_python
from .pyutil import (
    Owned,
    call_method,
    checked,
    new_int,
    new_list,
    new_string,
    new_u64,
    string_of,
    wire,
)


struct DriverClient(Driver, Movable):
    """Wraps the driver object. A wire `Error` that comes back is an ERROR Value; a
    Python exception that escapes a driver method raises a Mojo error naming its type
    and message."""

    var driver: Owned

    def __init__(out self, driver: PyObjectPtr):
        self.driver = Owned(Py_NewRef(driver))

    def _invoke(self, method: PyObjectPtr, args: List[Owned]) raises -> Owned:
        """`driver.method(*args)`, where `method` is an interned name."""
        try:
            return call_method(self.driver.ptr, method, args)
        except e:
            raise Error(t"driver.{string_of(method)} raised {e}")

    def resolve(self, name: String) raises -> Int:
        """The target id of a qualified name. Raises with the message of the `Error`
        the driver returns for a name that doesn't resolve."""
        var result = from_python(self._invoke(wire()[].names.resolve, [new_string(name)]).ptr)
        if result.kind == .Error:
            raise Error(result.text())
        if result.kind == .Int:
            if case .Some(id) = result.small_int():
                return id
        raise Error(t"driver.resolve returned {result}")

    def call(self, target: Int, args: List[Value]) raises -> Value:
        var send: List[Owned] = [new_int(target), _list_of(args), Owned(checked(PyDict_New()))]
        return from_python(self._invoke(wire()[].names.call, send).ptr)

    def get(self, target: Int) raises -> Value:
        return from_python(self._invoke(wire()[].names.get, [new_int(target)]).ptr)

    def observe(
        self, obj: Value, name: String, args: Optional[List[Value]]
    ) raises -> Value:
        var arguments = _list_of(args.value()) if args is not None else Owned(Py_NewRef(wire()[].none))
        var send: List[Owned] = [Owned(to_python(obj)), new_string(name), arguments^]
        return from_python(self._invoke(wire()[].names.observe, send).ptr)

    def release(self, ids: List[UInt64]) raises:
        _ = self._invoke(wire()[].names.release, [new_list([new_u64(id) for id in ids])])


def _list_of(values: List[Value]) raises -> Owned:
    return new_list([Owned(to_python(value)) for value in values])
