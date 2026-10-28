"""Helpers over the C API: owned references, Python errors as Mojo errors, and the
cache of the wire classes and names the conversions use."""

from std.ffi import _Global
from std.python._cpython import PyObjectPtr

from .capi import (
    Py_DecRef,
    PyErr_Clear,
    PyErr_Fetch,
    PyErr_NormalizeException,
    PyImport_ImportModule,
    PyList_New,
    PyList_SetItem,
    PyLong_FromLongLong,
    PyLong_FromUnsignedLongLong,
    PyObject_GetAttr,
    PyObject_GetAttrString,
    PyObject_Str,
    PyObject_Vectorcall,
    PyObject_VectorcallMethod,
    PyTuple_New,
    PyTuple_SetItem,
    PyType_GetQualName,
    PyUnicode_AsUTF8AndSize,
    PyUnicode_FromStringAndSize,
    PyUnicode_InternFromString,
    object_symbol,
)


@fieldwise_init
struct Owned(Movable):
    """One reference, dropped when this goes away. Null is allowed."""

    var ptr: PyObjectPtr

    def __deinit__(deinit self):
        Py_DecRef(self.ptr)

    def take(deinit self) -> PyObjectPtr:
        return self.ptr


def span_at(address: Int, size: Int) -> Span[UInt8, MutAnyOrigin]:
    return Span[UInt8, MutAnyOrigin](
        unsafe_ptr=Pointer[UInt8, MutAnyOrigin](unsafe_from_address=address),
        length=size,
    )


def string_of(o: PyObjectPtr) -> String:
    """The text of a str (embedded NULs included), or "?" if it can't be read."""
    var size = 0
    var data = PyUnicode_AsUTF8AndSize(o, size)
    if data == 0:
        PyErr_Clear()
        return "?"
    return String(unsafe_from_utf8=span_at(data, size))


def string_of(o: Owned) -> String:
    return string_of(o.ptr)


def qualname(type: PyObjectPtr) -> Optional[String]:
    var name = Owned(PyType_GetQualName(type))
    return string_of(name) if name.ptr else None


def python_error() -> Error:
    """Takes Python's current exception and describes it as `Type: message`."""
    var kind = Owned(PyObjectPtr())
    var value = Owned(PyObjectPtr())
    var trace = Owned(PyObjectPtr())
    PyErr_Fetch(kind.ptr, value.ptr, trace.ptr)
    if not kind.ptr:
        return Error("RuntimeError: a C API call failed without an exception")
    PyErr_NormalizeException(kind.ptr, value.ptr, trace.ptr)
    var name = qualname(kind.ptr).or_else("exception")
    var message = String()
    if value.ptr:
        var text = Owned(PyObject_Str(value.ptr))
        if text.ptr:
            message = string_of(text)
        else:
            PyErr_Clear()
    return Error(t"{name}: {message}")


def checked(o: PyObjectPtr) raises -> PyObjectPtr:
    """`o`, or the Python error that made it null."""
    if not o:
        raise python_error()
    return o


def attr(o: PyObjectPtr, name: PyObjectPtr) raises -> Owned:
    return Owned(checked(PyObject_GetAttr(o, name)))


def new_string(text: String) raises -> Owned:
    return Owned(checked(PyUnicode_FromStringAndSize(text)))


def new_int(value: Int) raises -> Owned:
    return Owned(checked(PyLong_FromLongLong(Int64(value))))


def new_u64(value: UInt64) raises -> Owned:
    return Owned(checked(PyLong_FromUnsignedLongLong(value)))


def new_list(var items: List[Owned]) raises -> Owned:
    var list = Owned(checked(PyList_New(len(items))))
    for i in reversed(range(len(items))):
        _ = PyList_SetItem(list.ptr, i, items.pop().take())
    return list^


def new_tuple(var items: List[Owned]) raises -> Owned:
    var tuple = Owned(checked(PyTuple_New(len(items))))
    for i in reversed(range(len(items))):
        _ = PyTuple_SetItem(tuple.ptr, i, items.pop().take())
    return tuple^


