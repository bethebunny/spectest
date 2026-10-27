"""Extended reals: exact rationals in lowest terms, plus positive and negative infinity.

The denominator is positive for a finite real. An infinity has denominator 0 and
numerator 1 or -1. The numerator and denominator are what `Value.real` stores.
"""

from bigint import BigUInt

from numeric.bigint import BigInt
from numeric.decimal import gcd, trailing_zeros


struct Real(Absable, Comparable, Copyable, Defaultable, Movable, Writable):
    var numerator: BigInt
    var denominator: BigInt

    def __init__(out self):
        self = Self(0)

    @implicit
    def __init__(out self, value: Int):
        self = Self(BigInt(value))

    @implicit
    def __init__(out self, var value: BigInt):
        self.numerator = value^
        self.denominator = BigInt(1)

    def __init__(out self, var numerator: BigInt, var denominator: BigInt) raises:
        """`numerator / denominator` in lowest terms."""
        if denominator.is_zero():
            raise Error("division by zero")
        self = Self.ratio(
            numerator.negative != denominator.negative,
            numerator.magnitude.copy(),
            denominator.magnitude.copy(),
        )

    def __init__(out self, *, lowest_numerator: BigInt, lowest_denominator: BigInt):
        """The caller guarantees lowest terms and a positive denominator."""
        self.numerator = lowest_numerator.copy()
        self.denominator = lowest_denominator.copy()

    @staticmethod
    def ratio(negative: Bool, var n: BigUInt, var d: BigUInt) -> Self:
        """The real `±n / d`; `d` must be nonzero."""
        if not n:
            return Self()
        if d != 1:
            var g = gcd(n.copy(), d.copy())
            if g != 1:
                n = n // g
                d = d // g
        return Self(
            lowest_numerator=BigInt(negative=negative, magnitude=n^),
            lowest_denominator=BigInt(negative=False, magnitude=d^),
        )

    @staticmethod
    def dyadic(negative: Bool, m: BigUInt, q: Int) -> Self:
        """The real `±m * 2**q`."""
        if not m:
            return Self()
        # An odd m puts the ratio in lowest terms.
        var zeros = trailing_zeros(m)
        var odd = m >> zeros
        var e = q + zeros
        return Self(
            lowest_numerator=BigInt(negative=negative, magnitude=odd << e if e > 0 else odd^),
            lowest_denominator=BigInt(negative=False, magnitude=BigUInt(1) << max(-e, 0)),
        )

    @staticmethod
    def infinity(negative: Bool = False) -> Self:
        return Self(
            lowest_numerator=BigInt(-1 if negative else 1),
            lowest_denominator=BigInt(),
        )

    def is_inf(self) -> Bool:
        return self.denominator.is_zero()

    def is_finite(self) -> Bool:
        return not self.denominator.is_zero()

    def is_zero(self) -> Bool:
        return self.numerator.is_zero()

    def is_integer(self) -> Bool:
        return self.denominator == 1

    def sign(self) -> Int:
        """-1, 0 or 1; an infinity has its own sign."""
        return self.numerator.sign()

    def __abs__(self) -> Self:
        return Self(lowest_numerator=abs(self.numerator), lowest_denominator=self.denominator)

    def __neg__(self) -> Self:
        return Self(lowest_numerator=-self.numerator, lowest_denominator=self.denominator)

    def _rank(self) -> Int:
        """-1 for -inf, 1 for +inf, 0 for finite."""
        return self.sign() if self.is_inf() else 0

    def __lt__(self, rhs: Self) -> Bool:
        if self._rank() != 0 or rhs._rank() != 0:
            return self._rank() < rhs._rank()
        return self.numerator * rhs.denominator < rhs.numerator * self.denominator

    def __add__(self, rhs: Self) raises -> Self:
        if self.is_inf() or rhs.is_inf():
            if self.is_inf() and rhs.is_inf() and self.sign() != rhs.sign():
                raise Error("inf + -inf is undefined")
            return self.copy() if self.is_inf() else rhs.copy()
        var n = self.numerator * rhs.denominator + rhs.numerator * self.denominator
        var d = self.denominator * rhs.denominator
        return Self.ratio(n.negative, n.magnitude.copy(), d.magnitude.copy())

    def __sub__(self, rhs: Self) raises -> Self:
        if self.is_inf() and rhs.is_inf() and self.sign() == rhs.sign():
            raise Error("inf - inf is undefined")
        return self + (-rhs)

    def __mul__(self, rhs: Self) raises -> Self:
        if self.is_inf() or rhs.is_inf():
            var s = self.sign() * rhs.sign()
            if s == 0:
                raise Error("0 * inf is undefined")
            return Self.infinity(s < 0)
        var n = self.numerator * rhs.numerator
        var d = self.denominator * rhs.denominator
        return Self.ratio(n.negative, n.magnitude.copy(), d.magnitude.copy())

    def __truediv__(self, rhs: Self) raises -> Self:
        if rhs.is_zero():
            raise Error("division by zero")
        if self.is_inf():
            if rhs.is_inf():
                raise Error("inf / inf is undefined")
            return Self.infinity(self.sign() * rhs.sign() < 0)
        if rhs.is_inf():
            return Self()
        var n = self.numerator * rhs.denominator
        var d = self.denominator * rhs.numerator
        return Self.ratio(n.negative != d.negative, n.magnitude.copy(), d.magnitude.copy())

    def floor(self) raises -> BigInt:
        if self.is_inf():
            raise Error("floor of an infinity")
        return self.numerator // self.denominator

    def ceil(self) raises -> BigInt:
        if self.is_inf():
            raise Error("ceil of an infinity")
        return -((-self.numerator) // self.denominator)

    def write_to(self, mut writer: Some[Writer]):
        if self.is_inf():
            writer.write("-inf" if self.numerator.negative else "inf")
        elif self.is_integer():
            writer.write(self.numerator)
        else:
            writer.write(self.numerator, "/", self.denominator)
