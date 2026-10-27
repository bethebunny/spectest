"""Signed integers of any size: spec `int`, and every fixed-width integer once promoted.

A `BigInt` is a sign and a magnitude, bitpattern's `BigUInt`. The form is canonical
(zero is never negative), so structural equality is numeric equality.
"""

from std.hash import Hasher

from bigint import BigUInt

from numeric.digits import digit_value, hex_digits, magnitude_of_digits


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
        var magnitude = self.magnitude.uint64_or_none()
        if magnitude is None:
            return None
        var u = magnitude.value()
        if self.negative:
            return Int64(0) - Int64(u - 1) - 1 if u <= UInt64(1) << 63 else None
        return Int64(u) if u < UInt64(1) << 63 else None

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
        var negative = text.startswith("-")
        var unsigned = text[byte=1:] if negative else text
        var hex = unsigned.startswith("0x") or unsigned.startswith("0X")
        var body = String(unsigned[byte=2:] if hex else unsigned).replace("_", "")
        var digits = [digit_value(Int(c), hex=hex) for c in body.as_bytes()]
        if len(digits) == 0 or -1 in digits:
            raise Error(t"not an integer: {text}")
        var magnitude = magnitude_of_digits(digits, base=16 if hex else 10)
        return Self(negative=negative, magnitude=magnitude^)

    def write_to(self, mut writer: Some[Writer]):
        """Decimal, as Python prints an int."""
        if not self.magnitude:
            writer.write("0")
            return
        # Base 10**19 chunks, least significant first.
        var chunks: List[UInt64] = []
        var rest = self.magnitude.copy()
        var ten19 = BigUInt(_TEN19)
        while rest:
            chunks.append((rest % ten19).limb(0))
            rest = rest // ten19
        if self.negative:
            writer.write("-")
        writer.write(chunks.pop())
        for chunk in reversed(chunks):
            var digits = String(chunk)
            writer.write("0" * (19 - digits.byte_length()), digits)

    def hex(self) -> String:
        """`0x`-prefixed lowercase hexadecimal, `-0x...` when negative."""
        var digits = String()
        for k in range(len(self.magnitude.limbs) - 1, -1, -1):
            digits += hex_digits(self.magnitude.limb(k), width=16)
        var trimmed = digits.lstrip("0")
        var unsigned = String(trimmed) if trimmed.byte_length() > 0 else "0"
        return String("-" if self.negative else "", "0x", unsigned)
