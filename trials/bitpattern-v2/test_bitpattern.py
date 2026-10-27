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
    # Records are named by their class.
    "Codec": "bitpattern.codecs.Codec",
    "Int": "bitpattern.codecs.Int",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.Int_new": "bitpattern.codecs.Int",
    "variant.Int_named": "support.int_named",
    "variant.BDDSet_new": "bitpattern.codecs.BDDSet",
    "variant.BDDSet_setattr": "support.bddset_setattr",
    "variant.BDDSet_hash": "support.bddset_hash",
    "variant.DType_value": "support.dtype_value",
    "variant.IntSet_range_floats": "support.intset_range",
    "variant.IntSet_and_pattern": "operator.and_",
    "variant.IntSet_or_pattern": "operator.or_",
    "variant.IntSet_sub_pattern": "operator.sub",
    "variant.IntSet_xor_pattern": "operator.xor",
    "variant.Pattern_ror_list": "bitpattern.pattern.Pattern.__ror__",
    "variant.Pattern_rsub_list": "bitpattern.pattern.Pattern.__rsub__",
    "variant.Pattern_slice": "support.getslice",
    "variant.Int_eq": "operator.eq",
    "variant.Int_hash": "builtins.hash",
    "variant.Int_setattr": "builtins.setattr",
    "variant.Codec_repr": "builtins.repr",
    "variant.Int_encode_float": "bitpattern.codecs.Int.encode",
    "variant.Int_encode_string": "bitpattern.codecs.Int.encode",
    "variant.Int_range_floats": "bitpattern.codecs.Int.range",
    "variant.Int_pattern": "support.codec_pattern",
    # A BDDSet is rebuilt from its codec and storage (support.py).
    "bitpattern.codecs.BDDSet.size": "support.bddset_size",
    "bitpattern.codecs.BDDSet.__contains__": "support.bddset_contains",
    "variant.BDDSet_contains_float": "support.bddset_contains_other",
    "bitpattern.codecs.BDDSet.__getitem__": "support.bddset_getitem",
    "variant.BDDSet_slice": "support.bddset_slice",
    "bitpattern.codecs.BDDSet.index": "support.bddset_index",
    "bitpattern.codecs.BDDSet.count": "support.bddset_count",
    "bitpattern.codecs.BDDSet.__invert__": "support.bddset_invert",
    "bitpattern.codecs.BDDSet.__or__": "support.bddset_or",
    "bitpattern.codecs.BDDSet.__and__": "support.bddset_and",
    "bitpattern.codecs.BDDSet.__sub__": "support.bddset_sub",
    "bitpattern.codecs.BDDSet.__xor__": "support.bddset_xor",
    "bitpattern.codecs.BDDSet.__le__": "support.bddset_le",
    "bitpattern.codecs.BDDSet.__lt__": "support.bddset_lt",
    "bitpattern.codecs.BDDSet.__ge__": "support.bddset_ge",
    "bitpattern.codecs.BDDSet.__gt__": "support.bddset_gt",
    "bitpattern.codecs.BDDSet.__eq__": "support.bddset_eq",
    "bitpattern.codecs.BDDSet.isdisjoint": "support.bddset_isdisjoint",
    "bitpattern.codecs.BDDSet.choice": "support.bddset_choice",
    "variant.BDDSet_or_other_codec": "support.bddset_or_other_codec",
    "variant.BDDSet_or_list": "support.bddset_or_foreign",
    "variant.BDDSet_or_intset": "support.bddset_or_foreign",
    "variant.BDDSet_le_intset": "support.bddset_le_foreign",
    "variant.BDDSet_isdisjoint_list": "support.bddset_isdisjoint_foreign",
    "variant.BDDSet_eq_intset": "support.bddset_eq_foreign",
    "variant.BDDSet_eq_list": "support.bddset_eq_foreign",
    "variant.BDDSet_repr": "support.bddset_repr",
    "variant.BDDSet_exported": "support.bddset_exported",
    # Hypothesis strategies cannot cross.
    "bitpattern.strategies.from_set": "support.strategy_examples",
    "variant.from_set_minimal": "support.strategy_minimal",
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


