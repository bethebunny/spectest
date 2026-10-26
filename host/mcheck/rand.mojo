"""Deterministic randomness: splitmix64 seeds xoshiro256**."""


def splitmix64(mut state: UInt64) -> UInt64:
    state += UInt64(0x9E3779B97F4A7C15)
    var z = state
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


struct Rng(Copyable, Movable):
    var s0: UInt64
    var s1: UInt64
    var s2: UInt64
    var s3: UInt64

    def __init__(out self, seed: UInt64):
        var sm = seed
        self.s0 = splitmix64(sm)
        self.s1 = splitmix64(sm)
        self.s2 = splitmix64(sm)
        self.s3 = splitmix64(sm)

    def next(mut self) -> UInt64:
        var x = self.s1 * UInt64(5)
        var result = ((x << 7) | (x >> 57)) * UInt64(9)
        var t = self.s1 << 17
        self.s2 ^= self.s0
        self.s3 ^= self.s1
        self.s1 ^= self.s2
        self.s0 ^= self.s3
        self.s2 ^= t
        self.s3 = (self.s3 << 45) | (self.s3 >> 19)
        return result

    def below(mut self, n: UInt64) -> UInt64:
        """Uniform in [0, n); n must be positive."""
        if n & (n - 1) == 0:
            return self.next() & (n - 1)
        var threshold = (UInt64(0) - n) % n
        while True:
            var r = self.next()
            if r >= threshold:
                return r % n

    def unit(mut self) -> Float64:
        """Uniform in [0, 1)."""
        return Float64(self.next() >> 11) * (1.0 / 9007199254740992.0)
