"""The host's side of the driver protocol: calls the driver object's methods and
converts arguments and results (docs/v2/protocol.md)."""

from std.python._cpython import PyObjectPtr

from wire.value import ERROR, INT, Value

from .capi import Py_NewRef, PyDict_New, PyList_New, PyList_SetItem, PyObject_VectorcallMethod
from .convert import from_python, to_python
from .pyutil import Owned, checked, new_int, new_string, new_u64, python_error, wire


struct DriverClient(Movable):
    """Wraps the driver object. A wire `Error` that comes back is an ERROR Value; a
    Python exception that escapes a driver method raises a Mojo error naming its type
    and message."""

    var driver: Owned

    def __init__(out self, driver: PyObjectPtr):
        self.driver = Owned(Py_NewRef(driver))

    def _invoke(
        self, method: PyObjectPtr, label: StaticString, args: List[Owned]
    ) raises -> Owned:
        """Calls `driver.method(*args)`."""
        var receiver_and_args: List[PyObjectPtr] = [self.driver.ptr]
        for i in range(len(args)):
            receiver_and_args.append(args[i].ptr)
        var result = PyObject_VectorcallMethod(
            method, Int(receiver_and_args.unsafe_ptr()), len(receiver_and_args)
        )
        _ = len(receiver_and_args)  # keeps the vector alive through the call
        if not result:
            raise Error("driver.", label, " raised ", String(python_error()))
        return Owned(result)

    def resolve(self, name: String) raises -> Int:
        """The target id of a qualified name. Raises with the message of the `Error`
        the driver returns for a name that doesn't resolve."""
        var reply = self._invoke(wire()[].m_resolve, "resolve", [new_string(name)])
        var result = from_python(reply.ptr)
        if result.is_(ERROR):
            raise Error(result.text())
        var id = result.small_int()
        if not result.is_(INT) or id is None:
            raise Error("driver.resolve returned ", result)
        return id.value()

    def call(self, target: Int, args: List[Value]) raises -> Value:
        """Calls a target. An exception the call raised comes back as an ERROR Value."""
        var send: List[Owned] = [new_int(target), _list_of(args), Owned(checked(PyDict_New()))]
        return from_python(self._invoke(wire()[].m_call, "call", send).ptr)

    def get(self, target: Int) raises -> Value:
        return from_python(self._invoke(wire()[].m_get, "get", [new_int(target)]).ptr)

    def observe(
        self, obj: Value, name: String, args: Optional[List[Value]]
    ) raises -> Value:
        """Reads attribute `name` of `obj`, calling it with `args` when given."""
        var arguments = _list_of(args.value()) if args is not None else Owned(Py_NewRef(wire()[].none))
        var send: List[Owned] = [Owned(to_python(obj)), new_string(name), arguments^]
        return from_python(self._invoke(wire()[].m_observe, "observe", send).ptr)

    def release(self, ids: List[UInt64]) raises:
        var list = Owned(checked(PyList_New(len(ids))))
        for i, id in enumerate(ids):
            _ = PyList_SetItem(list.ptr, i, new_u64(id).take())
        _ = self._invoke(wire()[].m_release, "release", [list^])


def _list_of(values: List[Value]) raises -> Owned:
    var list = Owned(checked(PyList_New(len(values))))
    for i in range(len(values)):
        _ = PyList_SetItem(list.ptr, i, to_python(values[i]))
    return list^
