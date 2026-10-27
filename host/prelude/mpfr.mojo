"""MPFR through FFI, for `mp.*` and `cr.*`.

The library is the system's `libmpfr.so.6` or, when that is missing, the copy gmpy2
ships in the virtual environment (`site-packages/gmpy2.libs/`). `SPECTEST_MPFR` names a
library to use instead. A `Mpfr` owns the open library and a few `mpfr_t` cells; results
are read back from the cell's limbs, so no GMP integer is needed.
"""

from std.ffi import OwnedDLHandle, _Global
from std.os import getenv
from std.pathlib import Path

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.real import Real

comptime RNDN = Int32(0)
comptime CELLS = 4
"""Cell 0 holds the argument, 1 the result, 2 and 3 temporaries."""


def _try_open(path: String) -> Optional[OwnedDLHandle]:
    try:
        return OwnedDLHandle(path)
    except:
        return None


def bundled_library() -> Optional[String]:
    """The path of the MPFR copy gmpy2 ships in the virtual environment, if there is one."""
    var roots: List[String] = [".venv", "../.venv"]
    var venv = getenv("VIRTUAL_ENV")
    if venv:
        roots.insert(0, venv)
    for root in roots:
        for python in ["3.10", "3.11", "3.12", "3.13", "3.14"]:
            var dir = Path(root) / "lib" / ("python" + python) / "site-packages" / "gmpy2.libs"
            try:
                for name in dir.listdir():
                    if String(name).startswith("libmpfr"):
                        return String(dir / name)
            except:
                pass
    return None


def _open_library() raises -> OwnedDLHandle:
    var override = getenv("SPECTEST_MPFR")
    if override:
        return OwnedDLHandle(override)
    var system = _try_open("libmpfr.so.6")
    if system is not None:
        return system.take()
    var bundled = bundled_library()
    if bundled is not None:
        return OwnedDLHandle(bundled.value())
    raise Error("mpfr: cannot load libmpfr.so.6 or the copy shipped with gmpy2")


struct Library(Movable):
    """The open MPFR library, kept for the life of the process: opening it costs far
    more than a call."""

    var handle: Optional[OwnedDLHandle]
    var error: String

    def __init__(out self):
        self.handle = None
        self.error = String()
        try:
            self.handle = _open_library()
        except e:
            self.error = String(e)


def _new_library() -> Library:
    return Library()


comptime _LIBRARY = _Global["spectest_prelude_mpfr", _new_library]


