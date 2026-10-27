"""What `BigUInt` lacks: powers, gcd, trailing zeros, decimal logarithms and rounded
quotients."""

from std.bit import count_trailing_zeros

from bigint import BigUInt


def power(var base: BigUInt, exponent: Int) -> BigUInt:
    """`base**exponent` for a non-negative exponent, by squaring."""
    var result = BigUInt(1)
    var rest = exponent
    while rest > 0:
        if rest & 1:
            result = result * base
        rest >>= 1
        if rest:
            base = base * base
    return result^


def pow10(k: Int) -> BigUInt:
    return power(10, k)


def gcd(var a: BigUInt, var b: BigUInt) -> BigUInt:
    while b:
        var r = a % b
        a = b^
        b = r^
    return a^


def trailing_zeros(x: BigUInt) -> Int:
    """How many low bits of `x` are zero; 0 for zero."""
    for i in range(len(x.limbs)):
        if x.limb(i):
            return 64 * i + Int(count_trailing_zeros(x.limb(i)))
    return 0


def at_least_pow10(n: BigUInt, d: BigUInt, k: Int) -> Bool:
    """Is `n / d >= 10**k`? `d` is positive."""
    return d * pow10(k) <= n if k >= 0 else d <= n * pow10(-k)


def floor_log10(n: BigUInt, d: BigUInt) -> Int:
    """`floor(log10(n / d))` for positive n and d, exactly."""
    # 30103 / 100000 is about log10(2), so k starts near the answer.
    var k = ((n.bits() - d.bits()) * 30103) // 100000
    while not at_least_pow10(n, d, k):
        k -= 1
    while at_least_pow10(n, d, k + 1):
        k += 1
    return k


def rounded_quotient(n: BigUInt, d: BigUInt) -> BigUInt:
    """`n / d` rounded to the nearest integer, ties to even."""
    var quotient = n // d
    var twice = (n % d) << 1
    return quotient.plus(1) if d < twice or (twice == d and quotient.bit(0)) else quotient^
