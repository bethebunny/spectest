"""The prelude signature table is a contract with spectest.prelude; keep it in sync."""

from spectest.lang.parser import GENERIC_FNS
from spectest.lang.signatures import (
    GENERIC_PRELUDE,
    OPTIONAL_TYPE_ARGS,
    PRELUDE_SIGNATURES,
    contains_float,
    join,
    non_eq_part,
    ordered,
    satisfies,
    type_constant,
)
from spectest.types import (
    BOOL,
    INT,
    REAL,
    STRING,
    FixedIntT,
    FloatT,
    ListT,
    LiteralT,
    ModelT,
    OptionT,
    SetT,
    TupleT,
    TypeVarT,
)

CONTRACT = {
    "is_nan", "is_inf", "is_finite", "is_zero", "is_subnormal", "signbit", "bits",
    "next_up", "next_down", "ulp", "qe", "steps", "nans", "same", "ieee_eq", "real", "round",
    "wrap", "fits", "mp.sqrt", "mp.exp", "mp.log", "mp.sin", "mp.cos", "mp.tan",
    "mp.atan", "cr.sqrt", "cr.exp", "cr.log", "cr.sin", "cr.cos", "cr.tan", "cr.atan", "le_uint", "len", "sorted", "is_sorted", "is_permutation",
    "is_subsequence", "distinct", "index_of", "keys", "values", "range", "some",
    "is_some", "is_none", "unwrap", "valid_utf8", "codepoints", "fresh", "same_object",
    "shares_memory", "eq",
}  # fmt: skip

F64 = FloatT("f64")
I32 = FixedIntT(32, True)


def test_table_matches_the_contract():
    assert set(PRELUDE_SIGNATURES) == CONTRACT


def test_table_matches_the_prelude_registry():
    from spectest.prelude import PRELUDE

    assert set(PRELUDE) == set(PRELUDE_SIGNATURES)
    for name, sig in PRELUDE_SIGNATURES.items():
        assert PRELUDE[name].needs_ctx == sig.needs_ctx, name
        assert PRELUDE[name].needs_types == (sig.type_args > 0), name


def test_generic_functions():
    assert set(GENERIC_FNS) == set(GENERIC_PRELUDE) == {"wrap", "fits", "round", "ulp", "qe"}
    for name, sig in PRELUDE_SIGNATURES.items():
        assert (sig.type_args == 1) == (name in GENERIC_PRELUDE), name
        assert sig.optional_type_args == (name in OPTIONAL_TYPE_ARGS), name
    assert OPTIONAL_TYPE_ARGS == ("qe",)


def test_arity_kwargs_and_context():
    two = {
        "qe",
        "same",
        "ieee_eq",
        "is_permutation",
        "is_subsequence",
        "index_of",
        "range",
        "same_object",
        "shares_memory",
        "eq",
    }
    for name, sig in PRELUDE_SIGNATURES.items():
        assert sig.arity == ((2, 2) if name in two else (1, 1)), name
        assert sig.kwargs == (("float", "order") if name == "eq" else ()), name
        assert sig.needs_ctx == (name in {"fresh", "same_object", "shares_memory", "eq"}), name
        assert sig.shape.startswith(name), name


def test_join():
    assert join(I32, FixedIntT(8, False)) == INT
    assert join(I32, REAL) == REAL
    assert join(F64, F64) == F64
    assert join(F64, INT) is None
    assert join(F64, FloatT("f32")) is None
    assert join(OptionT(FixedIntT(64, False)), OptionT(FixedIntT(8, False))) == OptionT(INT)
    assert join(LiteralT(("a",)), STRING) == STRING
    assert join(TupleT((INT, BOOL)), TupleT((I32, BOOL))) == TupleT((INT, BOOL))
    assert join(TupleT((INT,)), TupleT((INT, INT))) is None
    assert join(ModelT("M"), ModelT("N")) is None


def test_equality_and_order_predicates():
    assert non_eq_part(ListT(OptionT(F64))) == F64
    assert non_eq_part(ListT(TupleT((INT, ModelT("M"))))) == ModelT("M")
    assert non_eq_part(TypeVarT("T")) == TypeVarT("T")
    assert non_eq_part(TypeVarT("T", "Eq")) is None
    assert ordered(ListT(TupleT((INT, STRING))))
    assert not ordered(OptionT(INT))
    assert not ordered(TypeVarT("T", "Eq"))
    assert satisfies(I32, "Ord") and satisfies(STRING, "Eq")
    assert not satisfies(F64, "Eq")
    assert not satisfies(TypeVarT("T", "Eq"), "Ord")
    assert satisfies(TypeVarT("T", "Ord"), "Eq")
    assert contains_float(ListT(OptionT(F64))) and not contains_float(ListT(INT))


def test_type_constants():
    assert type_constant(F64, "max") == F64
    assert type_constant(F64, "nan") == SetT(F64)
    assert type_constant(I32, "min") == INT
    assert type_constant(I32, "all") == SetT(I32)
    assert type_constant(I32, "nan") is None
    assert type_constant(BOOL, "all") == SetT(BOOL)
    assert type_constant(INT, "max") is None
