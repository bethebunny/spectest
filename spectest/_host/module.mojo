"""`spectest._host`, the CPython extension module the pytest plugin loads.

Functions:

  - `version() -> str`
  - `echo(obj)` (a wire object to a Value and back; eg. `TypeError` for anything else)
  - `call(driver, name, args)` (resolves `name` through the driver and calls it with a
    list of wire objects)
  - `bench(driver, name, args, n) -> float` (seconds per call)
  - `load(path, driver) -> int`, `items(spec)`, `run(spec, decl, options)`,
    `unload(spec)` (the runner's API, docs/v2/host-api.md)

A spec error raises `spectest.SpecError` when that exists, else `ValueError`.
"""

from std.ffi import _Global, c_int
from std.memory.alloc import unsafe_alloc
from std.python._cpython import (
    METH_FASTCALL,
    PyMethodDef,
    PyModuleDef,
    PyObjectPtr,
    _fn_ptr_as_opaque,
)
from std.time import perf_counter_ns

from host.items import items_of
from host.load import Loaded, load as load_spec
from host.stateful import run_declaration
from value.value import Value

from _host.capi import (
    METH_NOARGS,
    METH_O,
    Py_DecRef,
    Py_NewRef,
    PyErr_Clear,
    PyErr_SetObject,
    PyFloat_FromDouble,
    PyImport_ImportModule,
    PyLong_AsLong,
    PyLong_FromSsize_t,
    PyModuleDef_Init,
    PyObject_GetAttrString,
    PyUnicode_FromStringAndSize,
    pointer_symbol,
)
from _host.client import DriverClient
from _host.convert import from_python, to_python
from _host.pyapi import parse_options, result_to_python
from _host.pyutil import string_of, wire

comptime VERSION = "0.1.0.dev0"

comptime Arguments = Span[PyObjectPtr, MutUntrackedOrigin]
"""A METH_FASTCALL function's arguments (borrowed)."""


@fieldwise_init
struct Session(Movable):
    """A loaded spec and the driver it runs against."""

    var loaded: Loaded
    var driver: DriverClient


def _no_sessions() -> List[Optional[Session]]:
    return []


comptime _SESSIONS = _Global["spectest_bridge_sessions", _no_sessions]


def _sessions() raises -> Pointer[List[Optional[Session]], MutUntrackedOrigin]:
    """The sessions by handle. An unloaded one leaves None, so later handles keep
    their place."""
    return _SESSIONS.get_or_create_ptr()


def _slot(spec: PyObjectPtr) raises -> ref [MutUntrackedOrigin] Optional[Session]:
    var handle = PyLong_AsLong(spec)
    var sessions = _sessions()
    if handle < 0 or handle >= len(sessions[]) or sessions[][handle] is None:
        raise Error("TypeError: not a loaded spec")
    return sessions[][handle]


def _raise(e: Error) -> PyObjectPtr:
    """Sets Python's error from a Mojo error and returns NULL. The prefixes `TypeError: `
    and `SpecError: ` pick the class (RuntimeError otherwise)."""
    var message = String(e)
    comptime TYPE = "TypeError: "
    comptime SPEC = "SpecError: "
    if message.startswith(TYPE):
        return _raise(pointer_symbol("PyExc_TypeError"), message.removeprefix(TYPE))
    if message.startswith(SPEC):
        return _raise(_spec_error_class(), message.removeprefix(SPEC))
    return _raise(pointer_symbol("PyExc_RuntimeError"), message)


def _raise(kind: PyObjectPtr, message: StringSpan) -> PyObjectPtr:
    var text = PyUnicode_FromStringAndSize(message)
    if text:
        PyErr_SetObject(kind, text)
        Py_DecRef(text)
    return PyObjectPtr()


def _spec_error_class() -> PyObjectPtr:
    """`spectest.SpecError` when the package defines it, else `ValueError`."""
    var module = PyImport_ImportModule("spectest".as_c_string_span())
    var found = PyObject_GetAttrString(module, "SpecError".as_c_string_span()) if module else module
    Py_DecRef(module)
    if found:
        Py_DecRef(found)  # the module keeps the class alive
        return found
    PyErr_Clear()
    return pointer_symbol("PyExc_ValueError")


def _fastcall[
    function: def(Arguments) thin raises -> PyObjectPtr,
    signature: StaticString,
    arity: Int,
](
    module: PyObjectPtr, args: Pointer[PyObjectPtr, MutUntrackedOrigin], nargs: Int
) abi("C") -> PyObjectPtr:
    try:
        if nargs != arity:
            raise Error(t"TypeError: {signature} takes {arity} arguments")
        return function(Arguments(unsafe_ptr=args, length=nargs))
    except e:
        return _raise(e)


