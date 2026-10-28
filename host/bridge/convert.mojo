"""Conversion between `Value` and wire objects (the Python form of wire values, see
docs/v2/protocol.md).

Untyped: a wire object becomes the Value of its own kind, `None` an empty OPTION, and
`Converted(cls, v)` the Value of `v` (the class is dropped). A present OPTION goes to
Python unwrapped.
"""

from std.ffi import c_int
from std.python._cpython import (
    Py_TPFLAGS_BYTES_SUBCLASS,
    Py_TPFLAGS_LIST_SUBCLASS,
    Py_TPFLAGS_LONG_SUBCLASS,
    Py_TPFLAGS_TUPLE_SUBCLASS,
    Py_TPFLAGS_UNICODE_SUBCLASS,
    PyObjectPtr,
)

from numeric.bigint import BigInt
from numeric.formats import format_by_name
from wire.value import Value

from .capi import (
    Py_NewRef,
    PyBool_FromLong,
    PyBytes_AsStringAndSize,
    PyBytes_FromStringAndSize,
    PyErr_Occurred,
    PyList_GetItem,
    PyList_Size,
    PyLong_AsLongLongAndOverflow,
    PyLong_AsUnsignedLongLong,
    PyLong_FromString,
    PyNumber_ToBase,
    PySequence_GetItem,
    PySequence_Size,
    PyTuple_GetItem,
    PyTuple_Size,
    PyType_GetFlags,
    ob_type,
)
from .pyutil import (
    Owned,
    Wire,
    attr,
    call,
    checked,
    new_int,
    new_list,
    new_string,
    new_tuple,
    new_u64,
    python_error,
    qualname,
    span_at,
    string_of,
    wire,
)


def from_python(obj: PyObjectPtr) raises -> Value:
    """The Value of a wire object. Raises `TypeError: ...` for anything else."""
    return _value_of(obj, wire()[])


def to_python(value: Value) raises -> PyObjectPtr:
    """The wire object for a Value, a new reference."""
    return _object_of(value, wire()[]).take()


def _int_value(obj: PyObjectPtr) raises -> Value:
    var overflow = c_int(0)
    var n = PyLong_AsLongLongAndOverflow(obj, overflow)
    if overflow != 0:
        return Value.int(BigInt.parse(string_of(Owned(checked(PyNumber_ToBase(obj, 16))))))
    if n == -1 and PyErr_Occurred():
        raise python_error()
    return Value.int(Int(n))


def _u64(obj: PyObjectPtr) raises -> UInt64:
    var n = PyLong_AsUnsignedLongLong(obj)
    if n == UInt64.MAX and PyErr_Occurred():
        raise python_error()
    return n


def _str(obj: PyObjectPtr) raises -> String:
    if not (PyType_GetFlags(ob_type(obj)) & Py_TPFLAGS_UNICODE_SUBCLASS):
        raise Error(t"TypeError: expected a str, got {_type_name(obj)}")
    return string_of(obj)


def _bytes(obj: PyObjectPtr) raises -> List[UInt8]:
    var data = 0
    var size = 0
    if PyBytes_AsStringAndSize(obj, data, size) < 0:
        raise python_error()
    return List(span_at(data, size))


def _type_name(obj: PyObjectPtr) -> String:
    return qualname(ob_type(obj)).or_else("an object")


def _items(obj: PyObjectPtr) raises -> List[Owned]:
    """The elements of a list or tuple, each as a new reference."""
    var n = PySequence_Size(obj)
    if n < 0:
        raise python_error()
    return [Owned(checked(PySequence_GetItem(obj, i))) for i in range(n)]


def _pair(obj: Owned) raises -> List[Owned]:
    var items = _items(obj.ptr)
    if len(items) != 2:
        raise Error(t"TypeError: expected a pair, got {len(items)} items")
    return items^


def _str_attr(obj: PyObjectPtr, name: PyObjectPtr) raises -> String:
    return _str(attr(obj, name).ptr)


def _u64_attr(obj: PyObjectPtr, name: PyObjectPtr) raises -> UInt64:
    return _u64(attr(obj, name).ptr)


def _items_attr(obj: PyObjectPtr, name: PyObjectPtr) raises -> List[Owned]:
    return _items(attr(obj, name).ptr)


