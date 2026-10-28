"""Values of fixed-width types from their bit patterns."""

from spec import types as ty
from value.bigint import BigInt
from value.fixed import signed_of
from value.float_formats import format_by_id
from value.value import Value


def int_from_bits(bits: UInt64, width: Int, signed: Bool) -> Value:
    return Value.int(signed_of(bits, width)) if signed else Value.int(BigInt(bits))


def value_from_bits(types: ty.Types, t: Int, bits: UInt64) raises -> Value:
    """The value of fixed-width type `t` with bit pattern `bits`."""
    ref info = types.info(t)
    match info.kind:
        case .BOOL:
            return Value.bool(bits != 0)
        case .FIXED_INT:
            return int_from_bits(bits, info.bits, info.signed)
        case .FLOAT:
            return Value.float(format_by_id(UInt8(info.bits)), bits)
        case _:
            raise Error(t"{types.text(t)} is not a fixed-width type")
