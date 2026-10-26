"""The host's side of the driver protocol: calls the driver object's methods and
converts arguments and results (docs/v2/protocol.md)."""

from std.python._cpython import PyObjectPtr

from wire.value import ERROR, INT, Value

from .capi import (
    Py_IncRef,
    Py_NewRef,
    PyDict_New,
    PyList_New,
    PyList_SetItem,
    PyLong_FromLongLong,
    PyLong_FromUnsignedLongLong,
    PyObject_VectorcallMethod,
    PyUnicode_FromStringAndSize,
)
from .convert import from_python, to_python
from .pyutil import Owned, checked, python_error, wire


struct DriverClient(Movable):
    """Wraps the driver object. A wire `Error` that comes back is an ERROR Value; a
    Python exception that escapes a driver method raises a Mojo error naming its type
    and message."""

    var driver: PyObjectPtr
    """Owned: one reference, dropped with the client."""

    def __init__(out self, driver: PyObjectPtr):
        Py_IncRef(driver)
        self.driver = driver

    def __deinit__(deinit self):
        from .capi import Py_DecRef

        Py_DecRef(self.driver)

    def _invoke(
        self, method: PyObjectPtr, label: StaticString, args: List[PyObjectPtr]
    ) raises -> Owned:
        """Calls `driver.method(*args)`; `args` are borrowed."""
        var all = List[PyObjectPtr](capacity=len(args) + 1)
        all.append(self.driver)
        for a in args:
            all.append(a)
        var result = PyObject_VectorcallMethod(method, Int(all.unsafe_ptr()), len(all))
        _ = len(all)  # keeps the vector alive through the call
        if not result:
            var e = python_error()
            raise Error("driver.", label, " raised ", String(e))
        return Owned(result)

    def resolve(self, name: String) raises -> Int:
        """The target id of a qualified name. Raises with the message of the `Error`
        the driver returns for a name that doesn't resolve."""
        var w = wire()
        var arg = Owned(checked(PyUnicode_FromStringAndSize(name)))
        var args: List[PyObjectPtr] = [arg.ptr]
        var result = from_python(self._invoke(w[].m_resolve, "resolve", args).ptr)
        if result.is_(ERROR):
            raise Error(result.text())
        var id = result.small_int()
        if not result.is_(INT) or not id:
            raise Error("driver.resolve returned " + String(result))
        return id.value()

    def call(self, target: Int, args: List[Value]) raises -> Value:
        """Calls a target. An exception the call raised comes back as an ERROR Value."""
        var w = wire()
        var id = Owned(checked(PyLong_FromLongLong(Int64(target))))
        var list = _list_of(args)
        var kwargs = Owned(checked(PyDict_New()))
        var send: List[PyObjectPtr] = [id.ptr, list.ptr, kwargs.ptr]
        return from_python(self._invoke(w[].m_call, "call", send).ptr)

    def get(self, target: Int) raises -> Value:
        var w = wire()
        var id = Owned(checked(PyLong_FromLongLong(Int64(target))))
        var send: List[PyObjectPtr] = [id.ptr]
        return from_python(self._invoke(w[].m_get, "get", send).ptr)

    def observe(
        self, obj: Value, name: String, args: Optional[List[Value]]
    ) raises -> Value:
        """Reads attribute `name` of `obj`, calling it with `args` when given."""
        var w = wire()
        var target = Owned(to_python(obj))
        var attribute = Owned(checked(PyUnicode_FromStringAndSize(name)))
        var arguments = Owned(Py_NewRef(w[].none))
        if args:
            arguments = _list_of(args.value())
        var send: List[PyObjectPtr] = [target.ptr, attribute.ptr, arguments.ptr]
        return from_python(self._invoke(w[].m_observe, "observe", send).ptr)

    def release(self, ids: List[UInt64]) raises:
        var w = wire()
        var list = Owned(checked(PyList_New(len(ids))))
        for i in range(len(ids)):
            var n = PyLong_FromUnsignedLongLong(ids[i])
            if not n:
                raise python_error()
            _ = PyList_SetItem(list.ptr, i, n)
        var send: List[PyObjectPtr] = [list.ptr]
        _ = self._invoke(w[].m_release, "release", send)


def _list_of(values: List[Value]) raises -> Owned:
    var list = Owned(checked(PyList_New(len(values))))
    for i in range(len(values)):
        _ = PyList_SetItem(list.ptr, i, to_python(values[i]))
    return list^
