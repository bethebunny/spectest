"""Conversion between `Value` and wire objects (the Python form of wire values, see
docs/v2/protocol.md).

Untyped: a wire object becomes the Value of its own kind, `None` an empty OPTION, and
`Converted(cls, v)` the Value of `v` (the class is dropped). A present OPTION goes to
Python unwrapped.
"""

from std.ffi import c_int
from std.python._cpython import PyObjectPtr

from numeric.bigint import BigInt
from numeric.formats import format_by_name
from wire.value import Value

from .capi import (
    Py_NewRef,
    Py_TPFLAGS_BYTES_SUBCLASS,
    Py_TPFLAGS_LIST_SUBCLASS,
    Py_TPFLAGS_LONG_SUBCLASS,
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
    PyNumber_ToBase,
    PySequence_GetItem,
    PySequence_Size,
    PyTuple_GetItem,
    PyTuple_New,
    PyTuple_SetItem,
    PyTuple_Size,
    PyType_GetFlags,
    PyType_GetQualName,
    ob_type,
)
from .pyutil import (
    Owned, Wire, attr, call, checked, new_string, new_u64, python_error, span_at, string_of, wire,
)


def from_python(obj: PyObjectPtr) raises -> Value:
    """The Value of a wire object. Raises `TypeError: ...` for anything else."""
    return _from_py(obj, wire())


def to_python(value: Value) raises -> PyObjectPtr:
    """The wire object for a Value, a new reference."""
    return _to_py(value, wire()).take()


def _int_value(obj: PyObjectPtr) raises -> Value:
    var overflow = c_int(0)
    var n = PyLong_AsLongLongAndOverflow(obj, overflow)
    if overflow == 0:
        if n == -1 and PyErr_Occurred():
            raise python_error()
        return Value.int(Int(n))
    var text = Owned(checked(PyNumber_ToBase(obj, 16)))
    return Value.int(BigInt.parse(string_of(text)))


def _u64(obj: PyObjectPtr) raises -> UInt64:
    var n = PyLong_AsUnsignedLongLong(obj)
    if n == UInt64.MAX and PyErr_Occurred():
        raise python_error()
    return n


def _str(obj: PyObjectPtr) raises -> String:
    if not (PyType_GetFlags(ob_type(obj)) & Py_TPFLAGS_UNICODE_SUBCLASS):
        raise Error(t"TypeError: expected a str, got {_type_name(obj)}")
    var text = string_of(obj)
    if text == "?" and PyErr_Occurred():
        raise python_error()
    return text^


# The attribute stays alive through `obj`, so its owner may die before the call.
def _str_attr(obj: PyObjectPtr, name: PyObjectPtr) raises -> String:
    var value = attr(obj, name)
    return _str(value.ptr)


def _u64_attr(obj: PyObjectPtr, name: PyObjectPtr) raises -> UInt64:
    var value = attr(obj, name)
    return _u64(value.ptr)


def _type_name(obj: PyObjectPtr) -> String:
    var qual = Owned(PyType_GetQualName(ob_type(obj)))
    return string_of(qual) if qual.ptr else "an object"


def _items(obj: PyObjectPtr) raises -> List[Owned]:
    """The elements of a list or tuple, each as a new reference."""
    var n = PySequence_Size(obj)
    if n < 0:
        raise python_error()
    var out = List[Owned](capacity=n)
    for i in range(n):
        out.append(Owned(checked(PySequence_GetItem(obj, i))))
    return out^


def _items_attr(obj: PyObjectPtr, name: PyObjectPtr) raises -> List[Owned]:
    var value = attr(obj, name)
    return _items(value.ptr)


