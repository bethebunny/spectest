"""The system prelude's signatures: arity, type arguments, keyword arguments, the shape
messages show, and the typing rule that applies (see sigs.mojo). Also what a rule sees
of a call, and how it rejects one.
"""


__enum Rule(Equatable, ImplicitlyCopyable):
    """A typing rule, shared by the prelude functions of a family."""

    case FloatPredicate
    case Bits
    case SameFloat
    case Ulp
    case Qe
    case QerrPart
    case Same
    case IeeeEq
    case Real
    case Round
    case Wrap
    case Fits
    case Mp
    case Cr
    case LeUint
    case Len
    case Sorted
    case IsSorted
    case TwoLists
    case Distinct
    case IndexOf
    case Keys
    case Values
    case Range
    case Some
    case OptionPredicate
    case Unwrap
    case ValidUtf8
    case Codepoints
    case Fresh
    case TwoModels
    case Eq
    case BitLength
    case FromCodepoints

    def __eq__(self, other: Self) -> Bool:
        return self._get_enum_discriminant() == other._get_enum_discriminant()


struct PreludeSig(Copyable):
    var shape: String
    """The signature as messages show it, eg. `sorted(xs: list<A>) -> list<A>`."""
    var arity: Int
    var rule: Rule
    var type_args: Int
    var optional_type_args: Bool
    var has_kwargs: Bool

    def __init__(
        out self,
        shape: Some[Writable],
        arity: Int,
        rule: Rule,
        *,
        type_args: Int = 0,
        optional_type_args: Bool = False,
        has_kwargs: Bool = False,
    ):
        self.shape = String(shape)
        self.arity = arity
        self.rule = rule
        self.type_args = type_args
        self.optional_type_args = optional_type_args
        self.has_kwargs = has_kwargs


def prelude_sig(name: String) -> PreludeSig:
    match name:
        case "is_nan" | "is_inf" | "is_finite" | "is_zero" | "is_subnormal" | "signbit":
            return PreludeSig(t"{name}(x: T) -> bool", 1, .FloatPredicate)
        case "bits":
            return PreludeSig("bits(x: T) -> int", 1, .Bits)
        case "next_up" | "next_down":
            return PreludeSig(t"{name}(x: T) -> T", 1, .SameFloat)
        case "ulp":
            return PreludeSig("ulp<T>(r: real) -> real", 1, .Ulp, type_args=1)
        case "qe":
            return PreludeSig(
                "qe(a: T, b: T) -> qerr (or qe<T>(a, b))", 2, .Qe, type_args=1, optional_type_args=True
            )
        case "steps" | "nans":
            return PreludeSig(t"{name}(e: qerr) -> int", 1, .QerrPart)
        case "same":
            return PreludeSig("same(a: A, b: A) -> bool", 2, .Same)
        case "ieee_eq":
            return PreludeSig("ieee_eq(a: T, b: T) -> bool", 2, .IeeeEq)
        case "real":
            return PreludeSig("real(x: real) -> real", 1, .Real)
        case "round":
            return PreludeSig("round<T>(r: real) -> T", 1, .Round, type_args=1)
        case "wrap":
            return PreludeSig("wrap<I>(n: int) -> I", 1, .Wrap, type_args=1)
        case "fits":
            return PreludeSig("fits<I>(n: real) -> bool", 1, .Fits, type_args=1)
        case _ if name.startswith("mp."):
            return PreludeSig(t"{name}(x: real) -> real", 1, .Mp)
        case _ if name.startswith("cr."):
            return PreludeSig(t"{name}(x: T) -> T", 1, .Cr)
        case "le_uint":
            return PreludeSig("le_uint(b: bytes) -> int", 1, .LeUint)
        case "len":
            return PreludeSig("len(x: list<A> | string | bytes | map<K, V>) -> int", 1, .Len)
        case "sorted":
            return PreludeSig("sorted(xs: list<A>) -> list<A>", 1, .Sorted)
        case "is_sorted":
            return PreludeSig("is_sorted(xs: list<A>) -> bool", 1, .IsSorted)
        case "is_permutation" | "is_subsequence":
            return PreludeSig(t"{name}(a: list<A>, b: list<A>) -> bool", 2, .TwoLists)
        case "distinct":
            return PreludeSig("distinct(xs: list<A>) -> bool", 1, .Distinct)
        case "index_of":
            return PreludeSig("index_of(xs: list<A>, x: A) -> int", 2, .IndexOf)
        case "keys":
            return PreludeSig("keys(m: map<K, V>) -> list<K>", 1, .Keys)
        case "values":
            return PreludeSig("values(m: map<K, V>) -> list<V>", 1, .Values)
        case "range":
            return PreludeSig("range(a: int, b: int) -> list<int>", 2, .Range)
        case "some":
            return PreludeSig("some(x: A) -> option<A>", 1, .Some)
        case "is_some" | "is_none":
            return PreludeSig(t"{name}(o: option<A>) -> bool", 1, .OptionPredicate)
        case "unwrap":
            return PreludeSig("unwrap(o: option<A>) -> A", 1, .Unwrap)
        case "valid_utf8":
            return PreludeSig("valid_utf8(b: bytes) -> bool", 1, .ValidUtf8)
        case "codepoints":
            return PreludeSig("codepoints(s: string) -> list<int>", 1, .Codepoints)
        case "fresh":
            return PreludeSig("fresh(h: model) -> bool", 1, .Fresh)
        case "same_object" | "shares_memory":
            return PreludeSig(t"{name}(a: model, b: model) -> bool", 2, .TwoModels)
        case "eq":
            return PreludeSig(
                'eq(a: A, b: A, float="bits"|"ieee"|"nan_any", order="exact"|"ignore") -> bool',
                2,
                .Eq,
                has_kwargs=True,
            )
        case "bit_length":
            return PreludeSig("bit_length(n: int) -> int", 1, .BitLength)
        case _:
            return PreludeSig("from_codepoints(xs: list<int>) -> string", 1, .FromCodepoints)


@fieldwise_init
struct Arg(Copyable):
    """A typed argument of a call."""

    var key: String
    """Its keyword, or "" for a positional argument."""
    var type: Int
    var node: Int
    """Its expression."""


struct CallInfo(Copyable):
    """What a typing rule sees of one call."""

    var name: String
    var args: List[Arg]
    """The positional arguments, in order."""
    var keywords: List[Arg]
    var targs: List[Int]
    """The explicit type arguments, `T` of `round<T>(r)`."""

    def __init__(out self, var name: String):
        self.name = name^
        self.args = []
        self.keywords = []
        self.targs = []

    def arg_types(self) -> List[Int]:
        return [a.type for a in self.args]


struct TypingError(Copyable, Writable):
    """A call that its typing rule rejects."""

    var message: String
    var arg: Int
    """The position of the argument at fault, or -1."""
    var key: String
    """The keyword argument at fault, or ""."""

    def __init__(out self, message: Some[Writable], *, arg: Int = -1, var key: String = ""):
        self.message = String(message)
        self.arg = arg
        self.key = key^

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.message)
