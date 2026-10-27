import math
import signal
import struct
import time

import fixtures_mod as fm
import numpy as np
import pytest

import spectest
from spectest.driver import Driver
from spectest.driver.wire import (
    Converted,
    Enum,
    Error,
    Float,
    Handle,
    Map,
    Record,
)

M = "fixtures_mod"


@pytest.fixture
def d():
    return Driver()


def call(d, name, *args, **kw):
    t = d.resolve(name)
    assert isinstance(t, int), t
    return d.call(t, list(args), kw or None)


# -- resolution ------------------------------------------------------------


def test_function_and_cache(d):
    t = d.resolve(f"{M}.add")
    assert d.resolve(f"{M}.add") == t
    assert d.call(t, [1, 2], None) == 3


def test_class_constructor_and_method(d):
    h = call(d, f"{M}.Counter", 3)
    assert isinstance(h, Handle) and h.cls == f"{M}.Counter"
    h2 = call(d, f"{M}.Counter.plus", h, 4)
    assert d.observe(h2, "n", None) == 7


def test_class_attribute_is_unbound_function(d):
    t = d.resolve(f"{M}.Counter.plus")
    assert d._targets[t] is fm.Counter.plus


def test_property(d):
    h = call(d, f"{M}.Counter", 5)
    assert call(d, f"{M}.Counter.double", h) == 10


def test_staticmethod_classmethod(d):
    assert call(d, f"{M}.Counter.static", 1) == 2
    h = call(d, f"{M}.Counter.make", 9)
    assert d.observe(h, "n", None) == 9


def test_constant_and_get(d):
    t = d.resolve(f"{M}.CONSTANT")
    assert d.get(t) == 42


def test_nested_class(d):
    h = call(d, f"{M}.Counter.Inner", 2)
    assert h.cls == f"{M}.Counter.Inner"


def test_builtins(d):
    assert call(d, "builtins.len", [1, 2, 3]) == 3
    assert call(d, "builtins.list.__len__", [1, 2]) == 2


@pytest.mark.parametrize(
    "name", ["nope_mod.x", f"{M}.missing", f"{M}.Counter.missing", "", "a..b", f"{M}."]
)
def test_unresolved(d, name):
    r = d.resolve(name)
    assert isinstance(r, Error) and r.cls == "spectest.ResolveError"


def test_unknown_target(d):
    r = d.call(999, [], None)
    assert isinstance(r, Error) and r.cls == "spectest.ResolveError"


# -- python to wire ----------------------------------------------------------


def f64bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def out(d, obj):
    """The wire form of a Python object, as a result."""
    return d._result(obj)


def test_simple_kinds(d):
    for v in [None, True, False, 0, 2**200, -5, "hi", ""]:
        r = out(d, v)
        assert r == v and type(r) is type(v)


def test_bool_before_int(d):
    assert out(d, True) is True
    assert out(d, 1) == 1 and out(d, 1) is not True


def test_floats(d):
    r = out(d, -0.0)
    assert r == Float("f64", 1 << 63)
    nan = struct.unpack("<d", struct.pack("<Q", 0x7FF0000000000123))[0]
    assert out(d, nan) == Float("f64", 0x7FF0000000000123)


def test_numpy_scalars(d):
    assert out(d, np.float16(1.0)) == Float("f16", 0x3C00)
    assert out(d, np.float32(1.0)) == Float("f32", 0x3F800000)
    assert out(d, np.float64(1.0)) == Float("f64", f64bits(1.0))
    r = out(d, np.int16(-3))
    assert r == -3 and type(r) is int
    r = out(d, np.bool_(True))
    assert r is True


def test_bytes_kinds(d):
    for v in [b"ab", bytearray(b"ab"), memoryview(b"ab")]:
        r = out(d, v)
        assert r == b"ab" and type(r) is bytes


def test_containers(d):
    assert out(d, [1, (2, "x"), [None]]) == [1, (2, "x"), [None]]
    r = out(d, {"a": 1, 2: [3]})
    assert r == Map((("a", 1), (2, [3])))


def test_enum_member(d):
    assert out(d, fm.Color.BLUE) == Enum(f"{M}.Color", "BLUE")


