"""The parts of CPython's C API the module calls.

`external_call` binds each name when Python loads the module, so only functions in
3.11's stable ABI are called that way. Data symbols and other functions are looked up
with `symbol`.

Pointers in structs shared with C are plain Ints (addresses). A call through a C
function pointer takes memory as a pointer with the memory's own origin, or as a `mut`
argument. Otherwise the compiler may drop the store before the call or miss the callee's
write.
"""

from std.ffi import CStringSpan, c_int, external_call
from std.python._cpython import PyObjectPtr
from std.sys.info import CompilationTarget


comptime Py_TPFLAGS_LIST_SUBCLASS: UInt64 = 1 << 25
comptime Py_TPFLAGS_TUPLE_SUBCLASS: UInt64 = 1 << 26
comptime Py_TPFLAGS_UNICODE_SUBCLASS: UInt64 = 1 << 28
comptime Py_TPFLAGS_LONG_SUBCLASS: UInt64 = 1 << 24
comptime Py_TPFLAGS_BYTES_SUBCLASS: UInt64 = 1 << 27

comptime METH_NOARGS: c_int = 0x04
comptime METH_O: c_int = 0x08
comptime METH_FASTCALL: c_int = 0x80


@fieldwise_init
struct MethodDef(TrivialRegisterPassable):
    var name: Int
    var meth: Int
    var flags: c_int
    var doc: Int


@fieldwise_init
struct ModuleDef(TrivialRegisterPassable):
    # PyModuleDef_HEAD_INIT
    var ob_refcnt: Int
    var ob_type: Int
    var m_init: Int
    var m_index: Int
    var m_copy: Int
    var m_name: Int
    var m_doc: Int
    var m_size: Int
    var m_methods: Int
    var m_slots: Int
    var m_traverse: Int
    var m_clear: Int
    var m_free: Int


struct ObjectHead:
    """The start of every object in a non-free-threaded build."""

    var ob_refcnt: Int
    var ob_type: PyObjectPtr


@always_inline
def address[T: TrivialRegisterPassable](function: T) -> Int:
    """The C address of an `abi("C")` function."""
    return Pointer(to=function).unsafe_bitcast[Int]()[]


@always_inline
def text(literal: StaticString) -> Int:
    """A literal's address as a C string (literals end in a NUL)."""
    return Int(literal.unsafe_ptr())


def leaked[T: Copyable & Deinitable](var items: List[T]) -> Int:
    """The address of `items`, which then live as long as the process (as C's
    tables must)."""
    return Int(items.unsafe_take_allocation().unsafe_leak())


def symbol(name: StaticString) -> Int:
    comptime RTLD_DEFAULT: Int = -2 if CompilationTarget.is_macos() else 0
    return external_call["dlsym", Int](RTLD_DEFAULT, name.unsafe_ptr())


def object_symbol(name: StaticString) -> PyObjectPtr:
    """A static object, eg. `_Py_NoneStruct`."""
    return PyObjectPtr(
        upcast_from=Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=symbol(name)
        )
    )


def pointer_symbol(name: StaticString) -> PyObjectPtr:
    """The object a `PyObject *` variable points at, eg. `PyExc_ValueError`."""
    return Pointer[PyObjectPtr, MutUntrackedOrigin](
        unsafe_from_address=symbol(name)
    )[]


@always_inline
def ob_type(o: PyObjectPtr) -> PyObjectPtr:
    return o.bitcast[ObjectHead]().unsafe_value()[].ob_type


@always_inline
def Py_IncRef(o: PyObjectPtr):
    external_call["Py_IncRef", NoneType](o)


@always_inline
def Py_DecRef(o: PyObjectPtr):
    external_call["Py_DecRef", NoneType](o)


@always_inline
def Py_NewRef(o: PyObjectPtr) -> PyObjectPtr:
    Py_IncRef(o)
    return o


@always_inline
def PyLong_FromLongLong(value: Int64) -> PyObjectPtr:
    return external_call["PyLong_FromLongLong", PyObjectPtr](value)


