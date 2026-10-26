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

    def __eq__(self, other: Self) -> Bool:
        return self.id == other.id

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

    def name(self) -> StaticString:
        if self.id == 1:
            return "f16"
        if self.id == 2:
            return "bf16"
        if self.id == 3:
            return "f32"
        if self.id == 4:
            return "f64"
        return "none"

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.name())


comptime F16 = FloatFormat(1, 5, 10)
comptime BF16 = FloatFormat(2, 8, 7)
comptime F32 = FloatFormat(3, 8, 23)
comptime F64 = FloatFormat(4, 11, 52)


def format_by_id(id: UInt8) raises -> FloatFormat:
    if id == 1:
        return F16
    if id == 2:
        return BF16
    if id == 3:
        return F32
    if id == 4:
        return F64
    raise Error("no float format with id " + String(id))


def format_by_name(name: StringSlice) raises -> FloatFormat:
    if name == "f16":
        return F16
    if name == "bf16":
        return BF16
    if name == "f32":
        return F32
    if name == "f64":
        return F64
    raise Error("no float format named " + String(name))
