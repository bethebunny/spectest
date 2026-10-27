"""Converters: how enum members cross to the spec, which reads them as plain values."""

import enum

import spectest


# An enum member is read as its name: the dtype of a codec ("INT8", "UINT16", ...) and a
# member a Members codec decodes ("RED"). The converters read results only: a value goes
# back to the library by a call that makes it (support.py).
@spectest.marshal(enum.Enum)
def enum_to_wire(member: enum.Enum) -> str:
    return member.name


# A Flag, which may be a combination without a name, is read as its integer value.
@spectest.marshal(enum.Flag)
def flag_to_wire(flags: enum.Flag) -> int:
    return flags.value
