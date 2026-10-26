"""Helpers over the C API: owned references, Python errors as Mojo errors, and the
cache of the wire classes and names the conversions use."""

from std.ffi import _Global
from std.python._cpython import PyObjectPtr

from .capi import (
    Py_DecRef,
    Py_IncRef,
    PyBytes_FromStringAndSize,
    PyErr_Clear,
    PyErr_Fetch,
    PyErr_NormalizeException,
    PyImport_ImportModule,
    PyObject_GetAttr,
    PyObject_GetAttrString,
    PyObject_Str,
    PyObject_Vectorcall,
    PyObject_VectorcallMethod,
    PyType_GetQualName,
    PyUnicode_AsUTF8AndSize,
    PyUnicode_FromStringAndSize,
    PyUnicode_InternFromString,
    object_symbol,
    utf8,
)


struct Owned(Movable):
    """One reference, dropped when this goes away. Null is allowed."""

    var ptr: PyObjectPtr

    def __init__(out self, ptr: PyObjectPtr):
        self.ptr = ptr

    def __deinit__(deinit self):
        Py_DecRef(self.ptr)

    def take(deinit self) -> PyObjectPtr:
        """The reference, which is now the caller's."""
        return self.ptr


def string_of(o: PyObjectPtr) -> String:
    """The text of a str, including embedded NULs; "?" if it can't be read."""
    var size = 0
    var data = PyUnicode_AsUTF8AndSize(o, size)
    if data == 0:
        PyErr_Clear()
        return "?"
    var bytes = List[UInt8](capacity=size)
    var src = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=data)
    for i in range(size):
        bytes.append(src[unsafe_offset=i])
    return String(unsafe_from_utf8=Span(bytes))


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
    var name = String("exception")
    var qual = PyType_GetQualName(kind)
    if qual:
        name = string_of(qual)
        Py_DecRef(qual)
    var message = String()
    if value:
        var text = PyObject_Str(value)
        if text:
            message = string_of(text)
            Py_DecRef(text)
        else:
            PyErr_Clear()
    Py_DecRef(kind)
    Py_DecRef(value)
    Py_DecRef(trace)
    return Error(name, ": ", message)


def checked(o: PyObjectPtr) raises -> PyObjectPtr:
    """`o`, or the Python error that made it null."""
    if not o:
        raise python_error()
    return o


def attr(o: PyObjectPtr, name: PyObjectPtr) raises -> Owned:
    return Owned(checked(PyObject_GetAttr(o, name)))


def interned(name: StringLiteral) raises -> PyObjectPtr:
    return checked(PyUnicode_InternFromString(name.as_c_string_span()))


def new_string(text: String) raises -> PyObjectPtr:
    return checked(PyUnicode_FromStringAndSize(text))


def call_stealing(callable: PyObjectPtr, args: List[PyObjectPtr]) raises -> PyObjectPtr:
    """`callable(*args)`, dropping `args` afterwards. Raises the Python error when a
    result or an argument is null."""
    var failed = False
    for a in args:
        if not a:
            failed = True
    var result = PyObjectPtr()
    if not failed:
        result = PyObject_Vectorcall(callable, Int(args.unsafe_ptr()), len(args))
        _ = len(args)  # keeps the vector alive through the call
    for a in args:
        Py_DecRef(a)
    return checked(result)


struct Wire(Movable):
    """The wire classes of `spectest.driver.wire`, the singletons and the attribute
    names, looked up once."""

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
    var ready: Bool

    def __init__(out self):
        self.float_cls = PyObjectPtr()
        self.map_cls = PyObjectPtr()
        self.record_cls = PyObjectPtr()
        self.enum_cls = PyObjectPtr()
        self.handle_cls = PyObjectPtr()
        self.error_cls = PyObjectPtr()
        self.converted_cls = PyObjectPtr()
        self.none = PyObjectPtr()
        self.true_ = PyObjectPtr()
        self.false_ = PyObjectPtr()
        self.n_fmt = PyObjectPtr()
        self.n_bits = PyObjectPtr()
        self.n_pairs = PyObjectPtr()
        self.n_type = PyObjectPtr()
        self.n_fields = PyObjectPtr()
        self.n_member = PyObjectPtr()
        self.n_id = PyObjectPtr()
        self.n_cls = PyObjectPtr()
        self.n_bases = PyObjectPtr()
        self.n_message = PyObjectPtr()
        self.n_value = PyObjectPtr()
        self.m_resolve = PyObjectPtr()
        self.m_call = PyObjectPtr()
        self.m_get = PyObjectPtr()
        self.m_observe = PyObjectPtr()
        self.m_release = PyObjectPtr()
        self.ready = False

    def load(mut self) raises:
        var module = Owned(checked(PyImport_ImportModule("spectest.driver.wire".as_c_string_span())))
        self.none = object_symbol("_Py_NoneStruct")
        self.true_ = object_symbol("_Py_TrueStruct")
        self.false_ = object_symbol("_Py_FalseStruct")
        self.n_fmt = interned("fmt")
        self.n_bits = interned("bits")
        self.n_pairs = interned("pairs")
        self.n_type = interned("type")
        self.n_fields = interned("fields")
        self.n_member = interned("member")
        self.n_id = interned("id")
        self.n_cls = interned("cls")
        self.n_bases = interned("bases")
        self.n_message = interned("message")
        self.n_value = interned("value")
        self.m_resolve = interned("resolve")
        self.m_call = interned("call")
        self.m_get = interned("get")
        self.m_observe = interned("observe")
        self.m_release = interned("release")
        # The classes live as long as the process, like the names.
        self.float_cls = checked(PyObject_GetAttrString(module.ptr, "Float".as_c_string_span()))
        self.map_cls = checked(PyObject_GetAttrString(module.ptr, "Map".as_c_string_span()))
        self.record_cls = checked(PyObject_GetAttrString(module.ptr, "Record".as_c_string_span()))
        self.enum_cls = checked(PyObject_GetAttrString(module.ptr, "Enum".as_c_string_span()))
        self.handle_cls = checked(PyObject_GetAttrString(module.ptr, "Handle".as_c_string_span()))
        self.error_cls = checked(PyObject_GetAttrString(module.ptr, "Error".as_c_string_span()))
        self.converted_cls = checked(PyObject_GetAttrString(module.ptr, "Converted".as_c_string_span()))
        self.ready = True


def _new_wire() -> Wire:
    return Wire()


comptime _WIRE = _Global["spectest_bridge_wire", _new_wire]


def wire() raises -> Pointer[Wire, MutUntrackedOrigin]:
    """The process's wire cache, loaded on first use."""
    var w = _WIRE.get_or_create_ptr()
    if not w[].ready:
        w[].load()
    return w
