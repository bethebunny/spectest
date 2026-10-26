"""`spectest._host`, the CPython extension module the pytest plugin loads.

Functions for Python (the host's own entry points arrive with later packages):

- `version() -> str`
- `echo(obj)`: a wire object to a Value and back; `TypeError` for anything else.
- `call(driver, name, args)`: resolve `name` through the driver, call it with `args`
  (a list of wire objects) and return the result. The path of a host call.
- `bench(driver, name, args, n) -> float`: seconds per call over `n` calls.

The Mojo API for the other packages is in `bridge.convert` (`to_python`,
`from_python`) and `bridge.client` (`DriverClient`).
"""

from std.memory.alloc import unsafe_alloc
from std.python._cpython import PyObjectPtr
from std.time import perf_counter_ns

from wire.value import LIST, Value

from bridge.capi import (
    METH_FASTCALL,
    METH_NOARGS,
    METH_O,
    MethodDef,
    ModuleDef,
    Py_NewRef,
    PyErr_SetObject,
    PyFloat_FromDouble,
    PyLong_AsLong,
    PyModuleDef_Init,
    PyErr_Occurred,
    Py_DecRef,
    PyUnicode_FromStringAndSize,
    address,
    leaked,
    pointer_symbol,
    text,
)
from bridge.client import DriverClient
from bridge.convert import from_python, to_python
from bridge.pyutil import Owned, checked, python_error, string_of

comptime VERSION = "0.1.0.dev0"


def _raise(e: Error) -> PyObjectPtr:
    """Sets Python's error from a Mojo error and returns NULL. Errors that start with
    `TypeError: ` are TypeErrors; the rest are RuntimeErrors."""
    var message = String(e)
    var kind = pointer_symbol("PyExc_RuntimeError")
    comptime PREFIX = "TypeError: "
    if message.startswith(PREFIX):
        kind = pointer_symbol("PyExc_TypeError")
        var rest = String(message[byte = PREFIX.byte_length() :])
        message = rest^
    var made = PyUnicode_FromStringAndSize(message)
    if made:
        PyErr_SetObject(kind, made)
        Py_DecRef(made)
    return PyObjectPtr()


def _argument(args: Int, i: Int) -> PyObjectPtr:
    return Pointer[PyObjectPtr, MutUntrackedOrigin](unsafe_from_address=args)[
        unsafe_offset=i
    ]


def _values(list: PyObjectPtr) raises -> List[Value]:
    var v = from_python(list)
    if not v.is_(LIST):
        raise Error("TypeError: args must be a list of wire objects")
    var out = List[Value](capacity=v.count())
    for i in range(v.count()):
        out.append(v.item(i))
    return out^


def version(module: PyObjectPtr, unused: PyObjectPtr) abi("C") -> PyObjectPtr:
    return PyUnicode_FromStringAndSize(VERSION)


def echo(module: PyObjectPtr, obj: PyObjectPtr) abi("C") -> PyObjectPtr:
    try:
        return to_python(from_python(obj))
    except e:
        return _raise(e)


def call(module: PyObjectPtr, args: Int, nargs: Int) abi("C") -> PyObjectPtr:
    try:
        if nargs != 3:
            raise Error("TypeError: call(driver, name, args) takes 3 arguments")
        var client = DriverClient(_argument(args, 0))
        var name = _name(_argument(args, 1))
        var target = client.resolve(name)
        return to_python(client.call(target, _values(_argument(args, 2))))
    except e:
        return _raise(e)


def bench(module: PyObjectPtr, args: Int, nargs: Int) abi("C") -> PyObjectPtr:
    try:
        if nargs != 4:
            raise Error("TypeError: bench(driver, name, args, n) takes 4 arguments")
        var client = DriverClient(_argument(args, 0))
        var target = client.resolve(_name(_argument(args, 1)))
        var values = _values(_argument(args, 2))
        var n = PyLong_AsLong(_argument(args, 3))
        if n <= 0:
            raise Error("TypeError: n must be a positive int")
        var start = perf_counter_ns()
        for _ in range(n):
            _ = client.call(target, values)
        var elapsed = perf_counter_ns() - start
        return PyFloat_FromDouble(Float64(elapsed) / 1e9 / Float64(n))
    except e:
        return _raise(e)


def _name(o: PyObjectPtr) raises -> String:
    var s = string_of(o)
    if s == "?" and PyErr_Occurred():
        raise python_error()
    return s^


def methods() -> Int:
    var table: List[MethodDef] = [
        MethodDef(text("version"), address(version), METH_NOARGS, text("version() -> str")),
        MethodDef(text("echo"), address(echo), METH_O, text("echo(obj): a wire object through a Value and back")),
        MethodDef(text("call"), address(call), METH_FASTCALL, text("call(driver, name, args): resolve name and call it through the driver")),
        MethodDef(text("bench"), address(bench), METH_FASTCALL, text("bench(driver, name, args, n) -> seconds per call")),
        MethodDef(0, 0, 0, 0),
    ]
    return leaked(table^)


@export
def PyInit__host() abi("C") -> PyObjectPtr:
    var definition = unsafe_alloc[ModuleDef](1)
    definition[] = ModuleDef(
        ob_refcnt=1,
        ob_type=0,
        m_init=0,
        m_index=0,
        m_copy=0,
        m_name=text("spectest._host"),
        m_doc=text("The spectest host: Value conversion and the driver client."),
        m_size=0,
        m_methods=methods(),
        m_slots=0,
        m_traverse=0,
        m_clear=0,
        m_free=0,
    )
    return PyModuleDef_Init(Int(definition))