def _one_argument[
    function: def(PyObjectPtr) thin raises -> PyObjectPtr
](module: PyObjectPtr, obj: PyObjectPtr) abi("C") -> PyObjectPtr:
    try:
        return function(obj)
    except e:
        return _raise(e)


def _values(list: PyObjectPtr) raises -> List[Value]:
    var value = from_python(list)
    if value.kind != .LIST:
        raise Error("TypeError: args must be a list of wire objects")
    return value.items()


def version(module: PyObjectPtr, unused: PyObjectPtr) abi("C") -> PyObjectPtr:
    return PyUnicode_FromStringAndSize(VERSION)


def echo(obj: PyObjectPtr) raises -> PyObjectPtr:
    return to_python(from_python(obj))


def call(args: Arguments) raises -> PyObjectPtr:
    var client = DriverClient(args[0])
    var target = client.resolve(string_of(args[1]))
    return to_python(client.call(target, _values(args[2])))


def bench(args: Arguments) raises -> PyObjectPtr:
    var client = DriverClient(args[0])
    var target = client.resolve(string_of(args[1]))
    var values = _values(args[2])
    var n = PyLong_AsLong(args[3])
    if n <= 0:
        raise Error("TypeError: n must be a positive int")
    var start = perf_counter_ns()
    for _ in range(n):
        _ = client.call(target, values)
    var elapsed = perf_counter_ns() - start
    return PyFloat_FromDouble(Float64(elapsed) / 1e9 / Float64(n))


def load(args: Arguments) raises -> PyObjectPtr:
    var path = string_of(args[0])
    var loaded: Loaded
    try:
        loaded = load_spec(path)
    except e:
        raise Error(t"SpecError: {e}")
    var sessions = _sessions()
    sessions[].append(Session(loaded^, DriverClient(args[1])))
    return PyLong_FromSsize_t(len(sessions[]) - 1)


def items(spec: PyObjectPtr) raises -> PyObjectPtr:
    return result_to_python(Value.list(items_of(_slot(spec).value().loaded)))


def run(args: Arguments) raises -> PyObjectPtr:
    ref session = _slot(args[0]).value()
    var decl = string_of(args[1])
    var options = parse_options(args[2])
    var result = run_declaration(session.loaded, decl, options, session.driver)
    return result_to_python(result.to_value())


def unload(spec: PyObjectPtr) raises -> PyObjectPtr:
    _slot(spec) = None
    return Py_NewRef(wire()[].none)


def _method[
    T: TrivialRegisterPassable
](name: StaticString, function: T, flags: c_int, doc: StaticString) -> PyMethodDef:
    return PyMethodDef(
        name.as_c_string_span(), _fn_ptr_as_opaque(function), flags, doc.as_c_string_span()
    )


def _methods() -> OptionalPointer[PyMethodDef, MutUntrackedOrigin]:
    """The module's functions, in a table that lives as long as the process (as C's
    tables must)."""
    var table: List[PyMethodDef] = [
        _method("version", version, METH_NOARGS, "version() -> str"),
        _method("echo", _one_argument[echo], METH_O, "echo(obj): a wire object through a Value and back"),
        _method("call", _fastcall[call, "call(driver, name, args)", 3], METH_FASTCALL, "call(driver, name, args): resolve name and call it through the driver"),
        _method("bench", _fastcall[bench, "bench(driver, name, args, n)", 4], METH_FASTCALL, "bench(driver, name, args, n) -> seconds per call"),
        _method("load", _fastcall[load, "load(path, driver)", 2], METH_FASTCALL, "load(path, driver) -> spec handle"),
        _method("items", _one_argument[items], METH_O, "items(spec) -> list of clause dicts"),
        _method("run", _fastcall[run, "run(spec, decl, options)", 3], METH_FASTCALL, "run(spec, decl, options) -> result dict"),
        _method("unload", _one_argument[unload], METH_O, "unload(spec) -> None"),
        PyMethodDef(),
    ]
    return table.unsafe_take_allocation().unsafe_leak()


@export
def PyInit__host() abi("C") -> PyObjectPtr:
    var definition = unsafe_alloc[PyModuleDef](1)  # C reads it as long as the process lives
    definition.unsafe_write(PyModuleDef("spectest._host"))
    definition[].base.object_base.object_ref_count = 1  # as PyModuleDef_HEAD_INIT sets it
    definition[].docstring = "The spectest host: Value conversion and the driver client.".as_c_string_span()
    definition[].size = 0
    definition[].methods = _methods()
    return PyModuleDef_Init(definition)