def _pair(obj: Owned) raises -> List[Owned]:
    var items = _items(obj.ptr)
    if len(items) != 2:
        raise Error(t"TypeError: expected a pair, got {len(items)} items")
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
        return Value.bytes(List[UInt8](span_at(data, size)))
    if flags & Py_TPFLAGS_LIST_SUBCLASS:
        return Value.list([_from_py(PyList_GetItem(obj, i), w) for i in range(PyList_Size(obj))])
    if flags & Py_TPFLAGS_TUPLE_SUBCLASS:
        return Value.tuple([_from_py(PyTuple_GetItem(obj, i), w) for i in range(PyTuple_Size(obj))])
    if t == w[].float_cls:
        return Value.float(
            format_by_name(_str_attr(obj, w[].n_fmt)), _u64_attr(obj, w[].n_bits)
        )
    if t == w[].map_cls:
        var keys = List[Value]()
        var values = List[Value]()
        for p in _items_attr(obj, w[].n_pairs):
            var kv = _pair(p)
            keys.append(_from_py(kv[0].ptr, w))
            values.append(_from_py(kv[1].ptr, w))
        return Value.map(keys^, values^)
    if t == w[].record_cls:
        var names = List[String]()
        var values = List[Value]()
        for p in _items_attr(obj, w[].n_fields):
            var kv = _pair(p)
            names.append(_str(kv[0].ptr))
            values.append(_from_py(kv[1].ptr, w))
        return Value.record(_str_attr(obj, w[].n_type), names, values^)
    if t == w[].enum_cls:
        return Value.enum(_str_attr(obj, w[].n_type), _str_attr(obj, w[].n_member))
    if t == w[].handle_cls:
        return Value.handle(_u64_attr(obj, w[].n_id), _str_attr(obj, w[].n_cls))
    if t == w[].error_cls:
        var bases = List[String]()
        for b in _items_attr(obj, w[].n_bases):
            bases.append(_str(b.ptr))
        return Value.error(
            _str_attr(obj, w[].n_cls), bases, _str_attr(obj, w[].n_message)
        )
    if t == w[].converted_cls:
        var inner = attr(obj, w[].n_value)
        return _from_py(inner.ptr, w)
    raise Error(t"TypeError: not a wire object: {_type_name(obj)}")


def _to_py(value: Value, w: Pointer[Wire, MutUntrackedOrigin]) raises -> Owned:
    var kind = value.kind
    if kind == .BOOL:
        return Owned(checked(PyBool_FromLong(value.as_bool())))
    if kind == .INT:
        var small: Optional[Int]
        if (small := value.small_int()) is not None:
            return Owned(checked(PyLong_FromLongLong(Int64(small.value()))))
        var digits: List[UInt8] = [b for b in value.as_bigint().hex().as_bytes()]
        digits.append(0)
        var made = PyLong_FromString(Int(digits.unsafe_ptr()), 16)
        _ = len(digits)  # keeps the text alive through the call
        return Owned(checked(made))
    if kind == .FLOAT:
        var fmt = value.float_format()
        return call(w[].float_cls, [new_string(String(fmt.name())), new_u64(value.float_bits())])
    if kind == .STRING:
        return new_string(value.text())
    if kind == .BYTES:
        ref data = value.data()
        return Owned(checked(PyBytes_FromStringAndSize(Int(data.unsafe_ptr()), len(data))))
    if kind == .LIST:
        var out = Owned(checked(PyList_New(value.count())))
        for i in range(value.count()):
            _ = PyList_SetItem(out.ptr, i, _to_py(value.item(i), w).take())
        return out^
    if kind == .TUPLE:
        return _tuple_of_items(value, w)
    if kind == .OPTION:
        return Owned(Py_NewRef(w[].none)) if value.count() == 0 else _to_py(value.item(0), w)
    if kind == .MAP:
        return call(w[].map_cls, [_pairs(value, w)])
    if kind == .RECORD:
        return call(w[].record_cls, [new_string(value.name()), _pairs(value, w)])
    if kind == .ENUM:
        return call(w[].enum_cls, [new_string(value.name()), new_string(value.text())])
    if kind == .HANDLE:
        return call(w[].handle_cls, [new_u64(value.handle_id()), new_string(value.name())])
    if kind == .ERROR:
        return call(
            w[].error_cls,
            [new_string(value.name()), _tuple_of_items(value, w), new_string(value.text())],
        )
    raise Error(t"TypeError: a {kind} value has no wire form")


def _tuple_of_items(value: Value, w: Pointer[Wire, MutUntrackedOrigin]) raises -> Owned:
    var out = Owned(checked(PyTuple_New(value.item_count())))
    for i in range(value.item_count()):
        _ = PyTuple_SetItem(out.ptr, i, _to_py(value.item(i), w).take())
    return out^


def _pairs(value: Value, w: Pointer[Wire, MutUntrackedOrigin]) raises -> Owned:
    """A MAP's or RECORD's items as a tuple of (key, value) pairs."""
    var out = Owned(checked(PyTuple_New(value.count())))
    for i in range(value.count()):
        var pair = Owned(checked(PyTuple_New(2)))
        _ = PyTuple_SetItem(pair.ptr, 0, _to_py(value.item(2 * i), w).take())
        _ = PyTuple_SetItem(pair.ptr, 1, _to_py(value.item(2 * i + 1), w).take())
        _ = PyTuple_SetItem(out.ptr, i, pair^.take())
    return out^
