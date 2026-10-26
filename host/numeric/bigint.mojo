"""Signed integers of any size: spec `int`, and every fixed-width integer once promoted.

A `BigInt` is a sign and a magnitude, bitpattern's `BigUInt`. The form is canonical
(zero is never negative), so structural equality is numeric equality.
"""

from std.hash import Hasher

from bigint import BigUInt


comptime _TEN19 = UInt64(10_000_000_000_000_000_000)


struct BigInt(Comparable, Copyable, Defaultable, Hashable, Movable, Writable):
    var negative: Bool
    """Never set on zero."""
    var magnitude: BigUInt

    def __init__(out self):
        self.negative = False
        self.magnitude = BigUInt()

    @implicit
    def __init__(out self, value: Int):
        self.negative = value < 0
        if value >= 0:
            self.magnitude = BigUInt(UInt64(value))
        else:
            # -Int.MIN overflows Int, but not UInt64.
            self.magnitude = BigUInt(UInt64(~value) + 1)

    def __init__(out self, value: UInt64):
        self.negative = False
        self.magnitude = BigUInt(value)

    def __init__(out self, *, negative: Bool, var magnitude: BigUInt):
        self.negative = negative and Bool(magnitude)
        self.magnitude = magnitude^

    # Queries

    def __bool__(self) -> Bool:
        return Bool(self.magnitude)

    def is_zero(self) -> Bool:
        return not self.magnitude

    def sign(self) -> Int:
        """-1, 0 or 1."""
        if not self.magnitude:
            return 0
        return -1 if self.negative else 1

    def int64_or_none(self) -> Optional[Int64]:
        var m = self.magnitude.uint64_or_none()
        if not m:
            return None
        var u = m.value()
        if self.negative:
            if u > (UInt64(1) << 63):
                return None
            return Int64(0) - Int64(u - 1) - 1
        if u >= (UInt64(1) << 63):
            return None
        return Int64(u)

    def bit_length(self) -> Int:
        """Bits of the magnitude, as Python's `int.bit_length`."""
        return self.magnitude.bits()

    # Comparisons

    def __eq__(self, rhs: Self) -> Bool:
        return self.negative == rhs.negative and self.magnitude == rhs.magnitude

    def __lt__(self, rhs: Self) -> Bool:
        if self.negative != rhs.negative:
            return self.negative
        if self.negative:
            return rhs.magnitude < self.magnitude
        return self.magnitude < rhs.magnitude

    def __hash__(self, mut hasher: Some[Hasher]):
        self.negative.__hash__(hasher)
        self.magnitude.__hash__(hasher)

    # Arithmetic

    def __neg__(self) -> Self:
        return Self(negative=not self.negative, magnitude=self.magnitude.copy())

    def __abs__(self) -> Self:
        return Self(negative=False, magnitude=self.magnitude.copy())

    def __add__(self, rhs: Self) -> Self:
        if self.negative == rhs.negative:
            return Self(negative=self.negative, magnitude=self.magnitude + rhs.magnitude)
        # Opposite signs: the larger magnitude keeps its sign.
        if self.magnitude < rhs.magnitude:
            return Self(negative=rhs.negative, magnitude=rhs.magnitude - self.magnitude)
        return Self(negative=self.negative, magnitude=self.magnitude - rhs.magnitude)

    def __sub__(self, rhs: Self) -> Self:
        return self + (-rhs)

    def __mul__(self, rhs: Self) -> Self:
        return Self(
            negative=self.negative != rhs.negative,
            magnitude=self.magnitude * rhs.magnitude,
        )

    def divmod(self, divisor: Self) raises -> Tuple[Self, Self]:
        """Floored division, as Python's: the remainder takes the divisor's sign."""
        if not divisor:
            raise Error("division by zero")
        var q = self.magnitude // divisor.magnitude
        var r = self.magnitude % divisor.magnitude
        var quotient = Self(negative=self.negative != divisor.negative, magnitude=q^)
        var remainder = Self(negative=self.negative, magnitude=r^)
        if remainder and remainder.negative != divisor.negative:
            quotient = quotient - Self(1)
            remainder = remainder + divisor
        return (quotient^, remainder^)

    def __floordiv__(self, divisor: Self) raises -> Self:
        return self.divmod(divisor)[0].copy()

    def __mod__(self, divisor: Self) raises -> Self:
        return self.divmod(divisor)[1].copy()

    def __lshift__(self, shift: Int) -> Self:
        return Self(negative=self.negative, magnitude=self.magnitude << shift)

    # Text

    @staticmethod
    def parse(text: StringSlice) raises -> Self:
        """Decimal digits with an optional leading `-`; `_` may separate digits.
        `0x` introduces hexadecimal digits."""
        var bytes = text.as_bytes()
        var i = 0
        var negative = False
        if i < len(bytes) and Int(bytes[i]) == ord("-"):
            negative = True
            i += 1
        var base = UInt64(10)
        if i + 1 < len(bytes) and Int(bytes[i]) == ord("0") and (
            Int(bytes[i + 1]) == ord("x") or Int(bytes[i + 1]) == ord("X")
        ):
            base = 16
            i += 2
        var magnitude = BigUInt()
        var digits = 0
        var big_base = BigUInt(base)
        while i < len(bytes):
            var c = Int(bytes[i])
            i += 1
            if c == ord("_"):
                continue
            var d: Int
            if ord("0") <= c <= ord("9"):
                d = c - ord("0")
            elif base == 16 and ord("a") <= c <= ord("f"):
                d = c - ord("a") + 10
            elif base == 16 and ord("A") <= c <= ord("F"):
                d = c - ord("A") + 10
            else:
                raise Error("not an integer: " + String(text))
            magnitude = magnitude * big_base + BigUInt(UInt64(d))
            digits += 1
        if digits == 0:
            raise Error("not an integer: " + String(text))
        return Self(negative=negative, magnitude=magnitude^)

    def write_to(self, mut writer: Some[Writer]):
        """Decimal, as Python prints an int."""
        if not self.magnitude:
            writer.write("0")
            return
        # Base 10**19 chunks, least significant first.
        var chunks = List[UInt64]()
        var rest = self.magnitude.copy()
        var ten19 = BigUInt(_TEN19)
        while rest:
            chunks.append((rest % ten19).limb(0))
            rest = rest // ten19
        if self.negative:
            writer.write("-")
        writer.write(chunks[len(chunks) - 1])
        for k in range(len(chunks) - 2, -1, -1):
            var digits = String(chunks[k])
            for _ in range(19 - digits.byte_length()):
                writer.write("0")
            writer.write(digits)

    def hex(self) -> String:
        """`0x`-prefixed lowercase hexadecimal, `-0x...` when negative."""
        var out = String("-0x" if self.negative else "0x")
        var n = len(self.magnitude.limbs)
        if n == 0:
            return out + "0"
        comptime DIGITS = "0123456789abcdef"
        var started = False
        for k in range(n - 1, -1, -1):
            var limb = self.magnitude.limb(k)
            for shift in range(60, -4, -4):
                var d = Int((limb >> UInt64(shift)) & 15)
                if d or started:
                    started = True
                    out += String(DIGITS[byte=d])
        return out
