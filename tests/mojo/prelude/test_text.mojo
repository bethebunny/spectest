from std.testing import assert_equal, assert_true, assert_false, TestSuite

from prelude_testkit import Lcg, error_of, int_list, run, samples
from value.value import Value


def valid(data: List[UInt8]) raises -> Bool:
    return run("valid_utf8", [Value.bytes(data.copy())]).as_bool()


def test_valid_utf8_table() raises:
    assert_true(valid([]))
    assert_true(valid([0x00, 0x41, 0x7F]))
    assert_true(valid([0xC2, 0x80]))
    assert_true(valid([0xDF, 0xBF]))
    assert_true(valid([0xE0, 0xA0, 0x80]))
    assert_true(valid([0xED, 0x9F, 0xBF]))
    assert_true(valid([0xEE, 0x80, 0x80]))
    assert_true(valid([0xEF, 0xBF, 0xBF]))
    assert_true(valid([0xF0, 0x90, 0x80, 0x80]))
    assert_true(valid([0xF4, 0x8F, 0xBF, 0xBF]))
    # A stray continuation byte, or a lead with no continuation.
    assert_false(valid([0x80]))
    assert_false(valid([0xBF]))
    assert_false(valid([0xC2]))
    assert_false(valid([0xE2, 0x82]))
    assert_false(valid([0xF0, 0x9F, 0x98]))
    # Overlong forms.
    assert_false(valid([0xC0, 0x80]))
    assert_false(valid([0xC1, 0xBF]))
    assert_false(valid([0xE0, 0x80, 0x80]))
    assert_false(valid([0xE0, 0x9F, 0xBF]))
    assert_false(valid([0xF0, 0x80, 0x80, 0x80]))
    assert_false(valid([0xF0, 0x8F, 0xBF, 0xBF]))
    # Surrogates and values past U+10FFFF.
    assert_false(valid([0xED, 0xA0, 0x80]))
    assert_false(valid([0xED, 0xBF, 0xBF]))
    assert_false(valid([0xF4, 0x90, 0x80, 0x80]))
    assert_false(valid([0xF5, 0x80, 0x80, 0x80]))
    assert_false(valid([0xF8, 0x88, 0x80, 0x80, 0x80]))
    assert_false(valid([0xFF]))
    assert_false(valid([0xFE]))
    # A valid prefix doesn't excuse what follows.
    assert_false(valid([0x41, 0x42, 0x80]))
    assert_false(valid([0xC2, 0x41]))
    assert_false(valid([0xE2, 0x82, 0x41]))
    assert_true(valid([0x41, 0xE2, 0x82, 0xAC, 0x42]))
    assert_true(error_of("valid_utf8", [Value.string("a")]).startswith("valid_utf8: "))


def oracle(data: List[UInt8]) -> Bool:
    """Decode by the bit layout, then check the value against its length's range."""
    var i = 0
    var n = len(data)
    while i < n:
        var c = Int(data[i])
        var extra: Int
        var value: Int
        var least: Int
        if c < 0x80:
            i += 1
            continue
        elif c >= 0xC0 and c < 0xE0:
            extra = 1
            value = c & 0x1F
            least = 0x80
        elif c >= 0xE0 and c < 0xF0:
            extra = 2
            value = c & 0x0F
            least = 0x800
        elif c >= 0xF0 and c < 0xF8:
            extra = 3
            value = c & 0x07
            least = 0x10000
        else:
            return False
        if i + extra >= n:
            return False
        for k in range(1, extra + 1):
            var d = Int(data[i + k])
            if (d & 0xC0) != 0x80:
                return False
            value = (value << 6) | (d & 0x3F)
        if value < least or value > 0x10FFFF or (0xD800 <= value <= 0xDFFF):
            return False
        i += extra + 1
    return True


def test_agrees_with_a_decoder_on_short_strings() raises:
    for a in range(256):
        assert_true(valid([UInt8(a)]) == oracle([UInt8(a)]))
        for b in range(0, 256, samples(3, 1)):
            var two: List[UInt8] = [UInt8(a), UInt8(b)]
            assert_true(valid(two) == oracle(two))


