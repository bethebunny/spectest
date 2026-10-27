"""The Python side of the API: options read from a dict, results built as dicts."""

from std.memory import bitcast
from std.python._cpython import PyObjectPtr

from bridge.capi import (
    Py_DecRef,
    PyBool_FromLong,
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
from bridge.pyutil import Owned, checked, python_error, string_of, wire
from wire.value import (
    BOOL,
    FLOAT,
    INT,
    LIST,
    MAP,
    OPTION,
    STRING,
    Value,
)

from .options import RunOptions

comptime Py_TPFLAGS_DICT_SUBCLASS: UInt64 = 1 << 29
comptime Py_TPFLAGS_UNICODE: UInt64 = 1 << 28
comptime Py_TPFLAGS_LIST: UInt64 = 1 << 25


def _is_dict(o: PyObjectPtr) -> Bool:
    return Bool(PyType_GetFlags(ob_type(o)) & Py_TPFLAGS_DICT_SUBCLASS)


def _text(o: PyObjectPtr, what: String) raises -> String:
    if not (PyType_GetFlags(ob_type(o)) & Py_TPFLAGS_UNICODE):
        raise Error(String("TypeError: ", what, " must be a str"))
    return string_of(o)


def _int(o: PyObjectPtr, what: String) raises -> Int:
    var v = from_python(o)
    if v.kind != INT or not v.small_int():
        raise Error(String("TypeError: ", what, " must be an int"))
    return v.small_int().value()


def parse_options(o: PyObjectPtr) raises -> RunOptions:
    """The options dict of `run` (docs/v2/host-api.md). Unknown keys are ignored."""
    var opts = RunOptions()
    if not _is_dict(o):
        raise Error("TypeError: options must be a dict")
    var pos = 0
    var key = PyObjectPtr()
    var value = PyObjectPtr()
    while PyDict_Next(o, pos, key, value):
        var name = _text(key, "an option name")
        var none = value == wire()[].none
        if name == "seed":
            opts.seed = UInt64(bitcast[DType.uint64](Int64(_int(value, "seed"))))
        elif name == "max_examples":
            opts.max_examples = _int(value, "max_examples")
        elif name == "exhaustive_limit":
            opts.exhaustive_limit = _int(value, "exhaustive_limit")
        elif name == "store":
            if not none:
                opts.store = _text(value, "store")
        elif name == "strength":
            opts.strength = _text(value, "strength")
        elif name == "aggregate_samples":
            opts.aggregate_samples = _int(value, "aggregate_samples")
        elif name == "steps":
            opts.steps = _int(value, "steps")
        elif name == "max_handles":
            opts.max_handles = _int(value, "max_handles")
        elif name == "instantiation":
            if not none:
                if not _is_dict(value):
                    raise Error("TypeError: instantiation must be a dict")
                var p2 = 0
                var k2 = PyObjectPtr()
                var v2 = PyObjectPtr()
                while PyDict_Next(value, p2, k2, v2):
                    opts.inst_names.append(_text(k2, "a type parameter name"))
                    opts.inst_types.append(_text(v2, "a type argument"))
        elif name == "examples":
            if not none:
                if not (PyType_GetFlags(ob_type(value)) & Py_TPFLAGS_LIST):
                    raise Error("TypeError: examples must be a list")
                for i in range(PyList_Size(value)):
                    var ex = PyList_GetItem(value, i)
                    if not _is_dict(ex):
                        raise Error("TypeError: an example must be a dict")
                    var keys = List[Value]()
                    var vals = List[Value]()
                    var p3 = 0
                    var k3 = PyObjectPtr()
                    var v3 = PyObjectPtr()
                    while PyDict_Next(ex, p3, k3, v3):
                        keys.append(Value.string(_text(k3, "a parameter name")))
                        vals.append(from_python(v3))
                    opts.examples.append(Value.map(keys^, vals^))
    return opts^


def result_to_python(v: Value) raises -> PyObjectPtr:
    """A result `Value` tree as Python: MAP with string keys as dict, LIST as list,
    an empty OPTION as None, an f64 FLOAT as float; scalars as themselves."""
    var kind = v.kind
    if kind == MAP:
        var d = checked(PyDict_New())
        for i in range(v.count()):
            var item: PyObjectPtr
            try:
                item = result_to_python(v.item(2 * i + 1))
            except e:
                Py_DecRef(d)
                raise e^
            var rc = PyDictSetItem(d, v.item(2 * i).text(), item)
            Py_DecRef(item)
            if rc != 0:
                Py_DecRef(d)
                raise python_error()
        return d
    if kind == LIST:
        var n = v.count()
        var out = checked(PyList_New(n))
        for i in range(n):
            var item: PyObjectPtr
            try:
                item = result_to_python(v.item(i))
            except e:
                Py_DecRef(out)
                raise e^
            _ = PyList_SetItem(out, i, item)
        return out
    if kind == FLOAT:
        return checked(PyFloat_FromDouble(bitcast[DType.float64](v.float_bits())))
    return to_python(v)


def PyDictSetItem(d: PyObjectPtr, var key: String, value: PyObjectPtr) -> Int:
    return Int(PyDict_SetItemString(d, key.as_c_string_span(), value))