struct Mpfr(Movable):
    var lib: Pointer[Library, MutUntrackedOrigin]
    var cells: List[Int]
    var emin: Int
    var emax: Int

    def __init__(out self) raises:
        self.lib = _LIBRARY.get_or_create_ptr()
        if self.lib[].handle is None:
            raise Error(self.lib[].error)
        self.cells = List[Int](length=4 * CELLS, fill=0)
        self.emin = Int(self.lib[].handle.value().call["mpfr_get_emin", Int](()))
        self.emax = Int(self.lib[].handle.value().call["mpfr_get_emax", Int](()))
        for i in range(CELLS):
            self.lib[].handle.value().call["mpfr_init2"](self.addr(i), 64)

    def __deinit__(deinit self):
        for i in range(CELLS):
            self.lib[].handle.value().call["mpfr_clear"](Int(self.cells.unsafe_ptr()) + 32 * i)
        _ = self.lib[].handle.value().call["mpfr_set_emin", Int32](self.emin)
        _ = self.lib[].handle.value().call["mpfr_set_emax", Int32](self.emax)

    def addr(self, cell: Int) -> Int:
        return Int(self.cells.unsafe_ptr()) + 32 * cell

    def set_precision(self, cell: Int, prec: Int):
        self.lib[].handle.value().call["mpfr_set_prec"](self.addr(cell), prec)

    def set_range(self, emin: Int, emax: Int):
        _ = self.lib[].handle.value().call["mpfr_set_emin", Int32](emin)
        _ = self.lib[].handle.value().call["mpfr_set_emax", Int32](emax)

    def clear_flags(self):
        self.lib[].handle.value().call["mpfr_clear_flags"](())

    def overflowed(self) -> Bool:
        return self.lib[].handle.value().call["mpfr_overflow_p", Int32](()) != 0

    def underflowed(self) -> Bool:
        return self.lib[].handle.value().call["mpfr_underflow_p", Int32](()) != 0

    # Setting a cell

    def set_double(self, cell: Int, x: Float64):
        _ = self.lib[].handle.value().call["mpfr_set_d", Int32](self.addr(cell), x, RNDN)

    def set_infinity(self, cell: Int, negative: Bool):
        self.lib[].handle.value().call["mpfr_set_inf"](self.addr(cell), Int32(-1 if negative else 1))

    def _set_exact_integer(self, cell: Int, value: BigInt) -> Bool:
        """Sets the cell, whose precision is raised to hold the value exactly."""
        self.set_precision(cell, max(value.bit_length(), 8))
        var text = BigInt(negative=False, magnitude=value.magnitude.copy()).hex()
        var cstr = text + "\0"
        var status = self.lib[].handle.value().call["mpfr_set_str", Int32](
            self.addr(cell), Int(cstr.unsafe_ptr()), Int32(16), RNDN
        )
        if value.negative:
            _ = self.lib[].handle.value().call["mpfr_neg", Int32](self.addr(cell), self.addr(cell), RNDN)
        return status == 0

    def set_real(self, cell: Int, r: Real):
        """The real at the cell's precision, rounded to nearest when not exact."""
        if r.is_inf():
            self.set_infinity(cell, r.numerator.negative)
            return
        if r.denominator == BigInt(1):
            var prec = self.precision(cell)
            _ = self._set_exact_integer(2, r.numerator)
            self.set_precision(cell, prec)
            _ = self.lib[].handle.value().call["mpfr_set", Int32](self.addr(cell), self.addr(2), RNDN)
            return
        var prec = self.precision(cell)
        _ = self._set_exact_integer(2, r.numerator)
        _ = self._set_exact_integer(3, r.denominator)
        self.set_precision(cell, prec)
        _ = self.lib[].handle.value().call["mpfr_div", Int32](self.addr(cell), self.addr(2), self.addr(3), RNDN)

    # Reading a cell

    def precision(self, cell: Int) -> Int:
        return self.cells[4 * cell]

    def is_nan(self, cell: Int) -> Bool:
        return self.lib[].handle.value().call["mpfr_nan_p", Int32](self.addr(cell)) != 0

    def is_inf(self, cell: Int) -> Bool:
        return self.lib[].handle.value().call["mpfr_inf_p", Int32](self.addr(cell)) != 0

    def is_zero(self, cell: Int) -> Bool:
        return self.lib[].handle.value().call["mpfr_zero_p", Int32](self.addr(cell)) != 0

    def negative(self, cell: Int) -> Bool:
        return self.lib[].handle.value().call["mpfr_signbit", Int32](self.addr(cell)) != 0

    def to_real(self, cell: Int) -> Real:
        """The exact value of a finite cell: limbs times a power of two."""
        if self.is_zero(cell):
            return Real()
        var prec = self.precision(cell)
        var exp = self.cells[4 * cell + 2]
        var limbs = (prec + 63) // 64
        var ptr = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=self.cells[4 * cell + 3])
        var magnitude = BigUInt(UInt64(0))
        for k in range(limbs - 1, -1, -1):
            magnitude = (magnitude << 64) | BigUInt(ptr[unsafe_offset=k])
        # dropping trailing zero bits leaves an odd numerator, so the power of two is in lowest terms
        var zeros = 0
        while not magnitude.bit(zeros):
            zeros += 1
        magnitude = magnitude >> zeros
        var shift = exp - 64 * limbs + zeros
        var numerator = BigInt(negative=self.negative(cell), magnitude=magnitude^)
        var one = BigUInt(UInt64(1))
        if shift >= 0:
            return Real(
                lowest_numerator=BigInt(negative=numerator.negative, magnitude=numerator.magnitude << shift),
                lowest_denominator=BigInt(1),
            )
        return Real(lowest_numerator=numerator^, lowest_denominator=BigInt(negative=False, magnitude=one << (-shift)))

    # Operations

    def apply(self, function: String, rop: Int, op: Int) -> Int32:
        """rop = function(op) at the precision of rop, rounded to nearest (the ternary value)."""
        var r = self.addr(rop)
        var x = self.addr(op)
        ref lib = self.lib[].handle.value()
        match function:
            case "sqrt":
                return lib.call["mpfr_sqrt", Int32](r, x, RNDN)
            case "exp":
                return lib.call["mpfr_exp", Int32](r, x, RNDN)
            case "log":
                return lib.call["mpfr_log", Int32](r, x, RNDN)
            case "sin":
                return lib.call["mpfr_sin", Int32](r, x, RNDN)
            case "cos":
                return lib.call["mpfr_cos", Int32](r, x, RNDN)
            case "tan":
                return lib.call["mpfr_tan", Int32](r, x, RNDN)
            case _:
                return lib.call["mpfr_atan", Int32](r, x, RNDN)

    def subnormalize(self, cell: Int, ternary: Int32):
        _ = self.lib[].handle.value().call["mpfr_subnormalize", Int32](self.addr(cell), ternary, RNDN)
