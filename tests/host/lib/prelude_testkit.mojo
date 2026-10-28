"""Helpers for the prelude's tests: calling by name, building values, sampling."""

from std.memory import bitcast
from std.os import getenv

from check.types import Types
from value.bigint import BigInt
from value.float_formats import FloatFormat, F16, BF16, F32, F64
from value.real import Real
from prelude.api import call, CallArgs, Keyword
from prelude.names import prelude_id
from prelude.util import real_value
from value.value import Value


def is_full() -> Bool:
    return getenv("SPECTEST_STRENGTH") == "full"


def samples(dev: Int, full: Int) -> Int:
    """A sample count that grows with `SPECTEST_STRENGTH`."""
    return full if is_full() else dev


struct Lcg(Movable):
    """A small deterministic generator, so a failing sample reproduces."""

    var state: UInt64

    def __init__(out self, seed: UInt64 = 0x9E3779B97F4A7C15):
        self.state = seed

    def next(mut self) -> UInt64:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        var x = self.state
        x ^= x >> 33
        x *= 0xFF51AFD7ED558CCD
        x ^= x >> 33
        return x

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


def formats() -> List[FloatFormat]:
    return [F16, BF16, F32, F64]


def id_of(name: String) raises -> Int:
    var id = prelude_id(name)
    if id is None:
        raise Error(t"no prelude function {name}")
    return id.value()


def run(name: String, var args: List[Value]) raises -> Value:
    var types = Types()
    return call(id_of(name), CallArgs(args^), types)


def run_typed(name: String, var args: List[Value], type_arg: Int, types: Types) raises -> Value:
    return call(id_of(name), CallArgs(args^, type_args=[type_arg]), types)


def run_kw(name: String, var args: List[Value], names: List[String], var keywords: List[Value]) raises -> Value:
    var types = Types()
    return call(id_of(name), CallArgs(args^, keywords=[Keyword(n, k.copy()) for n, k in zip(names, keywords)]), types)


def error_of(name: String, var args: List[Value]) -> String:
    """The message the call raises, or "" when it doesn't."""
    try:
        _ = run(name, args^)
    except e:
        return String(e)
    return String()


def fl(f: FloatFormat, bits: UInt64) -> Value:
    return Value.float(f, bits)


def f64v(x: Float64) -> Value:
    return Value.float(F64, UInt64(bitcast_f64(x)))


def bitcast_f64(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def bi(text: String) raises -> Value:
    return Value.int(BigInt.parse(text))


def rat(n: Int, d: Int) raises -> Value:
    """The real n/d, in lowest terms."""
    return real_value(Real(BigInt(n), BigInt(d)))


def int_list(*values: Int) -> Value:
    return Value.list([Value.int(v) for v in values])