def test_agrees_with_a_decoder_on_longer_strings() raises:
    var step = samples(53, 1)
    for a in range(0xE0, 0xF8):
        for b in range(0, 256, samples(3, 1)):
            for c in range(0, 256, step):
                var three: List[UInt8] = [UInt8(a), UInt8(b), UInt8(c)]
                assert_true(valid(three) == oracle(three))
                if a >= 0xF0:
                    for d in range(0x7E, 0xC0, 5 if step > 1 else 9):
                        var four: List[UInt8] = [UInt8(a), UInt8(b), UInt8(c), UInt8(d)]
                        assert_true(valid(four) == oracle(four))
    var rng = Lcg()
    for _ in range(samples(2000, 200000)):
        var data = List[UInt8]()
        for _k in range(1 + rng.below(8)):
            # Biased towards the bytes that matter.
            var r = rng.below(4)
            data.append(UInt8(rng.below(128)) if r == 0 else UInt8(0x80 + rng.below(0x80)))
        assert_true(valid(data) == oracle(data))


def test_codepoints() raises:
    assert_true(run("codepoints", [Value.string("")]) == Value.list([]))
    assert_true(run("codepoints", [Value.string("abc")]) == int_list(97, 98, 99))
    assert_true(run("codepoints", [Value.string("aé€" + chr(0x1F600))]) == int_list(97, 0xE9, 0x20AC, 0x1F600))
    assert_true(run("codepoints", [Value.string(chr(0))]) == int_list(0))
    assert_true(error_of("codepoints", [Value.bytes([])]).startswith("codepoints: "))


def test_from_codepoints() raises:
    assert_true(run("from_codepoints", [Value.list([])]) == Value.string(""))
    assert_true(run("from_codepoints", [int_list(97, 98)]) == Value.string("ab"))
    assert_true(run("from_codepoints", [int_list(0xE9, 0x20AC, 0x1F600)]) == Value.string("é€" + chr(0x1F600)))
    assert_true(run("from_codepoints", [int_list(0)]) == Value.string(chr(0)))
    assert_true(run("from_codepoints", [int_list(0x10FFFF)]) == Value.string(chr(0x10FFFF)))
    assert_true(run("from_codepoints", [int_list(0xD7FF, 0xE000)]) == Value.string(chr(0xD7FF) + chr(0xE000)))
    for bad in [-1, 0xD800, 0xDBFF, 0xDFFF, 0x110000, 1 << 40]:
        var message = error_of("from_codepoints", [int_list(65, bad)])
        assert_true(message.startswith("from_codepoints: "))
    assert_true(error_of("from_codepoints", [Value.list([Value.string("a")])]).startswith("from_codepoints: "))
    assert_true(error_of("from_codepoints", [Value.string("a")]).startswith("from_codepoints: "))


def test_round_trip_every_scalar() raises:
    var step = samples(61, 1)
    var scalars = List[Value]()
    var cp = 0
    while cp <= 0x10FFFF:
        if not (0xD800 <= cp <= 0xDFFF):
            scalars.append(Value.int(cp))
        cp += step
        if len(scalars) == 4096:
            check_batch(scalars)
            scalars = List[Value]()
    check_batch(scalars)


def check_batch(scalars: List[Value]) raises:
    var text = run("from_codepoints", [Value.list(scalars.copy())])
    assert_true(run("codepoints", [text.copy()]) == Value.list(scalars.copy()))
    assert_true(run("len", [text.copy()]) == Value.int(len(scalars)))
    # The bytes of the string, as the language encodes them, are well-formed.
    var data = List[UInt8]()
    for b in text.text().as_bytes():
        data.append(b)
    assert_true(valid(data))
    # And the encoding is the standard one.
    var expected = String()
    for s in scalars:
        expected += chr(s.small_int().value())
    assert_true(text == Value.string(expected^))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