@always_inline
def PyLong_FromUnsignedLongLong(value: UInt64) -> PyObjectPtr:
    return external_call["PyLong_FromUnsignedLongLong", PyObjectPtr](value)


@always_inline
def PyLong_FromSsize_t(value: Int) -> PyObjectPtr:
    return external_call["PyLong_FromSsize_t", PyObjectPtr](value)


@always_inline
def PyLong_AsLongLongAndOverflow(o: PyObjectPtr, mut overflow: c_int) -> Int64:
    return external_call["PyLong_AsLongLongAndOverflow", Int64](
        o, Pointer(to=overflow)
    )


@always_inline
def PyBool_FromLong(value: Bool) -> PyObjectPtr:
    return external_call["PyBool_FromLong", PyObjectPtr](Int(value))


@always_inline
def PyErr_Occurred() -> PyObjectPtr:
    return external_call["PyErr_Occurred", PyObjectPtr]()


@always_inline
def PyErr_SetObject(kind: PyObjectPtr, value: PyObjectPtr):
    external_call["PyErr_SetObject", NoneType](kind, value)


@always_inline
def PyErr_Clear():
    external_call["PyErr_Clear", NoneType]()


@always_inline
def PyUnicode_FromStringAndSize(text: StringSpan) -> PyObjectPtr:
    return external_call["PyUnicode_FromStringAndSize", PyObjectPtr](
        text.unsafe_ptr(), text.byte_length()
    )


@always_inline
def PyUnicode_InternFromString(text: CStringSpan) -> PyObjectPtr:
    return external_call["PyUnicode_InternFromString", PyObjectPtr](text)


@always_inline
def PyUnicode_AsUTF8AndSize(o: PyObjectPtr, mut size: Int) -> Int:
    return external_call["PyUnicode_AsUTF8AndSize", Int](o, Pointer(to=size))


@always_inline
def PyObject_Str(o: PyObjectPtr) -> PyObjectPtr:
    return external_call["PyObject_Str", PyObjectPtr](o)


@always_inline
def PyTuple_New(size: Int) -> PyObjectPtr:
    return external_call["PyTuple_New", PyObjectPtr](size)


@always_inline
def PyTuple_Size(o: PyObjectPtr) -> Int:
    return external_call["PyTuple_Size", Int](o)


@always_inline
def PyTuple_GetItem(o: PyObjectPtr, index: Int) -> PyObjectPtr:
    """Borrowed."""
    return external_call["PyTuple_GetItem", PyObjectPtr](o, index)


@always_inline
def PyTuple_SetItem(o: PyObjectPtr, index: Int, item: PyObjectPtr) -> c_int:
    """Steals `item`."""
    return external_call["PyTuple_SetItem", c_int](o, index, item)


@always_inline
def PyList_New(size: Int) -> PyObjectPtr:
    return external_call["PyList_New", PyObjectPtr](size)


@always_inline
def PyList_SetItem(o: PyObjectPtr, index: Int, item: PyObjectPtr) -> c_int:
    """Steals `item`."""
    return external_call["PyList_SetItem", c_int](o, index, item)


@always_inline
def PyDict_New() -> PyObjectPtr:
    return external_call["PyDict_New", PyObjectPtr]()


@always_inline
def PyDict_SetItemString(
    o: PyObjectPtr, key: CStringSpan, value: PyObjectPtr
) -> c_int:
    return external_call["PyDict_SetItemString", c_int](o, key, value)


@always_inline
def PyDict_Next(
    o: PyObjectPtr,
    mut position: Int,
    mut key: PyObjectPtr,
    mut value: PyObjectPtr,
) -> Bool:
    """Borrows `key` and `value`."""
    return (
        external_call["PyDict_Next", c_int](
            o, Pointer(to=position), Pointer(to=key), Pointer(to=value)
        )
        != 0
    )


@always_inline
def PyObject_GetAttrString(o: PyObjectPtr, name: CStringSpan) -> PyObjectPtr:
    return external_call["PyObject_GetAttrString", PyObjectPtr](o, name)


@always_inline
def PyType_GetFlags(type: PyObjectPtr) -> UInt64:
    return external_call["PyType_GetFlags", UInt64](type)


