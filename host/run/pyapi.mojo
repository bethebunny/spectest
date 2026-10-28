"""The Python side of the API: options read from a dict, results built as dicts."""

from std.memory import bitcast
from std.python._cpython import (
    Py_TPFLAGS_DICT_SUBCLASS,
    Py_TPFLAGS_LIST_SUBCLASS,
    Py_TPFLAGS_UNICODE_SUBCLASS,
    PyObjectPtr,
)

from bridge.capi import (
    Py_DecRef,
    PyDict_New,
    PyDict_Next,
    PyDict_SetItemString,
    PyFloat_FromDouble,
    PyList_GetItem,
    PyList_New,
    PyList_SetItem,
    PyList_Size,
    PyType_GetFlags,
    ob_type,
)
from bridge.convert import from_python, to_python
from bridge.pyutil import checked, python_error, string_of, wire
from wire.value import Value

from .options import RunOptions

def _is_dict(o: PyObjectPtr) -> Bool:
    return Bool(PyType_GetFlags(ob_type(o)) & Py_TPFLAGS_DICT_SUBCLASS)


def _text(o: PyObjectPtr, what: String) raises -> String:
    if not (PyType_GetFlags(ob_type(o)) & Py_TPFLAGS_UNICODE_SUBCLASS):
        raise Error(String("TypeError: ", what, " must be a str"))
    return string_of(o)


def _int(o: PyObjectPtr, what: String) raises -> Int:
    var v = from_python(o)
    if v.kind != .INT or not v.small_int():
        raise Error(String("TypeError: ", what, " must be an int"))
    return v.small_int().value()


def _items(d: PyObjectPtr) -> List[Tuple[PyObjectPtr, PyObjectPtr]]:
    var items: List[Tuple[PyObjectPtr, PyObjectPtr]] = []
    var pos = 0
    var key = PyObjectPtr()
    var value = PyObjectPtr()
    while PyDict_Next(d, pos, key, value):
        items.append((key, value))
    return items^


def parse_options(o: PyObjectPtr) raises -> RunOptions:
    """The options dict of `run` (docs/v2/host-api.md). Unknown keys are ignored."""
    var opts = RunOptions()
    if not _is_dict(o):
        raise Error("TypeError: options must be a dict")
    for key, value in _items(o):
        var name = _text(key, "an option name")
        var is_none = value == wire()[].none
        match name:
            case "seed":
                opts.seed = UInt64(bitcast[DType.uint64](Int64(_int(value, "seed"))))
            case "max_examples":
                opts.max_examples = _int(value, name)
            case "exhaustive_limit":
                opts.exhaustive_limit = _int(value, name)
            case "strength":
                opts.strength = _text(value, name)
            case "aggregate_samples":
                opts.aggregate_samples = _int(value, name)
            case "steps":
                opts.steps = _int(value, name)
            case "max_handles":
                opts.max_handles = _int(value, name)
            case "store":
                if not is_none:
                    opts.store = _text(value, name)
            case "instantiation":
                if not is_none:
                    if not _is_dict(value):
                        raise Error("TypeError: instantiation must be a dict")
                    for param, arg in _items(value):
                        opts.instantiation[_text(param, "a type parameter name")] = _text(arg, "a type argument")
            case "examples":
                if not is_none:
                    if not (PyType_GetFlags(ob_type(value)) & Py_TPFLAGS_LIST_SUBCLASS):
                        raise Error("TypeError: examples must be a list")
                    for i in range(PyList_Size(value)):
                        var example = PyList_GetItem(value, i)
                        if not _is_dict(example):
                            raise Error("TypeError: an example must be a dict")
                        var keys: List[Value] = []
                        var values: List[Value] = []
                        for param, arg in _items(example):
                            keys.append(Value.string(_text(param, "a parameter name")))
                            values.append(from_python(arg))
                        opts.examples.append(Value.map(keys^, values^))
            case _:
                pass
    return opts^


def result_to_python(v: Value) raises -> PyObjectPtr:
    """A result `Value` tree as Python: MAP with string keys as dict, LIST as list,
    an empty OPTION as None, an f64 FLOAT as float; scalars as themselves."""
    match v.kind:
        case .MAP:
            var d = checked(PyDict_New())
            for key, value in v.pairs():
                var item: PyObjectPtr
                try:
                    item = result_to_python(value)
                except e:
                    Py_DecRef(d)
                    raise e^
                var status = _set_item(d, key.text(), item)
                Py_DecRef(item)
                if status != 0:
                    Py_DecRef(d)
                    raise python_error()
            return d
        case .LIST:
            var out = checked(PyList_New(v.count()))
            for i, value in enumerate(v.items()):
                var item: PyObjectPtr
                try:
                    item = result_to_python(value)
                except e:
                    Py_DecRef(out)
                    raise e^
                _ = PyList_SetItem(out, i, item)
            return out
        case .FLOAT:
            return checked(PyFloat_FromDouble(bitcast[DType.float64](v.float_bits())))
        case _:
            return to_python(v)


def _set_item(d: PyObjectPtr, var key: String, value: PyObjectPtr) -> Int:
    return Int(PyDict_SetItemString(d, key.as_c_string_span(), value))
