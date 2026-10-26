"""Conversion between `Value` and wire objects (the Python form of wire values, see
docs/v2/protocol.md).

Untyped: a wire object becomes the Value of its own kind, `None` an empty OPTION, and
`Converted(cls, v)` the Value of `v` (the class is dropped). A present OPTION goes to
Python unwrapped. Every reference taken here is released; `to_python` returns a new
reference."""

from std.ffi import c_int
from std.python._cpython import PyObjectPtr

from numeric.bigint import BigInt
from numeric.formats import format_by_id, format_by_name
from wire.value import (
    BOOL,
    BYTES,
    ENUM,
    ERROR,
    FLOAT,
    HANDLE,
    INT,
    LIST,
    MAP,
    OPTION,
    RECORD,
    STRING,
    TUPLE,
    Value,
)

from .capi import (
    Py_DecRef,
    Py_NewRef,
    Py_TPFLAGS_LIST_SUBCLASS,
    Py_TPFLAGS_TUPLE_SUBCLASS,
    Py_TPFLAGS_UNICODE_SUBCLASS,
    PyBool_FromLong,
    PyBytes_AsStringAndSize,
    PyBytes_FromStringAndSize,
    PyErr_Occurred,
    PyList_GetItem,
    PyList_New,
    PyList_SetItem,
    PyList_Size,
    PyLong_AsLongLongAndOverflow,
    PyLong_AsUnsignedLongLong,
    PyLong_FromLongLong,
    PyLong_FromString,
    PyLong_FromUnsignedLongLong,
    PyNumber_ToBase,
    PySequence_GetItem,
    PySequence_Size,
    PyTuple_GetItem,
    PyTuple_New,
    PyTuple_SetItem,
    PyTuple_Size,
    PyType_GetFlags,
    PyType_GetQualName,
    PyUnicode_FromStringAndSize,
    ob_type,
)
from .pyutil import (
    Owned,
    Wire,
    attr,
    call_stealing,
    checked,
    new_string,
    python_error,
    string_of,
    wire,
)


comptime Py_TPFLAGS_LONG_SUBCLASS: UInt64 = 1 << 24
comptime Py_TPFLAGS_BYTES_SUBCLASS: UInt64 = 1 << 27


# Python to Value


def from_python(obj: PyObjectPtr) raises -> Value:
    """The Value of a wire object. Raises `TypeError: ...` for anything else."""
    return _from_py(obj, wire())


def _int_value(obj: PyObjectPtr) raises -> Value:
    var overflow = c_int(0)
    var n = PyLong_AsLongLongAndOverflow(obj, overflow)
    if overflow == 0:
        if n == -1 and PyErr_Occurred():
            raise python_error()
        return Value.int(Int(n))
    var text = Owned(checked(PyNumber_ToBase(obj, 16)))
    return Value.int(BigInt.parse(string_of(text.ptr)))


def _u64(obj: PyObjectPtr) raises -> UInt64:
    var n = PyLong_AsUnsignedLongLong(obj)
    if n == UInt64.MAX and PyErr_Occurred():
        raise python_error()
    return n


def _str(obj: PyObjectPtr) raises -> String:
    if not (PyType_GetFlags(ob_type(obj)) & Py_TPFLAGS_UNICODE_SUBCLASS):
        raise Error("TypeError: expected a str, got " + _type_name(obj))
    var text = string_of(obj)
    if text == "?" and PyErr_Occurred():
        raise python_error()
    return text^


def _type_name(obj: PyObjectPtr) -> String:
    var qual = Owned(PyType_GetQualName(ob_type(obj)))
    if not qual.ptr:
        return "an object"
    return string_of(qual.ptr)


def _items(obj: PyObjectPtr) raises -> List[Owned]:
    """The elements of a list or tuple, each as a new reference."""
    var n = PySequence_Size(obj)
    if n < 0:
        raise python_error()
    var out = List[Owned](capacity=n)
    for i in range(n):
        out.append(Owned(checked(PySequence_GetItem(obj, i))))
    return out^


def _pair(obj: PyObjectPtr) raises -> List[Owned]:
    var items = _items(obj)
    if len(items) != 2:
        raise Error("TypeError: expected a pair, got " + String(len(items)) + " items")
    return items^


