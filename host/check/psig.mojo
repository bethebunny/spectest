"""The system prelude's signature records: arity, type arguments, keyword arguments,
the human-readable shape used in messages, and which typing rule applies (see sigs.mojo).
"""


# Typing rules, by family.
comptime T_FLOAT_PRED = 0
comptime T_BITS = 1
comptime T_SAME_FLOAT = 2
comptime T_ULP = 3
comptime T_QE = 4
comptime T_QERR_PART = 5
comptime T_SAME = 6
comptime T_IEEE_EQ = 7
comptime T_REAL = 8
comptime T_ROUND = 9
comptime T_WRAP = 10
comptime T_FITS = 11
comptime T_MP = 12
comptime T_CR = 13
comptime T_LE_UINT = 14
comptime T_LEN = 15
comptime T_SORTED = 16
comptime T_IS_SORTED = 17
comptime T_TWO_LISTS = 18
comptime T_DISTINCT = 19
comptime T_INDEX_OF = 20
comptime T_KEYS = 21
comptime T_VALUES = 22
comptime T_RANGE = 23
comptime T_SOME = 24
comptime T_OPT_PRED = 25
comptime T_UNWRAP = 26
comptime T_VALID_UTF8 = 27
comptime T_CODEPOINTS = 28
comptime T_FRESH = 29
comptime T_TWO_MODELS = 30
comptime T_EQ = 31
comptime T_BIT_LENGTH = 32
comptime T_FROM_CODEPOINTS = 33


struct PreludeSig(Copyable, Movable):
    var name: String
    var shape: String
    var lo: Int
    var hi: Int
    var type_args: Int
    var optional_type_args: Bool
    var has_kwargs: Bool
    var typer: Int

    def __init__(
        out self,
        name: String,
        shape: String,
        arity: Int,
        typer: Int,
        type_args: Int = 0,
        optional_type_args: Bool = False,
        has_kwargs: Bool = False,
    ):
        self.name = name
        self.shape = shape
        self.lo = arity
        self.hi = arity
        self.type_args = type_args
        self.optional_type_args = optional_type_args
        self.has_kwargs = has_kwargs
        self.typer = typer


def _starts(name: String, prefix: StringSlice) -> Bool:
    return name.startswith(prefix)


