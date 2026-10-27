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
    PyLong_FromLongLong,
    PyLong_FromUnsignedLongLong,
    PyObject_GetAttr,
    PyObject_GetAttrString,
    PyObject_Str,
    PyObject_Vectorcall,
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


def python_error() -> Error:
    """Takes Python's current exception and describes it as `Type: message`."""
    var kind = PyObjectPtr()
    var value = PyObjectPtr()
    var trace = PyObjectPtr()
    PyErr_Fetch(kind, value, trace)
    if not kind:
        return Error("RuntimeError: a C API call failed without an exception")
    PyErr_NormalizeException(kind, value, trace)
    # each Owned is destroyed after its last use
    var kind_owner = Owned(kind)
    var value_owner = Owned(value)
    var trace_owner = Owned(trace)
    var qual = Owned(PyType_GetQualName(kind_owner.ptr))
    var name = string_of(qual) if qual.ptr else "exception"
    var message = String()
    if value_owner.ptr:
        var text = Owned(PyObject_Str(value_owner.ptr))
        if text.ptr:
            message = string_of(text)
        else:
            PyErr_Clear()
    return Error(name, ": ", message)


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


def call(callable: PyObjectPtr, args: List[Owned]) raises -> Owned:
    """`callable(*args)`."""
    var pointers: List[PyObjectPtr] = []
    for i in range(len(args)):
        pointers.append(args[i].ptr)
    var result = PyObject_Vectorcall(
        callable, Int(pointers.unsafe_ptr()), len(pointers)
    )
    _ = len(pointers)  # keeps the vector alive through the call
    return Owned(checked(result))


def _interned(name: StringLiteral) raises -> PyObjectPtr:
    return checked(PyUnicode_InternFromString(name.as_c_string_span()))


def _class(module: Owned, name: StringLiteral) raises -> PyObjectPtr:
    return checked(PyObject_GetAttrString(module.ptr, name.as_c_string_span()))


struct Wire(Movable):
    """The wire classes of `spectest.driver.wire`, the singletons and the attribute
    names, looked up once. They live as long as the process."""

    var float_cls: PyObjectPtr
    var map_cls: PyObjectPtr
    var record_cls: PyObjectPtr
    var enum_cls: PyObjectPtr
    var handle_cls: PyObjectPtr
    var error_cls: PyObjectPtr
    var converted_cls: PyObjectPtr
    var none: PyObjectPtr
    var true_: PyObjectPtr
    var false_: PyObjectPtr
    var n_fmt: PyObjectPtr
    var n_bits: PyObjectPtr
    var n_pairs: PyObjectPtr
    var n_type: PyObjectPtr
    var n_fields: PyObjectPtr
    var n_member: PyObjectPtr
    var n_id: PyObjectPtr
    var n_cls: PyObjectPtr
    var n_bases: PyObjectPtr
    var n_message: PyObjectPtr
    var n_value: PyObjectPtr
    var m_resolve: PyObjectPtr
    var m_call: PyObjectPtr
    var m_get: PyObjectPtr
    var m_observe: PyObjectPtr
    var m_release: PyObjectPtr

    def __init__(out self) raises:
        var module = Owned(
            checked(PyImport_ImportModule("spectest.driver.wire".as_c_string_span()))
        )
        self.float_cls = _class(module, "Float")
        self.map_cls = _class(module, "Map")
        self.record_cls = _class(module, "Record")
        self.enum_cls = _class(module, "Enum")
        self.handle_cls = _class(module, "Handle")
        self.error_cls = _class(module, "Error")
        self.converted_cls = _class(module, "Converted")
        self.none = object_symbol("_Py_NoneStruct")
        self.true_ = object_symbol("_Py_TrueStruct")
        self.false_ = object_symbol("_Py_FalseStruct")
        self.n_fmt = _interned("fmt")
        self.n_bits = _interned("bits")
        self.n_pairs = _interned("pairs")
        self.n_type = _interned("type")
        self.n_fields = _interned("fields")
        self.n_member = _interned("member")
        self.n_id = _interned("id")
        self.n_cls = _interned("cls")
        self.n_bases = _interned("bases")
        self.n_message = _interned("message")
        self.n_value = _interned("value")
        self.m_resolve = _interned("resolve")
        self.m_call = _interned("call")
        self.m_get = _interned("get")
        self.m_observe = _interned("observe")
        self.m_release = _interned("release")


def _unloaded() -> Optional[Wire]:
    return None


comptime _WIRE = _Global["spectest_bridge_wire", _unloaded]


def wire() raises -> Pointer[Wire, MutUntrackedOrigin]:
    """The process's wire cache, loaded on first use."""
    var slot = _WIRE.get_or_create_ptr()
    if slot[] is None:
        slot[] = Wire()
    return Pointer(to=slot[].unsafe_value()).unsafe_origin_cast[MutUntrackedOrigin]()
