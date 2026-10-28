"""The system prelude's functions, by name and id.

The checker resolves a prelude call to its id (Resolution kind R_PRELUDE) and types
it; the prelude package evaluates it by id. Ids are positions in `NAMES` and never
change meaning: a new function goes at the end.

`fresh`, `same_object` and `shares_memory` ask the host about identity, so the
evaluator answers them itself rather than the prelude.
"""

comptime NAMES: Array[StaticString, 56] = [
    "bits", "codepoints", "cr.atan", "cr.cos", "cr.exp", "cr.log", "cr.sin", "cr.sqrt",
    "cr.tan", "distinct", "eq", "fits", "fresh", "ieee_eq", "index_of", "is_finite",
    "is_inf", "is_nan", "is_none", "is_permutation", "is_some", "is_sorted",
    "is_subnormal", "is_subsequence", "is_zero", "keys", "le_uint", "len", "mp.atan",
    "mp.cos", "mp.exp", "mp.log", "mp.sin", "mp.sqrt", "mp.tan", "nans", "next_down",
    "next_up", "qe", "range", "real", "round", "same", "same_object", "shares_memory",
    "signbit", "some", "sorted", "steps", "ulp", "unwrap", "valid_utf8", "values", "wrap",
    "bit_length", "from_codepoints",
]


def prelude_id(name: StringSlice) -> Optional[Int]:
    """The id of a prelude function, as written in specs (`len`, `mp.cos`), if it is one."""
    for id, word in enumerate(materialize[NAMES]()):
        if word == name:
            return id
    return None


def prelude_name(id: Int) -> String:
    var names = materialize[NAMES]()
    return String(names[id]) if 0 <= id < len(names) else "?"


def prelude_count() -> Int:
    return len(materialize[NAMES]())