def _from_py(obj: PyObjectPtr, w: Pointer[Wire, MutUntrackedOrigin]) raises -> Value:
    if obj == w[].none:
        return Value.none()
    if obj == w[].true_:
        return Value.bool(True)
    if obj == w[].false_:
        return Value.bool(False)
    var t = ob_type(obj)
    var flags = PyType_GetFlags(t)
    if flags & Py_TPFLAGS_LONG_SUBCLASS:
        return _int_value(obj)
    if flags & Py_TPFLAGS_UNICODE_SUBCLASS:
        return Value.string(_str(obj))
    if flags & Py_TPFLAGS_BYTES_SUBCLASS:
        var data = 0
        var size = 0
        if PyBytes_AsStringAndSize(obj, data, size) < 0:
            raise python_error()
        var bytes = List[UInt8](capacity=size)
        var src = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=data)
        for i in range(size):
            bytes.append(src[unsafe_offset=i])
        return Value.bytes(bytes^)
    if flags & Py_TPFLAGS_LIST_SUBCLASS:
        var n = PyList_Size(obj)
        var out = List[Value](capacity=n)
        for i in range(n):
            out.append(_from_py(PyList_GetItem(obj, i), w))
        return Value.list(out^)
    if flags & Py_TPFLAGS_TUPLE_SUBCLASS:
        var n = PyTuple_Size(obj)
        var out = List[Value](capacity=n)
        for i in range(n):
            out.append(_from_py(PyTuple_GetItem(obj, i), w))
        return Value.tuple(out^)
    if t == w[].float_cls:
        var fmt = attr(obj, w[].n_fmt)
        var bits = attr(obj, w[].n_bits)
        return Value.float(format_by_name(_str(fmt.ptr)), _u64(bits.ptr))
    if t == w[].map_cls:
        var pairs = attr(obj, w[].n_pairs)
        var keys = List[Value]()
        var values = List[Value]()
        for p in _items(pairs.ptr):
            var kv = _pair(p.ptr)
            keys.append(_from_py(kv[0].ptr, w))
            values.append(_from_py(kv[1].ptr, w))
        return Value.map(keys^, values^)
    if t == w[].record_cls:
        var type = attr(obj, w[].n_type)
        var fields = attr(obj, w[].n_fields)
        var names = List[String]()
        var values = List[Value]()
        for p in _items(fields.ptr):
            var kv = _pair(p.ptr)
            names.append(_str(kv[0].ptr))
            values.append(_from_py(kv[1].ptr, w))
        return Value.record(_str(type.ptr), names, values^)
    if t == w[].enum_cls:
        var type = attr(obj, w[].n_type)
        var member = attr(obj, w[].n_member)
        return Value.enum(_str(type.ptr), _str(member.ptr))
    if t == w[].handle_cls:
        var id = attr(obj, w[].n_id)
        var cls = attr(obj, w[].n_cls)
        return Value.handle(_u64(id.ptr), _str(cls.ptr))
    if t == w[].error_cls:
        var cls = attr(obj, w[].n_cls)
        var bases = attr(obj, w[].n_bases)
        var message = attr(obj, w[].n_message)
        var names = List[String]()
        for b in _items(bases.ptr):
            names.append(_str(b.ptr))
        return Value.error(_str(cls.ptr), names, _str(message.ptr))
    if t == w[].converted_cls:
        var inner = attr(obj, w[].n_value)
        return _from_py(inner.ptr, w)
    raise Error("TypeError: not a wire object: " + _type_name(obj))


# Value to Python


def to_python(value: Value) raises -> PyObjectPtr:
    """The wire object for a Value, a new reference."""
    return _to_py(value, wire())


def _tuple2(first: PyObjectPtr, second: PyObjectPtr) -> PyObjectPtr:
    var made = PyTuple_New(2) if first and second else PyObjectPtr()
    if not made:
        Py_DecRef(first)
        Py_DecRef(second)
        return made
    _ = PyTuple_SetItem(made, 0, first)
    _ = PyTuple_SetItem(made, 1, second)
    return made


