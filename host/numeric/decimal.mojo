"""Helpers for powers of ten and decimal digits of exact ratios."""

from bigint import BigUInt

from numeric.bigint import BigInt


def pow10(k: Int) -> BigUInt:
    """`10**k` for k >= 0."""
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
    if k >= 0:
        return d * pow10(k) <= n
    return d <= n * pow10(-k)


def floor_log10(n: BigUInt, d: BigUInt) -> Int:
    """`floor(log10(n / d))` for positive n and d, exactly."""
    var e2 = n.bits() - d.bits()
    var k = (e2 * 30103) // 100000
    while not at_least_pow10(n, d, k):
        k -= 1
    while at_least_pow10(n, d, k + 1):
        k += 1
    return k


def decimal_digits(value: BigUInt) -> String:
    return String(BigInt(negative=False, magnitude=value.copy()))