@always_inline
def PyType_GetQualName(type: PyObjectPtr) -> PyObjectPtr:
    return external_call["PyType_GetQualName", PyObjectPtr](type)


@always_inline
def PyImport_ImportModule(name: CStringSpan) -> PyObjectPtr:
    return external_call["PyImport_ImportModule", PyObjectPtr](name)


@always_inline
def PyModuleDef_Init(definition: Int) -> PyObjectPtr:
    return external_call["PyModuleDef_Init", PyObjectPtr](definition)


@always_inline
def PyBytes_FromStringAndSize(data: Int, size: Int) -> PyObjectPtr:
    return external_call["PyBytes_FromStringAndSize", PyObjectPtr](data, size)


@always_inline
def PyBytes_AsStringAndSize(
    o: PyObjectPtr, mut data: Int, mut size: Int
) -> c_int:
    return external_call["PyBytes_AsStringAndSize", c_int](
        o, Pointer(to=data), Pointer(to=size)
    )


@always_inline
def PyLong_FromString(text: Int, base: c_int) -> PyObjectPtr:
    return external_call["PyLong_FromString", PyObjectPtr](text, 0, base)


@always_inline
def PyLong_AsUnsignedLongLong(o: PyObjectPtr) -> UInt64:
    return external_call["PyLong_AsUnsignedLongLong", UInt64](o)


@always_inline
def PyNumber_ToBase(o: PyObjectPtr, base: c_int) -> PyObjectPtr:
    return external_call["PyNumber_ToBase", PyObjectPtr](o, base)


@always_inline
def PyList_Size(o: PyObjectPtr) -> Int:
    return external_call["PyList_Size", Int](o)


@always_inline
def PyList_GetItem(o: PyObjectPtr, index: Int) -> PyObjectPtr:
    """Borrowed."""
    return external_call["PyList_GetItem", PyObjectPtr](o, index)


@always_inline
def PySequence_Size(o: PyObjectPtr) -> Int:
    return external_call["PySequence_Size", Int](o)


@always_inline
def PySequence_GetItem(o: PyObjectPtr, index: Int) -> PyObjectPtr:
    """A new reference."""
    return external_call["PySequence_GetItem", PyObjectPtr](o, index)


@always_inline
def PyObject_GetAttr(o: PyObjectPtr, name: PyObjectPtr) -> PyObjectPtr:
    return external_call["PyObject_GetAttr", PyObjectPtr](o, name)


@always_inline
def PyObject_Vectorcall(
    callable: PyObjectPtr, args: Int, nargs: Int
) -> PyObjectPtr:
    """`args` is the address of `nargs` object pointers."""
    return external_call["PyObject_Vectorcall", PyObjectPtr](
        callable, args, nargs, PyObjectPtr()
    )


@always_inline
def PyObject_VectorcallMethod(
    name: PyObjectPtr, args: Int, nargs: Int
) -> PyObjectPtr:
    """`args` holds the receiver first, then the arguments."""
    return external_call["PyObject_VectorcallMethod", PyObjectPtr](
        name, args, nargs, PyObjectPtr()
    )


@always_inline
def PyErr_Fetch(
    mut kind: PyObjectPtr, mut value: PyObjectPtr, mut trace: PyObjectPtr
):
    external_call["PyErr_Fetch", NoneType](
        Pointer(to=kind), Pointer(to=value), Pointer(to=trace)
    )


@always_inline
def PyErr_NormalizeException(
    mut kind: PyObjectPtr, mut value: PyObjectPtr, mut trace: PyObjectPtr
):
    external_call["PyErr_NormalizeException", NoneType](
        Pointer(to=kind), Pointer(to=value), Pointer(to=trace)
    )


@always_inline
def PyFloat_FromDouble(value: Float64) -> PyObjectPtr:
    return external_call["PyFloat_FromDouble", PyObjectPtr](value)


@always_inline
def PyLong_AsLong(o: PyObjectPtr) -> Int:
    return external_call["PyLong_AsLong", Int](o)