# The float codecs are named by `kind`; each variant is a call on the codec of that name.
FLOAT_MODULES = {
    "Float": "bitpattern.codecs.Float",
    "FloatFN": "bitpattern.codecs.FloatFN",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.Float_codec": "support.float_codec",
    "variant.FloatFN_codec": "support.float_codec_fn",
    "variant.Float_dtype": "support.float_dtype",
    "variant.Float_max": "support.float_max",
    "variant.Float_min": "support.float_min",
    "variant.FloatFN_max": "support.float_fn_max",
    "variant.Float_encode": "support.float_encode",
    "variant.Float_encode_int": "support.float_encode",
    "variant.Float_encode_string": "support.float_encode",
    "variant.Float_decode": "support.float_decode",
    "variant.FloatFN_decode": "support.float_fn_decode",
    "variant.FloatFN_encode": "support.float_fn_encode",
    "variant.Float_set": "support.float_set",
    "variant.Float_partition": "support.float_partition",
    "variant.Float_range": "support.float_range",
    "variant.Float_getitem": "support.float_getitem",
}

# Inputs the informal spec works through, judged before the search.
EXAMPLES = {
    "bitpattern.IntSet.range": [
        {"start": 3, "stop": 17, "width": 3},
        {"start": 0, "stop": 0, "width": None},
        {"start": 0, "stop": 2, "width": None},
        {"start": 5, "stop": 3, "width": None},
        {"start": 0, "stop": 2**100, "width": 128},
        {"start": -1, "stop": 3, "width": None},
        {"start": 0, "stop": 4, "width": -1},
    ],
    "variant.IntSet_with_width": [
        {"items": [300], "width": 2},
        {"items": [], "width": 0},
        {"items": [1], "width": -3},
    ],
    "variant.IntSet_new": [
        {"items": []},
        {"items": [0]},
        {"items": [5, 1, 3]},
        {"items": [3, 3, 1]},
        {"items": [-1]},
    ],
    "variant.Pattern_new": [
        {"tokens": list("*1.0000")},
        {"tokens": list("1.*")},
        {"tokens": list("*1.*.*.0000.1111.?01?")},
        {"tokens": list("1?1")},
        {"tokens": list(".1111")},
        {"tokens": list("1111.")},
        {"tokens": list("11111")},
        {"tokens": list("1.1")},
        {"tokens": list("**")},
        {"tokens": list("1|0")},
        {"tokens": []},
    ],
    "variant.diagram_cells": [{"cells": list("1?0")}, {"cells": []}],
    "bitpattern.bdd.diagram": [{"bits": ""}, {"bits": "*"}, {"bits": "1.0"}],
    "bitpattern.bdd.interval": [{"start": 3, "stop": 17, "width": 5}, {"start": 0, "stop": 8, "width": 3}],
    "bitpattern.bdd.count_repr": [{"total": t} for t in (0, 512, 1023, 1024, 2**64 - 1, 2**64, 2**127)],
}

FLOAT_EXAMPLES = {
    "variant.Float_encode": [
        {"kind": "float16", "value": 65504.0},
        {"kind": "float16", "value": 65520.0},
        {"kind": "float16", "value": 1 + 2**-11},
        {"kind": "float16", "value": 1 + 3 * 2**-11},
        {"kind": "float16", "value": -1e-10},
        {"kind": "float16", "value": -0.0},
        {"kind": "float16", "value": float("inf")},
        {"kind": "float16", "value": float("-nan")},
        {"kind": "float32", "value": 1e39},
    ],
    "variant.Float_range": [
        {"kind": "float16", "start": 1.0, "stop": 2.0},
        {"kind": "float32", "start": 1.0, "stop": 2.0},
        {"kind": "float16", "start": None, "stop": None},
        {"kind": "float16", "start": 0.0, "stop": None},
        {"kind": "float16", "start": 0.0, "stop": float("inf")},
        {"kind": "float16", "start": -0.0, "stop": None},
        {"kind": "float16", "start": -0.0, "stop": 0.0},
        {"kind": "float16", "start": None, "stop": 0.0},
        {"kind": "float16", "start": 1.00001, "stop": 1.002},
        {"kind": "float16", "start": 1e10, "stop": None},
        {"kind": "float16", "start": -1e10, "stop": -65504.0},
        {"kind": "float16", "start": float("nan"), "stop": None},
    ],
    "variant.FloatFN_encode": [{"value": 464.0}, {"value": 465.0}, {"value": 0.3}, {"value": float("inf")}],
}