def _value_of(obj: PyObjectPtr, wire: Wire) raises -> Value:
    if obj == wire.none:
        return Value.none()
    if obj == wire.true:
        return Value.bool(True)
    if obj == wire.false:
        return Value.bool(False)
    var type = ob_type(obj)
    var flags = PyType_GetFlags(type)
    if flags & Py_TPFLAGS_LONG_SUBCLASS:
        return _int_value(obj)
    if flags & Py_TPFLAGS_UNICODE_SUBCLASS:
        return Value.string(string_of(obj))
    if flags & Py_TPFLAGS_BYTES_SUBCLASS:
        return Value.bytes(_bytes(obj))
    if flags & Py_TPFLAGS_LIST_SUBCLASS:
        return Value.list([_value_of(PyList_GetItem(obj, i), wire) for i in range(PyList_Size(obj))])
    if flags & Py_TPFLAGS_TUPLE_SUBCLASS:
        return Value.tuple([_value_of(PyTuple_GetItem(obj, i), wire) for i in range(PyTuple_Size(obj))])
    ref classes = wire.classes
    ref names = wire.names
    if type == classes.float:
        return Value.float(format_by_name(_str_attr(obj, names.fmt)), _u64_attr(obj, names.bits))
    if type == classes.map:
        var keys: List[Value] = []
        var values: List[Value] = []
        for item in _items_attr(obj, names.pairs):
            var pair = _pair(item)
            keys.append(_value_of(pair[0].ptr, wire))
            values.append(_value_of(pair[1].ptr, wire))
        return Value.map(keys^, values^)
    if type == classes.record:
        var fields: List[String] = []
        var values: List[Value] = []
        for item in _items_attr(obj, names.fields):
            var pair = _pair(item)
            fields.append(_str(pair[0].ptr))
            values.append(_value_of(pair[1].ptr, wire))
        return Value.record(_str_attr(obj, names.type), fields, values^)
    if type == classes.enum:
        return Value.enum(_str_attr(obj, names.type), _str_attr(obj, names.member))
    if type == classes.handle:
        return Value.handle(_u64_attr(obj, names.id), _str_attr(obj, names.cls))
    if type == classes.error:
        var bases = [_str(base.ptr) for base in _items_attr(obj, names.bases)]
        return Value.error(_str_attr(obj, names.cls), bases, _str_attr(obj, names.message))
    if type == classes.converted:
        return _value_of(attr(obj, names.value).ptr, wire)
    raise Error(t"TypeError: not a wire object: {_type_name(obj)}")


def _object_of(value: Value, wire: Wire) raises -> Owned:
    ref classes = wire.classes
    match value.kind:
        case .BOOL:
            return Owned(checked(PyBool_FromLong(value.as_bool())))
        case .INT:
            if case .Some(small) = value.small_int():
                return new_int(small)
            var digits = value.as_bigint().hex()
            return Owned(checked(PyLong_FromString(digits.as_c_string_span(), 16)))
        case .FLOAT:
            var format = value.float_format().name()
            return call(classes.float, [new_string(format), new_u64(value.float_bits())])
        case .STRING:
            return new_string(value.text())
        case .BYTES:
            return Owned(checked(PyBytes_FromStringAndSize(value.data())))
        case .LIST:
            return new_list([_object_of(item, wire) for item in value.items()])
        case .TUPLE:
            return _tuple_of_items(value, wire)
        case .OPTION:
            return Owned(Py_NewRef(wire.none)) if value.count() == 0 else _object_of(value.item(0), wire)
        case .MAP:
            return call(classes.map, [_tuple_of_pairs(value, wire)])
        case .RECORD:
            return call(classes.record, [new_string(value.name()), _tuple_of_pairs(value, wire)])
        case .ENUM:
            return call(classes.enum, [new_string(value.name()), new_string(value.text())])
        case .HANDLE:
            return call(classes.handle, [new_u64(value.handle_id()), new_string(value.name())])
        case .ERROR:
            return call(
                classes.error,
                [new_string(value.name()), _tuple_of_items(value, wire), new_string(value.text())],
            )
        case .INVALID | .REAL | .QERR:
            raise Error(t"TypeError: a {value.kind} value has no wire form")


def _tuple_of_items(value: Value, wire: Wire) raises -> Owned:
    return new_tuple([_object_of(item, wire) for item in value.items()])


def _tuple_of_pairs(value: Value, wire: Wire) raises -> Owned:
    """A MAP's or RECORD's items as a tuple of (key, value) pairs."""
    return new_tuple(
        [new_tuple([_object_of(key, wire), _object_of(item, wire)]) for key, item in value.pairs()]
    )
