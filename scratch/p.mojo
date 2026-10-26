from numeric.real import Real
from numeric.literal import *
from numeric.text import *
from numeric.formats import *
def main() raises:
    print(parse_number("0x1.8p3"), parse_number("1_0.5e-1"), is_integer_literal("0xe"))
    print(float_text(4, 0x3FF8000000000000), float_text(4, 0x3FB999999999999A), float_text(4,1), float_text(4, 0x4341C37937E08000), float_text(3, 0x80000000), float_text(2, 0x7FC1))
    print(real_text(parse_number("1.5")), real_text(Real(1)/Real(3) if False else parse_number("0.000001")), real_text(Real(1)))
    print(float_text(4, 0x3EE4F8B588E368F1), float_text(4, 0x7FEFFFFFFFFFFFFF))
