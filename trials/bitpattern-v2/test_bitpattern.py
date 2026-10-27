"""Runs the formal spec of bitpattern 0.3.0 through spectest v2."""

import spectest

# Names the spec uses for calls that v2 cannot make as written: bitpattern's keyword-only
# parameters (v2 passes arguments by position), iterators (they cross as opaque
# handles), and one library callable under several spec names (v2 has one signature per
# name). Each maps to a function in support.py or back to the library.
MODULES = {
    "bitpattern.IntSet.range": "support.intset_range",
}

test_bitpattern = spectest.check("bitpattern.spec", modules=MODULES)