test_bitpattern = spectest.check("bitpattern.spec", modules=MODULES, examples=EXAMPLES)
test_floats = spectest.check("floats.spec", modules=FLOAT_MODULES, examples=FLOAT_EXAMPLES)

CHAR_MODULES = {
    "Char": "bitpattern.codecs.Char",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.Char_new": "bitpattern.codecs.Char",
    "variant.Char_char": "support.char_codec",
    "variant.Char_encode_int": "bitpattern.codecs.Char.encode",
}

test_chars = spectest.check("chars.spec", modules=CHAR_MODULES)

MAC_MODULES = {
    "MAC": "bitpattern.codecs.MAC",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.MAC_codec": "support.mac_codec",
    "variant.MAC_encode": "support.mac_encode",
    "variant.MAC_encode_int": "bitpattern.codecs.mac.encode",
    "variant.MAC_decode": "support.mac_decode",
    "variant.MAC_min": "support.mac_min",
    "variant.MAC_max": "support.mac_max",
    "variant.MAC_set": "support.mac_set",
    "variant.MAC_oui": "support.mac_oui",
    "variant.MAC_oui_other_form": "support.mac_oui_other_form",
}

UUID_MODULES = {
    "UUIDCodec": "bitpattern.codecs.UUIDCodec",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.UUID_codec": "support.uuid_codec",
    "variant.UUID_dtype": "support.uuid_dtype",
    "variant.UUID_encode": "bitpattern.codecs.uuid128.encode",
    "variant.UUID_encode_text": "support.uuid_encode_text",
    "variant.UUID_encode_garbage": "bitpattern.codecs.uuid128.encode",
    "variant.UUID_encode_int": "bitpattern.codecs.uuid128.encode",
    "variant.UUID_decode": "bitpattern.codecs.uuid128.decode",
    "variant.UUID_rfc9562": "support.uuid_rfc9562",
    "variant.UUID_version": "support.uuid_version",
    "variant.UUID_in_version": "support.uuid_in_version",
    "variant.UUID_uuid4_in_version4": "support.uuid4_in_version4",
}

DATE_MODULES = {
    "Date": "bitpattern.codecs.Date",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.Date_codec": "support.date_codec",
    "variant.Date_encode": "bitpattern.codecs.dates.encode",
    "variant.Date_encode_datetime": "bitpattern.codecs.dates.encode",
    "variant.Date_encode_int": "bitpattern.codecs.dates.encode",
    "variant.Date_decode": "bitpattern.codecs.dates.decode",
    "variant.Date_min": "support.date_min",
    "variant.Date_max": "support.date_max",
    "variant.Date_all": "support.date_all",
    "variant.Date_range": "bitpattern.codecs.dates.range",
}

test_macs = spectest.check("macs.spec", modules=MAC_MODULES)
test_uuids = spectest.check("uuids.spec", modules=UUID_MODULES)
test_dates = spectest.check("dates.spec", modules=DATE_MODULES)

IP_MODULES = {
    "IP": "bitpattern.codecs.IP",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.IP_codec": "support.ip_codec",
    "variant.ipv4_encode_address": "support.ipv4_encode",
    "variant.ipv6_encode_address": "support.ipv6_encode",
    "variant.ipv4_encode_text": "support.ipv4_encode_text",
    "variant.ipv6_encode_text": "support.ipv6_encode_text",
    "variant.ipv4_encode_int": "support.ipv4_encode",
    "variant.ipv6_encode_int": "support.ipv6_encode",
    "variant.ipv4_encode_ipv6_address": "support.ipv4_encode",
    "variant.ipv6_encode_ipv4_address": "support.ipv6_encode",
    "variant.ip_encode_float": "support.ip_encode_float",
    "variant.ip_encode_bytes": "support.ip_encode_bytes",
    "variant.ip_encode_garbage": "support.ip_encode_garbage",
    "variant.ipv4_encode_with_prefix": "support.ipv4_encode_with_prefix",
    "variant.ipv6_encode_with_prefix": "support.ipv6_encode_with_prefix",
    "variant.ipv4_decode": "bitpattern.codecs.ipv4.decode",
    "variant.ipv6_decode": "bitpattern.codecs.ipv6.decode",
    "variant.ipv4_min": "support.ipv4_min",
    "variant.ipv4_max": "support.ipv4_max",
    "variant.ipv6_min": "support.ipv6_min",
    "variant.ipv6_max": "support.ipv6_max",
    "variant.ip_range": "support.ip_range",
    "variant.ip_cidr": "support.ip_cidr",
    "variant.ip_cidr_bare": "support.ip_cidr_bare",
    "variant.ip_networks": "support.ip_networks",
    "variant.ip_networks_other_codec": "support.ip_networks_other_codec",
}