def _to_py(value: Value, w: Pointer[Wire, MutUntrackedOrigin]) raises -> PyObjectPtr:
    var kind = value.kind
    if kind == BOOL:
        return checked(PyBool_FromLong(value.as_bool()))
    if kind == INT:
        var small = value.small_int()
        if small:
            return checked(PyLong_FromLongLong(Int64(small.value())))
        var text = value.as_bigint().hex()
        var bytes = List[UInt8](capacity=text.byte_length() + 1)
        for b in text.as_bytes():
            bytes.append(b)
        bytes.append(0)
        var made = PyLong_FromString(Int(bytes.unsafe_ptr()), 16)
        _ = len(bytes)  # keeps the text alive through the call
        return checked(made)
    if kind == FLOAT:
        var fmt = format_by_id(value.float_format_id())
        var args = List[PyObjectPtr]()
        args.append(PyUnicode_FromStringAndSize(String(fmt.name())))
        args.append(PyLong_FromUnsignedLongLong(value.float_bits()))
        return call_stealing(w[].float_cls, args)
    if kind == STRING:
        return new_string(value.text())
    if kind == BYTES:
        ref data = value.data()
        return checked(PyBytes_FromStringAndSize(Int(data.unsafe_ptr()), len(data)))
    if kind == LIST:
        var n = value.count()
        var out = checked(PyList_New(n))
        for i in range(n):
            var item: PyObjectPtr
            try:
                item = _to_py(value.item(i), w)
            except e:
                Py_DecRef(out)
                raise e^
            _ = PyList_SetItem(out, i, item)
        return out
    if kind == TUPLE:
        return _tuple_of(value, 0, 1, w)
    if kind == OPTION:
        if value.count() == 0:
            return Py_NewRef(w[].none)
        return _to_py(value.item(0), w)
    if kind == MAP:
        var args = List[PyObjectPtr]()
        args.append(_pairs(value, w))
        return call_stealing(w[].map_cls, args)
    if kind == RECORD:
        var args = List[PyObjectPtr]()
        args.append(PyUnicode_FromStringAndSize(value.name()))
        args.append(_pairs(value, w))
        return call_stealing(w[].record_cls, args)
    if kind == ENUM:
        var args = List[PyObjectPtr]()
        args.append(PyUnicode_FromStringAndSize(value.name()))
        args.append(PyUnicode_FromStringAndSize(value.text()))
        return call_stealing(w[].enum_cls, args)
    if kind == HANDLE:
        var args = List[PyObjectPtr]()
        args.append(PyLong_FromUnsignedLongLong(value.handle_id()))
        args.append(PyUnicode_FromStringAndSize(value.name()))
        return call_stealing(w[].handle_cls, args)
    if kind == ERROR:
        var args = List[PyObjectPtr]()
        args.append(PyUnicode_FromStringAndSize(value.name()))
        args.append(_tuple_of(value, 0, 1, w))
        args.append(PyUnicode_FromStringAndSize(value.text()))
        return call_stealing(w[].error_cls, args)
    raise Error("TypeError: a " + String(kind) + " value has no wire form")


def _tuple_of(
    value: Value, start: Int, step: Int, w: Pointer[Wire, MutUntrackedOrigin]
) raises -> PyObjectPtr:
    """A tuple of the value's heap items at `start`, `start + step`, ..."""
    var n = value.item_count() // step
    var out = checked(PyTuple_New(n))
    for i in range(n):
        var item: PyObjectPtr
        try:
            item = _to_py(value.item(start + i * step), w)
        except e:
            Py_DecRef(out)
            raise e^
        _ = PyTuple_SetItem(out, i, item)
    return out


def _pairs(value: Value, w: Pointer[Wire, MutUntrackedOrigin]) raises -> PyObjectPtr:
    """A MAP's or RECORD's items as a tuple of (key, value) pairs. A RECORD's field
    names are STRING values, which come out as str."""
    var n = value.count()
    var out = checked(PyTuple_New(n))
    for i in range(n):
        var made: PyObjectPtr
        try:
            var key = _to_py(value.item(2 * i), w)
            var item: PyObjectPtr
            try:
                item = _to_py(value.item(2 * i + 1), w)
            except e:
                Py_DecRef(key)
                raise e^
            made = _tuple2(key, item)
        except e:
            Py_DecRef(out)
            raise e^
        if not made:
            Py_DecRef(out)
            raise python_error()
        _ = PyTuple_SetItem(out, i, made)
    return out
