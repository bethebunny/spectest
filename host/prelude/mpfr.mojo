"""MPFR through FFI, for `mp.*` and `cr.*`.

The library is the system's `libmpfr.so.6` or, when that is missing, the copy gmpy2
ships in the virtual environment (`site-packages/gmpy2.libs/`). `SPECTEST_MPFR` names a
library to use instead. A `Mpfr` owns the open library and a few `mpfr_t` cells; results
are read back from the cell's limbs, so no GMP integer is needed.
"""

from std.ffi import OwnedDLHandle
from std.os import getenv
from std.pathlib import Path

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.real import Real

comptime RNDN = Int32(0)
comptime CELLS = 4
"""Cell 0 holds the argument, 1 the result, 2 and 3 temporaries."""

comptime SQRT = 0
comptime EXP = 1
comptime LOG = 2
comptime SIN = 3
comptime COS = 4
comptime TAN = 5
comptime ATAN = 6


def _try_open(path: String) -> Optional[OwnedDLHandle]:
    try:
        return OwnedDLHandle(path)
    except:
        return None


def _open_library() raises -> OwnedDLHandle:
    var override = getenv("SPECTEST_MPFR")
    if override:
        return OwnedDLHandle(override)
    var system = _try_open("libmpfr.so.6")
    if system:
        return system.take()
    var roots = List[String]()
    var venv = getenv("VIRTUAL_ENV")
    if venv:
        roots.append(venv)
    roots.append(".venv")
    roots.append("../.venv")
    for root in roots:
        for python in ["3.10", "3.11", "3.12", "3.13", "3.14"]:
            var dir = Path(root) / "lib" / ("python" + python) / "site-packages" / "gmpy2.libs"
            try:
                for name in dir.listdir():
                    var text = String(name)
                    if text.startswith("libmpfr"):
                        return OwnedDLHandle(String(dir / name))
            except:
                pass
    raise Error("mpfr: cannot load libmpfr.so.6 or the copy shipped with gmpy2")


struct Mpfr(Movable):
    var lib: OwnedDLHandle
    var cells: List[Int]
    var emin: Int
    var emax: Int

    def __init__(out self) raises:
        self.lib = _open_library()
        self.cells = List[Int](length=4 * CELLS, fill=0)
        self.emin = Int(self.lib.call["mpfr_get_emin", Int](()))
        self.emax = Int(self.lib.call["mpfr_get_emax", Int](()))
        for i in range(CELLS):
            self.lib.call["mpfr_init2"](self.addr(i), 64)

    def __del__(deinit self):
        for i in range(CELLS):
            self.lib.call["mpfr_clear"](Int(self.cells.unsafe_ptr()) + 32 * i)
        _ = self.lib.call["mpfr_set_emin", Int32](self.emin)
        _ = self.lib.call["mpfr_set_emax", Int32](self.emax)

    def addr(self, cell: Int) -> Int:
        return Int(self.cells.unsafe_ptr()) + 32 * cell

    def set_precision(self, cell: Int, prec: Int):
        self.lib.call["mpfr_set_prec"](self.addr(cell), prec)

    def set_range(self, emin: Int, emax: Int):
        _ = self.lib.call["mpfr_set_emin", Int32](emin)
        _ = self.lib.call["mpfr_set_emax", Int32](emax)

    def clear_flags(self):
        self.lib.call["mpfr_clear_flags"](())

    def overflowed(self) -> Bool:
        return self.lib.call["mpfr_overflow_p", Int32](()) != 0

    def underflowed(self) -> Bool:
        return self.lib.call["mpfr_underflow_p", Int32](()) != 0

    # Setting a cell

    def set_double(self, cell: Int, x: Float64):
        _ = self.lib.call["mpfr_set_d", Int32](self.addr(cell), x, RNDN)

    def set_infinity(self, cell: Int, negative: Bool):
        self.lib.call["mpfr_set_inf"](self.addr(cell), Int32(-1 if negative else 1))

    def _set_exact_integer(self, cell: Int, value: BigInt) -> Bool:
        """Sets the cell, whose precision is raised to hold the value exactly."""
        self.set_precision(cell, max(value.bit_length(), 8))
        var text = BigInt(negative=False, magnitude=value.magnitude.copy()).hex()
        var cstr = text + "\0"
        var status = self.lib.call["mpfr_set_str", Int32](
            self.addr(cell), Int(cstr.unsafe_ptr()), Int32(16), RNDN
        )
        if value.negative:
            _ = self.lib.call["mpfr_neg", Int32](self.addr(cell), self.addr(cell), RNDN)
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
            _ = self.lib.call["mpfr_set", Int32](self.addr(cell), self.addr(2), RNDN)
            return
        var prec = self.precision(cell)
        _ = self._set_exact_integer(2, r.numerator)
        _ = self._set_exact_integer(3, r.denominator)
        self.set_precision(cell, prec)
        _ = self.lib.call["mpfr_div", Int32](self.addr(cell), self.addr(2), self.addr(3), RNDN)

    # Reading a cell

    def precision(self, cell: Int) -> Int:
        return self.cells[4 * cell]

    def is_nan(self, cell: Int) -> Bool:
        return self.lib.call["mpfr_nan_p", Int32](self.addr(cell)) != 0

    def is_inf(self, cell: Int) -> Bool:
        return self.lib.call["mpfr_inf_p", Int32](self.addr(cell)) != 0

    def is_zero(self, cell: Int) -> Bool:
        return self.lib.call["mpfr_zero_p", Int32](self.addr(cell)) != 0

    def negative(self, cell: Int) -> Bool:
        return self.lib.call["mpfr_signbit", Int32](self.addr(cell)) != 0

    def to_real(self, cell: Int) -> Real:
        """The exact value of a finite cell: limbs times a power of two."""
        if self.is_zero(cell):
            return Real()
        var prec = self.cells[4 * cell]
        var exp = self.cells[4 * cell + 2]
        var limbs = (prec + 63) // 64
        var ptr = UnsafePointer[UInt64, MutAnyOrigin](unsafe_from_address=self.cells[4 * cell + 3])
        var magnitude = BigUInt(UInt64(0))
        for k in range(limbs - 1, -1, -1):
            magnitude = (magnitude << 64) | BigUInt(ptr[k])
        var shift = exp - 64 * limbs
        var one = BigUInt(UInt64(1))
        if shift >= 0:
            return Real.ratio(self.negative(cell), magnitude << shift, one^)
        return Real.ratio(self.negative(cell), magnitude^, one << (-shift))

    # Operations

    def apply(self, which: Int, rop: Int, op: Int) -> Int32:
        """rop = f(op) at the precision of rop, rounded to nearest; the ternary value."""
        var r = self.addr(rop)
        var x = self.addr(op)
        if which == SQRT:
            return self.lib.call["mpfr_sqrt", Int32](r, x, RNDN)
        if which == EXP:
            return self.lib.call["mpfr_exp", Int32](r, x, RNDN)
        if which == LOG:
            return self.lib.call["mpfr_log", Int32](r, x, RNDN)
        if which == SIN:
            return self.lib.call["mpfr_sin", Int32](r, x, RNDN)
        if which == COS:
            return self.lib.call["mpfr_cos", Int32](r, x, RNDN)
        if which == TAN:
            return self.lib.call["mpfr_tan", Int32](r, x, RNDN)
        return self.lib.call["mpfr_atan", Int32](r, x, RNDN)

    def subnormalize(self, cell: Int, ternary: Int32):
        _ = self.lib.call["mpfr_subnormalize", Int32](self.addr(cell), ternary, RNDN)
