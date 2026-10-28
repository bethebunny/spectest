"""The four float formats: their ids, names and bit layouts.

A float value is its format's id and its bit pattern, zero-extended to 64 bits.
"""


@fieldwise_init
struct FloatFormat(Equatable, TrivialRegisterPassable, Writable):
    var id: UInt8
    """F16.id is 1, BF16.id 2, F32.id 3, F64.id 4. 0 is no format."""
    var exponent_bits: Int
    var fraction_bits: Int
    """Stored significand bits, without the implicit leading 1."""

    def width(self) -> Int:
        return 1 + self.exponent_bits + self.fraction_bits

    def bias(self) -> Int:
        return (1 << (self.exponent_bits - 1)) - 1

    def sign_mask(self) -> UInt64:
        return UInt64(1) << UInt64(self.width() - 1)

    def exponent_mask(self) -> UInt64:
        return ((UInt64(1) << UInt64(self.exponent_bits)) - 1) << UInt64(
            self.fraction_bits
        )

    def fraction_mask(self) -> UInt64:
        return (UInt64(1) << UInt64(self.fraction_bits)) - 1

    def quiet_nan(self) -> UInt64:
        """The positive quiet NaN with no payload, which prints as `nan`."""
        return self.exponent_mask() | UInt64(1) << UInt64(self.fraction_bits - 1)

    def max_finite(self) -> UInt64:
        return self.exponent_mask() - 1

    def name(self) -> StaticString:
        match Int(self.id):
            case 1:
                return "f16"
            case 2:
                return "bf16"
            case 3:
                return "f32"
            case 4:
                return "f64"
            case _:
                return "none"

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.name())


comptime F16 = FloatFormat(1, 5, 10)
comptime BF16 = FloatFormat(2, 8, 7)
comptime F32 = FloatFormat(3, 8, 23)
comptime F64 = FloatFormat(4, 11, 52)
comptime FORMATS: Array[FloatFormat, 4] = [F16, BF16, F32, F64]
"""In order of id, from 1."""


def format_by_id(id: UInt8) raises -> FloatFormat:
    var formats = materialize[FORMATS]()
    if not 1 <= Int(id) <= len(formats):
        raise Error(t"no float format with id {id}")
    return formats[Int(id) - 1]


def format_by_name(name: StringSlice) raises -> FloatFormat:
    for format in materialize[FORMATS]():
        if format.name() == name:
            return format
    raise Error(t"no float format named {name}")