test_ips = spectest.check("ips.spec", modules=IP_MODULES)

TUPLE_MODULES = {
    "Int": "bitpattern.codecs.Int",
    "Tuple": "bitpattern.codecs.Tuple",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "bitpattern.IntSet.range": "support.intset_range",
    "variant.Tuple_new": "support.tuple_new",
    "variant.Tuple_empty": "support.tuple_empty",
    "variant.Tuple_encode": "support.tuple_encode",
    "variant.Tuple_encode_list": "support.tuple_encode_list",
    "variant.Tuple_encode_length": "support.tuple_encode_length",
    "variant.Tuple_decode": "support.tuple_decode",
    "variant.Tuple_product": "support.tuple_product",
    "variant.Tuple_product_nothing": "support.tuple_product_nothing",
    "variant.Tuple_mul": "support.tuple_mul",
    "variant.Tuple_mul_foreign": "support.tuple_mul_foreign",
    "variant.Tuple_project": "support.tuple_project",
    "variant.Tuple_project_non_tuple": "support.tuple_project_non_tuple",
}

test_tuples = spectest.check("tuples.spec", modules=TUPLE_MODULES)

ENUM_MODULES = {
    "variant.Members_codec": "support.members_codec",
    "variant.Members_encode": "support.members_encode",
    "variant.Members_encode_alias": "support.members_encode_alias",
    "variant.Members_encode_raw": "support.members_encode_raw",
    "variant.Members_encode_unlisted_combination": "support.members_encode_unlisted_combination",
    "variant.Members_decode": "support.members_decode",
    "variant.Members_dtype": "support.members_dtype",
    "variant.Members_all": "support.members_all",
    "variant.Members_set": "support.members_set",
    "variant.Members_iterate": "support.members_iterate",
    "variant.Members_invert": "support.members_invert",
    "variant.Members_exported": "support.members_exported",
    "variant.Flags_codec": "support.flags_codec",
    "variant.Flags_all": "support.flags_all",
    "variant.Flags_encode": "support.flags_encode",
    "variant.Flags_encode_int": "support.flags_encode_int",
    "variant.Flags_decode": "support.flags_decode",
    "variant.Flags_having": "support.flags_having",
    "variant.Flags_lacking": "support.flags_lacking",
}

test_enums = spectest.check("enums.spec", modules=ENUM_MODULES)

DATETIME_MODULES = {
    "DateTime": "bitpattern.codecs.DateTime",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.DT_codec": "support.dt_codec",
    "variant.DT_utc_equals": "support.dt_utc_equals",
    "variant.DT_encode": "support.dt_encode",
    "variant.DT_encode_date": "support.dt_encode",
    "variant.DT_decode": "support.dt_decode",
    "variant.DT_all": "support.dt_all",
    "variant.DT_range": "support.dt_range",
}

test_datetimes = spectest.check("datetimes.spec", modules=DATETIME_MODULES)

FLOATFN_MODULES = {
    "FloatFN": "bitpattern.codecs.FloatFN",
    "BDDSet": "bitpattern.codecs.BDDSet",
    "variant.FloatFN_decode": "support.float_fn_decode",
    "variant.FloatFN_set": "support.floatfn_set",
    "variant.FloatFN_range": "support.floatfn_range",
}

test_floatfn = spectest.check(
    "floatfn.spec",
    modules=FLOATFN_MODULES,
    examples={"variant.FloatFN_range": [{"start": 1.0, "stop": 2.0}, {"start": None, "stop": None}, {"start": float("nan"), "stop": None}]},
)
