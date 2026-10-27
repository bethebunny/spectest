"""Runs the formal spec of bitpattern 0.3.0 through spectest v2."""

import spectest

# Names the spec uses for calls that v2 cannot make as written: bitpattern's keyword-only
# parameters (v2 passes arguments by position), iterators (they cross as opaque
# handles), and one library callable under several spec names (v2 has one signature per
# name). Each maps to a function in support.py or back to the library.
MODULES = {
    # Constructors: the class name is also the model's, so the spec calls a variant.
    "variant.IntSet_new": "bitpattern.IntSet",
    "variant.IntSet_floats": "bitpattern.IntSet",
    "variant.IntSet_with_width": "support.intset_width",
    "variant.BDD_new": "bitpattern.bdd.BDD",
    "variant.BDD_bad_children": "bitpattern.bdd.BDD",
    "variant.Pattern_new": "support.pattern_tokens",
    "variant.Pattern_cells": "support.pattern_from_cells",
    "variant.diagram_cells": "support.diagram",
    # Keyword-only parameters.
    "bitpattern.IntSet.range": "support.intset_range",
    "bitpattern.intset.IntSet.choice": "support.choice",
    "bitpattern.bdd.count": "support.bdd_count",
    "bitpattern.bdd.nth": "support.bdd_nth",
    "bitpattern.bdd.rank": "support.bdd_rank",
    "bitpattern.bdd.members": "support.bdd_members",
    "bitpattern.bdd.blocks": "support.bdd_blocks",
    "bitpattern.bdd.paths": "support.bdd_paths",
    "bitpattern.bdd.exactly_these": "support.exactly_these",
    "bitpattern.bdd.interval": "support.interval",
    "bitpattern.bdd.narrowed": "support.narrowed",
    "bitpattern.bdd.freed_between": "support.freed_between",
    "bitpattern.intset.IntSet.__dlpack__": "support.dlpack",
    "numpy.from_dlpack": "support.exported",
    # Objects that cannot cross as values.
    "variant.IntSet_slice": "support.getslice",
    "variant.IntSet_choice_seeded": "support.choice_seeded",
    # Operators, applied as Python applies them (reflected operands, NotImplemented).
    "variant.IntSet_contains_float": "operator.contains",
    "variant.IntSet_contains_string": "operator.contains",
    "variant.IntSet_getitem_float": "operator.getitem",
    "variant.IntSet_and_int": "operator.and_",
    "variant.IntSet_or_int": "operator.or_",
    "variant.IntSet_sub_int": "operator.sub",
    "variant.IntSet_xor_int": "operator.xor",
    "variant.IntSet_le_list": "operator.le",
    "variant.IntSet_lt_list": "operator.lt",
    "variant.IntSet_ge_list": "operator.ge",
    "variant.IntSet_gt_list": "operator.gt",
    "variant.IntSet_eq_list": "operator.eq",
    "variant.BDD_and_int": "operator.and_",
    "variant.BDD_or_int": "operator.or_",
    "variant.BDD_sub_int": "operator.sub",
    "variant.BDD_xor_int": "operator.xor",
    "variant.BDD_eq_int": "operator.eq",
    # One library callable under another argument shape: v2 has one signature per name.
    "variant.IntSet_count_float": "bitpattern.intset.IntSet.count",
    "variant.IntSet_index_float": "bitpattern.intset.IntSet.index",
    "variant.IntSet_choice_default": "bitpattern.intset.IntSet.choice",
    "variant.IntSet_and_list": "bitpattern.intset.IntSet.__and__",
    "variant.IntSet_or_list": "bitpattern.intset.IntSet.__or__",
    "variant.IntSet_sub_list": "bitpattern.intset.IntSet.__sub__",
    "variant.IntSet_xor_list": "bitpattern.intset.IntSet.__xor__",
    "variant.IntSet_rand_list": "bitpattern.intset.IntSet.__rand__",
    "variant.IntSet_ror_list": "bitpattern.intset.IntSet.__ror__",
    "variant.IntSet_rsub_list": "bitpattern.intset.IntSet.__rsub__",
    "variant.IntSet_rxor_list": "bitpattern.intset.IntSet.__rxor__",
    "variant.IntSet_and_negative": "bitpattern.intset.IntSet.__and__",
    "variant.IntSet_or_negative": "bitpattern.intset.IntSet.__or__",
    "variant.IntSet_sub_negative": "bitpattern.intset.IntSet.__sub__",
    "variant.IntSet_xor_negative": "bitpattern.intset.IntSet.__xor__",
    "variant.IntSet_and_floats": "bitpattern.intset.IntSet.__and__",
    "variant.IntSet_or_floats": "bitpattern.intset.IntSet.__or__",
    "variant.IntSet_sub_floats": "bitpattern.intset.IntSet.__sub__",
    "variant.IntSet_xor_floats": "bitpattern.intset.IntSet.__xor__",
    "variant.IntSet_isdisjoint_set": "bitpattern.intset.IntSet.isdisjoint",
    "variant.IntSet_repr": "builtins.repr",
    "variant.BDD_bool": "builtins.bool",
    "variant.BDD_hash": "builtins.hash",
    "variant.BDD_repr": "builtins.repr",
    "variant.Pattern_str": "builtins.str",
    "variant.Pattern_repr": "builtins.repr",
    "variant.Pattern_hash": "builtins.hash",
    "variant.Pattern_eq_pattern": "bitpattern.pattern.Pattern.__eq__",
}

test_bitpattern = spectest.check("bitpattern.spec", modules=MODULES)