def test_records(d):
    assert out(d, fm.Point(1, 2)) == Record(f"{M}.Point", (("x", 1), ("y", 2)))
    assert out(d, fm.Box("a", [1])) == Record(
        f"{M}.Box", (("label", "a"), ("items", [1]))
    )


def test_handle_for_anything_else(d):
    r = out(d, object())
    assert isinstance(r, Handle) and r.cls == "builtins.object" and r.id == 1


def test_identity(d):
    a = call(d, f"{M}.shared")
    b = call(d, f"{M}.shared")
    assert a == b
    c = call(d, f"{M}.Counter", 1)
    assert c.id != a.id


def test_release(d):
    a = call(d, f"{M}.shared")
    assert d.release([a.id]) is None
    r = call(d, f"{M}.Counter.double", a)
    assert isinstance(r, Error) and r.cls == "spectest.ConvertError"
    assert call(d, f"{M}.shared").id != a.id


def test_ids_start_at_one_and_target_not_handle(d):
    assert call(d, f"{M}.shared").id == 1


# -- wire to python ----------------------------------------------------------


@pytest.mark.parametrize(
    "fmt,bits,expect",
    [
        ("f16", 0x3C00, 1.0),
        ("bf16", 0x3F80, 1.0),
        ("f32", 0x3F800000, 1.0),
        ("f64", f64bits(2.5), 2.5),
        ("f16", 0x8000, -0.0),
        ("f32", 0x7F800000, math.inf),
    ],
)
def test_float_arguments(d, fmt, bits, expect):
    r = call(d, f"{M}.ident", Float(fmt, bits))
    assert r == Float("f64", f64bits(expect))


def test_nan_payload_through(d):
    r = call(d, f"{M}.ident", Float("f64", 0x7FF8000000000ABC))
    assert r == Float("f64", 0x7FF8000000000ABC)
    r = call(d, f"{M}.ident", Float("f32", 0x7FC00001))
    assert r.bits & 1 == 0 and (r.bits >> 52) & 0x7FF == 0x7FF
    assert (r.bits & ((1 << 52) - 1)) == (0x400001 << 29)


def test_argument_containers(d):
    arg = [1, (2, 3), Map((("k", [4]),)), b"x", None]
    assert call(d, f"{M}.ident", arg) == [1, (2, 3), Map((("k", [4]),)), b"x", None]


def test_record_argument(d):
    r = call(d, f"{M}.ident", Record(f"{M}.Point", (("x", 3), ("y", 4))))
    assert r == Record(f"{M}.Point", (("x", 3), ("y", 4)))
    bad = call(d, f"{M}.ident", Record(f"{M}.Point", (("z", 3),)))
    assert isinstance(bad, Error) and bad.cls == "spectest.ConvertError"
    bad = call(d, f"{M}.ident", Record(f"{M}.Nope", ()))
    assert bad.cls == "spectest.ConvertError"


def test_enum_argument(d):
    assert call(d, f"{M}.ident", Enum(f"{M}.Color", "RED")) == Enum(f"{M}.Color", "RED")
    assert call(d, f"{M}.ident", Enum("", "lit")) == "lit"
    assert (
        call(d, f"{M}.ident", Enum(f"{M}.Color", "GREEN")).cls
        == "spectest.ConvertError"
    )


def test_handle_argument(d):
    h = call(d, f"{M}.Counter", 2)
    assert call(d, f"{M}.ident", h) == h
    r = call(d, f"{M}.ident", Handle(12345, "x"))
    assert isinstance(r, Error) and r.cls == "spectest.ConvertError"


def test_kwargs(d):
    t = d.resolve(f"{M}.add")
    assert d.call(t, [1], {"b": 5}) == 6
    assert d.call(t, [1], Map((("b", 7),))) == 8


# -- errors ------------------------------------------------------------------


def test_error_from_code(d):
    r = call(d, f"{M}.boom", "bad")
    assert r == Error(
        "builtins.ValueError", ("builtins.Exception", "builtins.BaseException"), "bad"
    )


def test_error_ipaddress(d):
    r = call(d, "ipaddress.IPv4Address", "nope")
    assert isinstance(r, Error)
    assert r.cls == "ipaddress.AddressValueError"
    assert r.bases == (
        "builtins.ValueError",
        "builtins.Exception",
        "builtins.BaseException",
    )
    assert "nope" in r.message


