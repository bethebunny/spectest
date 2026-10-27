"""Powers of ten, gcd, logarithms and rounding of exact ratios."""

from bigint import BigUInt


def pow10(k: Int) -> BigUInt:
    var result = BigUInt(UInt64(1))
    var base = BigUInt(UInt64(10))
    var e = k
    while e > 0:
        if e & 1:
            result = result * base
        e >>= 1
        if e:
            base = base * base
    return result^


def gcd(var a: BigUInt, var b: BigUInt) -> BigUInt:
    while b:
        var r = a % b
        a = b^
        b = r^
    return a^


def at_least_pow10(n: BigUInt, d: BigUInt, k: Int) -> Bool:
    """Is `n / d >= 10**k`? `d` is positive."""
    return d * pow10(k) <= n if k >= 0 else d <= n * pow10(-k)


def floor_log10(n: BigUInt, d: BigUInt) -> Int:
    """`floor(log10(n / d))` for positive n and d, exactly."""
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
