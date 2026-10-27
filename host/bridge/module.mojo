"""`spectest._host`, the CPython extension module the pytest plugin loads.

Functions for Python (the host's own entry points arrive with later packages):

- `version() -> str`
- `echo(obj)`: a wire object to a Value and back; `TypeError` for anything else.
- `call(driver, name, args)`: resolve `name` through the driver, call it with `args`
  (a list of wire objects) and return the result. The path of a host call.
- `bench(driver, name, args, n) -> float`: seconds per call over `n` calls.
- `load(path, driver) -> int`, `items(spec)`, `run(spec, decl, options)`, `unload(spec)`:
  the runner's API (docs/v2/host-api.md). A spec error raises `spectest.SpecError`
  when that exists, else `ValueError`.

The Mojo API for the other packages is in `bridge.convert` (`to_python`,
`from_python`) and `bridge.client` (`DriverClient`).
"""

from std.ffi import _Global
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
    PyLong_FromSsize_t,
    PyLong_AsLong,
    PyModuleDef_Init,
    PyErr_Clear,
    PyErr_Occurred,
    PyImport_ImportModule,
    PyObject_GetAttrString,
    Py_DecRef,
    PyUnicode_FromStringAndSize,
    address,
    leaked,
    pointer_symbol,
    text,
)
from bridge.client import DriverClient
from bridge.convert import from_python, to_python
from bridge.pyutil import Owned, checked, python_error, string_of, wire

from run.items import items_of
from run.load import Loaded, load as load_spec
from run.pyapi import parse_options, result_to_python
from run.runner import run as run_declaration

comptime VERSION = "0.1.0.dev0"


struct Registry(Movable):
    """The loaded specs and the drivers they run against, by handle."""

    var specs: List[Optional[Loaded]]
    var drivers: List[Optional[DriverClient]]

    def __init__(out self):
        self.specs = List[Optional[Loaded]]()
        self.drivers = List[Optional[DriverClient]]()


def _new_registry() -> Registry:
    return Registry()


comptime _REGISTRY = _Global["spectest_run_registry", _new_registry]


def registry() raises -> Pointer[Registry, MutUntrackedOrigin]:
    return _REGISTRY.get_or_create_ptr()


def _raise(e: Error) -> PyObjectPtr:
    """Sets Python's error from a Mojo error and returns NULL. Errors that start with
    `TypeError: ` are TypeErrors; the rest are RuntimeErrors."""
    var message = String(e)
    var kind = pointer_symbol("PyExc_RuntimeError")
    comptime PREFIX = "TypeError: "
    comptime SPEC = "SpecError: "
    if message.startswith(PREFIX):
        kind = pointer_symbol("PyExc_TypeError")
        var rest = String(message[byte = PREFIX.byte_length() :])
        message = rest^
    elif message.startswith(SPEC):
        kind = _spec_error_class()
        var rest = String(message[byte = SPEC.byte_length() :])
        message = rest^
    var made = PyUnicode_FromStringAndSize(message)
    if made:
        PyErr_SetObject(kind, made)
        Py_DecRef(made)
    return PyObjectPtr()


def _spec_error_class() -> PyObjectPtr:
    """`spectest.SpecError` when the package defines it, else `ValueError`."""
    var module = PyImport_ImportModule("spectest".as_c_string_span())
    if module:
        var found = PyObject_GetAttrString(module, "SpecError".as_c_string_span())
        Py_DecRef(module)
        if found:
            # The module keeps the class alive.
            Py_DecRef(found)
            return found
        PyErr_Clear()
    else:
        PyErr_Clear()
    return pointer_symbol("PyExc_ValueError")


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


def _handle(o: PyObjectPtr) raises -> Int:
    var n = PyLong_AsLong(o)
    var reg = registry()
    if n < 0 or n >= len(reg[].specs) or not reg[].specs[n]:
        raise Error("TypeError: not a loaded spec")
    return n


def load(module: PyObjectPtr, args: Int, nargs: Int) abi("C") -> PyObjectPtr:
    try:
        if nargs != 2:
            raise Error("TypeError: load(path, driver) takes 2 arguments")
        var path = _name(_argument(args, 0))
        var loaded: Loaded
        try:
            loaded = load_spec(path)
        except e:
            raise Error("SpecError: " + String(e))
        var reg = registry()
        reg[].specs.append(Optional(loaded^))
        reg[].drivers.append(Optional(DriverClient(_argument(args, 1))))
        return PyLong_FromSsize_t(len(reg[].specs) - 1)
    except e:
        return _raise(e)


def items(module: PyObjectPtr, spec: PyObjectPtr) abi("C") -> PyObjectPtr:
    try:
        var h = _handle(spec)
        var reg = registry()
        var list = items_of(reg[].specs[h].value())
        return result_to_python(Value.list(list^))
    except e:
        return _raise(e)


def run(module: PyObjectPtr, args: Int, nargs: Int) abi("C") -> PyObjectPtr:
    try:
        if nargs != 3:
            raise Error("TypeError: run(spec, decl, options) takes 3 arguments")
        var h = _handle(_argument(args, 0))
        var decl = _name(_argument(args, 1))
        var options = parse_options(_argument(args, 2))
        var reg = registry()
        var result = run_declaration(
            reg[].specs[h].value(), decl, options, reg[].drivers[h].value()
        )
        return result_to_python(result.to_value())
    except e:
        return _raise(e)


def unload(module: PyObjectPtr, spec: PyObjectPtr) abi("C") -> PyObjectPtr:
    try:
        var h = _handle(spec)
        var reg = registry()
        reg[].specs[h] = None
        reg[].drivers[h] = None
        return Py_NewRef(wire()[].none)
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
        MethodDef(text("load"), address(load), METH_FASTCALL, text("load(path, driver) -> spec handle")),
        MethodDef(text("items"), address(items), METH_O, text("items(spec) -> list of clause dicts")),
        MethodDef(text("run"), address(run), METH_FASTCALL, text("run(spec, decl, options) -> result dict")),
        MethodDef(text("unload"), address(unload), METH_O, text("unload(spec) -> None")),
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