def test_propagating_exceptions(d):
    t = d.resolve("builtins.exit")
    with pytest.raises(SystemExit):
        d.call(t, [], None)


def test_keyboard_interrupt_propagates(d, monkeypatch):
    def ki():
        raise KeyboardInterrupt

    monkeypatch.setattr(fm, "ki", ki, raising=False)
    t = d.resolve(f"{M}.ki")
    with pytest.raises(KeyboardInterrupt):
        d.call(t, [], None)


# -- converters --------------------------------------------------------------


def test_converters(d):
    @spectest.marshal(fm.Day)
    def day_to_wire(x: fm.Day) -> int:
        return x.n

    @day_to_wire.inverse
    def day_from_wire(n: int) -> fm.Day:
        return fm.Day(n)

    assert d.converters()[f"{M}.Day"] == "int"
    r = call(d, f"{M}.Day", 5)
    assert r == Converted(f"{M}.Day", 5)
    back = call(d, f"{M}.ident", Converted(f"{M}.Day", 6))
    assert back == Converted(f"{M}.Day", 6)
    # a subclass uses the nearest registered base
    sub = call(d, f"{M}.SubDay", 8)
    assert sub == Converted(f"{M}.Day", 8)
    bad = call(d, f"{M}.ident", Converted("nope.X", 1))
    assert bad.cls == "spectest.ConvertError"


def test_converter_string_kind():
    class Name:
        pass

    @spectest.marshal(Name)
    def to_wire(x: Name) -> str:
        return "n"

    assert (
        Driver().converters()[f"{__name__}.test_converter_string_kind.<locals>.Name"]
        == "string"
    )


# -- cap ---------------------------------------------------------------------


def test_max_elements():
    small = Driver(max_elements=100)
    t = small.resolve(f"{M}.make_big")
    assert small.call(t, [50], None) == list(range(50))
    r = small.call(t, [1000], None)
    assert isinstance(r, Error) and r.cls == "spectest.TooLarge"


def test_default_cap(d):
    t = d.resolve(f"{M}.make_big")
    assert isinstance(d.call(t, [2**17 + 10], None), Error)
    assert len(d.call(t, [1000], None)) == 1000


# -- bitpattern --------------------------------------------------------------


def test_bitpattern(d):
    rng = d.resolve("bitpattern.IntSet.range")
    s = d.call(rng, [0, 5], None)
    assert isinstance(s, Handle) and s.cls.endswith("IntSet")
    contains = d.resolve("bitpattern.IntSet.__contains__")
    assert d.call(contains, [s, 3], None) is True
    assert d.call(contains, [s, 9], None) is False
    union = d.resolve("bitpattern.IntSet.__or__")
    t = d.call(rng, [10, 12], None)
    u = d.call(union, [s, t], None)
    assert d.observe(u, "size", None) == 7
    assert d.observe(s, "width", None) == 3
    assert d.observe(s, "__contains__", [4]) is True
    codec = d.get(d.resolve("bitpattern.codecs.int8"))
    assert isinstance(codec, Record) and codec.type.endswith("Int")


# -- speed -------------------------------------------------------------------


def test_call_speed(d, capsys):
    t = d.resolve(f"{M}.add")
    args = [1, 2]
    n = 200_000
    d.call(t, args, None)
    start = time.perf_counter()
    for _ in range(n):
        d.call(t, args, None)
    us = (time.perf_counter() - start) / n * 1e6
    with capsys.disabled():
        print(f"\ndriver.call of a two-int function: {us:.2f} us per call")
    assert us < 5


# -- time limit ---------------------------------------------------------------


def test_a_call_past_the_timeout_is_a_call_timeout_error():
    d = Driver(timeout=0.2)
    start = time.perf_counter()
    assert call(d, f"{M}.block") == Error(
        "spectest.CallTimeout", (), "timed out after 0.2s"
    )
    assert time.perf_counter() - start < 5


def test_the_alarm_is_off_after_a_call():
    d = Driver(timeout=0.2)
    assert call(d, f"{M}.add", 1, 2) == 3
    assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
    assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL


def test_observe_times_out_too():
    d = Driver(timeout=0.2)
    slow = call(d, f"{M}.Slow")
    assert isinstance(slow, Handle)
    assert d.observe(slow, "wait", []) == Error(
        "spectest.CallTimeout", (), "timed out after 0.2s"
    )