def make_sig(name: String) -> PreludeSig:
    if (
        name == "is_nan"
        or name == "is_inf"
        or name == "is_finite"
        or name == "is_zero"
        or name == "is_subnormal"
        or name == "signbit"
    ):
        return PreludeSig(name, name + "(x: T) -> bool", 1, T_FLOAT_PRED)
    if name == "bits":
        return PreludeSig(name, "bits(x: T) -> int", 1, T_BITS)
    if name == "next_up" or name == "next_down":
        return PreludeSig(name, name + "(x: T) -> T", 1, T_SAME_FLOAT)
    if name == "ulp":
        return PreludeSig(name, "ulp<T>(r: real) -> real", 1, T_ULP, type_args=1)
    if name == "qe":
        return PreludeSig(
            name,
            "qe(a: T, b: T) -> qerr (or qe<T>(a, b))",
            2,
            T_QE,
            type_args=1,
            optional_type_args=True,
        )
    if name == "steps" or name == "nans":
        return PreludeSig(name, name + "(e: qerr) -> int", 1, T_QERR_PART)
    if name == "same":
        return PreludeSig(name, "same(a: A, b: A) -> bool", 2, T_SAME)
    if name == "ieee_eq":
        return PreludeSig(name, "ieee_eq(a: T, b: T) -> bool", 2, T_IEEE_EQ)
    if name == "real":
        return PreludeSig(name, "real(x: real) -> real", 1, T_REAL)
    if name == "round":
        return PreludeSig(name, "round<T>(r: real) -> T", 1, T_ROUND, type_args=1)
    if name == "wrap":
        return PreludeSig(name, "wrap<I>(n: int) -> I", 1, T_WRAP, type_args=1)
    if name == "fits":
        return PreludeSig(name, "fits<I>(n: real) -> bool", 1, T_FITS, type_args=1)
    if _starts(name, "mp."):
        return PreludeSig(name, name + "(x: real) -> real", 1, T_MP)
    if _starts(name, "cr."):
        return PreludeSig(name, name + "(x: T) -> T", 1, T_CR)
    if name == "le_uint":
        return PreludeSig(name, "le_uint(b: bytes) -> int", 1, T_LE_UINT)
    if name == "len":
        return PreludeSig(
            name, "len(x: list<A> | string | bytes | map<K, V>) -> int", 1, T_LEN
        )
    if name == "sorted":
        return PreludeSig(name, "sorted(xs: list<A>) -> list<A>", 1, T_SORTED)
    if name == "is_sorted":
        return PreludeSig(name, "is_sorted(xs: list<A>) -> bool", 1, T_IS_SORTED)
    if name == "is_permutation" or name == "is_subsequence":
        return PreludeSig(
            name, name + "(a: list<A>, b: list<A>) -> bool", 2, T_TWO_LISTS
        )
    if name == "distinct":
        return PreludeSig(name, "distinct(xs: list<A>) -> bool", 1, T_DISTINCT)
    if name == "index_of":
        return PreludeSig(name, "index_of(xs: list<A>, x: A) -> int", 2, T_INDEX_OF)
    if name == "keys":
        return PreludeSig(name, "keys(m: map<K, V>) -> list<K>", 1, T_KEYS)
    if name == "values":
        return PreludeSig(name, "values(m: map<K, V>) -> list<V>", 1, T_VALUES)
    if name == "range":
        return PreludeSig(name, "range(a: int, b: int) -> list<int>", 2, T_RANGE)
    if name == "some":
        return PreludeSig(name, "some(x: A) -> option<A>", 1, T_SOME)
    if name == "is_some" or name == "is_none":
        return PreludeSig(name, name + "(o: option<A>) -> bool", 1, T_OPT_PRED)
    if name == "unwrap":
        return PreludeSig(name, "unwrap(o: option<A>) -> A", 1, T_UNWRAP)
    if name == "valid_utf8":
        return PreludeSig(name, "valid_utf8(b: bytes) -> bool", 1, T_VALID_UTF8)
    if name == "codepoints":
        return PreludeSig(name, "codepoints(s: string) -> list<int>", 1, T_CODEPOINTS)
    if name == "fresh":
        return PreludeSig(name, "fresh(h: model) -> bool", 1, T_FRESH)
    if name == "same_object" or name == "shares_memory":
        return PreludeSig(
            name, name + "(a: model, b: model) -> bool", 2, T_TWO_MODELS
        )
    if name == "eq":
        return PreludeSig(
            name,
            'eq(a: A, b: A, float="bits"|"ieee"|"nan_any", order="exact"|"ignore")'
            " -> bool",
            2,
            T_EQ,
            has_kwargs=True,
        )
    if name == "bit_length":
        return PreludeSig(name, "bit_length(n: int) -> int", 1, T_BIT_LENGTH)
    return PreludeSig(
        name, "from_codepoints(xs: list<int>) -> string", 1, T_FROM_CODEPOINTS
    )


struct CallInfo(Copyable, Movable):
    """What a typing rule sees of one call."""

    var name: String
    var args: List[Int]
    var nodes: List[Int]
    var kw_keys: List[String]
    var kw_types: List[Int]
    var kw_nodes: List[Int]
    var targs: List[Int]

    def __init__(out self, name: String):
        self.name = name
        self.args = List[Int]()
        self.nodes = List[Int]()
        self.kw_keys = List[String]()
        self.kw_types = List[Int]()
        self.kw_nodes = List[Int]()
        self.targs = List[Int]()