def call(callable: PyObjectPtr, args: List[Owned]) raises -> Owned:
    """`callable(*args)`."""
    var vector = [args[i].ptr for i in range(len(args))]
    return Owned(checked(PyObject_Vectorcall(callable, vector)))


def call_method(
    receiver: PyObjectPtr, name: PyObjectPtr, args: List[Owned]
) raises -> Owned:
    """`receiver.name(*args)`."""
    var vector: List[PyObjectPtr] = [receiver]
    vector.extend([args[i].ptr for i in range(len(args))])
    return Owned(checked(PyObject_VectorcallMethod(name, vector)))


def _interned(name: StringLiteral) raises -> PyObjectPtr:
    return checked(PyUnicode_InternFromString(name.as_c_string_span()))


def _class(module: Owned, name: StringLiteral) raises -> PyObjectPtr:
    return checked(PyObject_GetAttrString(module.ptr, name.as_c_string_span()))


struct Classes(Movable):
    """The classes of `spectest.driver.wire`."""

    var float: PyObjectPtr
    var map: PyObjectPtr
    var record: PyObjectPtr
    var enum: PyObjectPtr
    var handle: PyObjectPtr
    var error: PyObjectPtr
    var converted: PyObjectPtr

    def __init__(out self) raises:
        var module = Owned(
            checked(PyImport_ImportModule("spectest.driver.wire".as_c_string_span()))
        )
        self.float = _class(module, "Float")
        self.map = _class(module, "Map")
        self.record = _class(module, "Record")
        self.enum = _class(module, "Enum")
        self.handle = _class(module, "Handle")
        self.error = _class(module, "Error")
        self.converted = _class(module, "Converted")


struct Names(Movable):
    """The attributes of wire objects and the methods of the driver, as interned strs."""

    var fmt: PyObjectPtr
    var bits: PyObjectPtr
    var pairs: PyObjectPtr
    var type: PyObjectPtr
    var fields: PyObjectPtr
    var member: PyObjectPtr
    var id: PyObjectPtr
    var cls: PyObjectPtr
    var bases: PyObjectPtr
    var message: PyObjectPtr
    var value: PyObjectPtr
    var resolve: PyObjectPtr
    var call: PyObjectPtr
    var get: PyObjectPtr
    var observe: PyObjectPtr
    var release: PyObjectPtr

    def __init__(out self) raises:
        self.fmt = _interned("fmt")
        self.bits = _interned("bits")
        self.pairs = _interned("pairs")
        self.type = _interned("type")
        self.fields = _interned("fields")
        self.member = _interned("member")
        self.id = _interned("id")
        self.cls = _interned("cls")
        self.bases = _interned("bases")
        self.message = _interned("message")
        self.value = _interned("value")
        self.resolve = _interned("resolve")
        self.call = _interned("call")
        self.get = _interned("get")
        self.observe = _interned("observe")
        self.release = _interned("release")


struct Wire(Movable):
    """The wire classes, the names and the singletons, looked up once. They live as long
    as the process."""

    var classes: Classes
    var names: Names
    var none: PyObjectPtr
    var true: PyObjectPtr
    var false: PyObjectPtr

    def __init__(out self) raises:
        self.classes = Classes()
        self.names = Names()
        self.none = object_symbol("_Py_NoneStruct")
        self.true = object_symbol("_Py_TrueStruct")
        self.false = object_symbol("_Py_FalseStruct")


def _unloaded() -> Optional[Wire]:
    return None


comptime _WIRE = _Global["spectest_bridge_wire", _unloaded]


def wire() raises -> Pointer[Wire, MutUntrackedOrigin]:
    """The process's wire cache, loaded on first use."""
    var slot = _WIRE.get_or_create_ptr()
    if slot[] is None:
        slot[] = Wire()
    return Pointer(to=slot[].unsafe_value()).unsafe_origin_cast[MutUntrackedOrigin]()
