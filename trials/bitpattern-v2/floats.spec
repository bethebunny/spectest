spec floats

# Formal spec of bitpattern 0.3.0's float codecs (section 3.5). The BDDSet record of this
# file holds sets of a Float codec; the other codecs have their own files.
#
# A codec is named by `kind`, one of the formats of the table, and test_floats.py maps each
# variant to a call on the codec that bitpattern.codecs has under that name (support.py).

prelude "floats.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)
  observe head(n: int): list<int> = builtins.list(itertools.islice(self, n))

record Float { width: u8, name: string, exponent: u8, format: string }
record FloatFN { width: u8, name: string, exponent: u8 }
record BDDSet { codec: Float, storage: bitpattern.intset.IntSet }

# -- the codecs --------------------------------------------------------------------

fn variant.Float_codec(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2") -> Float
  ensures layout: result.width == fwidth(kind) and result.exponent == fexp(kind)
  ensures name: result.name == kind
  ensures mantissa: result.width - 1 - result.exponent == fman(kind)

fn variant.FloatFN_codec() -> FloatFN
  ensures layout: result.width == 8 and result.exponent == 4 and result.name == "float8_e4m3fn"

fn variant.Float_dtype(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2" | "float8_e4m3fn") -> "FLOAT64" | "FLOAT32" | "FLOAT16" | "BFLOAT16" | "FLOAT8_E5M2" | "FLOAT8_E4M3FN"
  ensures table: result == (if kind == "float64" then "FLOAT64" else if kind == "float32" then "FLOAT32" else if kind == "float16" then "FLOAT16" else if kind == "bfloat16" then "BFLOAT16" else if kind == "float8_e5m2" then "FLOAT8_E5M2" else "FLOAT8_E4M3FN")

# min == -max, the most negative and largest finite values.
fn variant.Float_max(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2") -> f64
  ensures largest_finite: real(result) == (2 ** (fman(kind) + 1) - 1) * 2 ** (2 ** fexp(kind) - 2) / 2 ** (fbias(kind) + fman(kind))
  ensures table: kind == "float16" implies real(result) == 65504
  ensures table_e5m2: kind == "float8_e5m2" implies real(result) == 57344

fn variant.Float_min(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2") -> f64
  ensures most_negative: real(result) == -((2 ** (fman(kind) + 1) - 1) * 2 ** (2 ** fexp(kind) - 2) / 2 ** (fbias(kind) + fman(kind)))
  relates negated_max: same(result, -variant.Float_max(kind))

fn variant.FloatFN_max() -> f64
  ensures largest_finite: real(result) == 448

# -- encode and decode -------------------------------------------------------------

# Rounds to the nearest value of the format, ties to even; a finite value that rounds
# beyond max raises ValueError; infinities keep their sign; zeros and NaNs keep theirs.
fn variant.Float_encode(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2", value: f64) -> int
  raises ValueError when is_finite(value) and can_round(kind) and round_inf(kind, value)
  may_raise ValueError when is_finite(value) and not can_round(kind)
  ensures universe: 0 <= result and result < 2 ** fwidth(kind)
  ensures nan: is_nan(value) implies is_nan_bits(kind, result) and (sign_field(kind, result) == 1) == signbit(value)
  ensures infinity: is_inf(value) implies result == inf_bits(kind, signbit(value))
  ensures zero: is_zero(value) implies result == (if signbit(value) then 2 ** (fwidth(kind) - 1) else 0)
  ensures rounds_to_nearest_even: is_finite(value) and not is_zero(value) and can_round(kind) implies result == encoded(kind, value, signbit(value))
  ensures sign: not is_nan(value) implies (sign_field(kind, result) == 1) == signbit(value)

# Integers are accepted too, and rounded alike.
fn variant.Float_encode_int(kind: "float64" | "float32" | "float16" | "bfloat16", value: int) -> int
  raises ValueError when round_inf_i(kind, value)
  ensures rounds_to_nearest_even: result == encoded_i(kind, value, value < 0)

# Strings and None are not numbers.
fn variant.Float_encode_string(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2", value: string) -> int
  raises TypeError when true

fn variant.Float_decode(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2", b: int) -> f64
  raises IndexError when b < 0 or b >= 2 ** fwidth(kind)
  ensures nan: is_nan_bits(kind, b) implies is_nan(result) and signbit(result) == (sign_field(kind, b) == 1)
  ensures infinity: is_inf_bits(kind, b) implies is_inf(result) and signbit(result) == (sign_field(kind, b) == 1)
  ensures zero: is_zero_bits(kind, b) implies is_zero(result) and signbit(result) == (sign_field(kind, b) == 1)
  ensures finite_value: not is_nan_bits(kind, b) and not is_inf_bits(kind, b) and not is_zero_bits(kind, b) implies real(result) == value_of(kind, b)
  ensures subnormal: kind == "float64" and is_sub_bits(kind, b) implies is_subnormal(result)
  relates roundtrip: not is_nan_bits(kind, b) implies variant.Float_encode(kind, result) == b
  relates nan_keeps_sign: is_nan_bits(kind, b) implies (sign_field(kind, variant.Float_encode(kind, result)) == sign_field(kind, b) and is_nan_bits(kind, variant.Float_encode(kind, result)))

# float8_e4m3fn: no infinities; only the all-ones patterns are NaN, one per sign.
fn variant.FloatFN_decode(b: u8) -> f64
  ensures nan: is_nan_bits("float8_e4m3fn", b) implies is_nan(result) and signbit(result) == (b >= 128)
  ensures finite_value: not is_nan_bits("float8_e4m3fn", b) and not is_zero_bits("float8_e4m3fn", b) implies real(result) == value_of("float8_e4m3fn", b)
  ensures top_exponent_is_normal: b == 126 implies real(result) == 448
  relates roundtrip: not is_nan_bits("float8_e4m3fn", b) implies variant.FloatFN_encode(result) == b

fn variant.FloatFN_encode(value: f64) -> int
  raises ValueError when is_inf(value)
  may_raise ValueError when is_finite(value) and (real(value) > 448 or real(value) < -448)
  ensures universe: 0 <= result and result < 256
  ensures nan: is_nan(value) implies is_nan_bits("float8_e4m3fn", result) and (result >= 128) == signbit(value)
  ensures zero: is_zero(value) implies result == (if signbit(value) then 128 else 0)
  ensures sign: not is_nan(value) implies (result >= 128) == signbit(value)
  ensures never_nan_for_finite: is_finite(value) implies not is_nan_bits("float8_e4m3fn", result)

# -- named sets and ranges ---------------------------------------------------------

# sign_clear, sign_set, zeros, positive (with +inf), negative (with -inf), nonnegative,
# subnormal, infinities, nan and finite, each a BDDSet of the codec.
fn variant.Float_set(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2", name: "all" | "sign_clear" | "sign_set" | "zeros" | "positive" | "negative" | "nonnegative" | "subnormal" | "infinities" | "nan" | "finite") -> BDDSet
  ensures codec: result.codec.width == fwidth(kind) and result.codec.name == kind
  ensures width: result.storage.width == fwidth(kind)
  ensures size: result.storage.size == named_size(kind, name)
  ensures members: all(b in patterns(kind): result.storage.has(b) == in_named(kind, name, b))

# finite, infinities and nan partition all; positive, negative, zeros and nan partition all.
fn variant.Float_partition(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2") -> int
  ensures finite_inf_nan_sizes: variant.Float_set(kind, "finite").storage.size + variant.Float_set(kind, "infinities").storage.size + variant.Float_set(kind, "nan").storage.size == variant.Float_set(kind, "all").storage.size
  ensures pos_neg_zero_nan_sizes: variant.Float_set(kind, "positive").storage.size + variant.Float_set(kind, "negative").storage.size + variant.Float_set(kind, "zeros").storage.size + variant.Float_set(kind, "nan").storage.size == 2 ** fwidth(kind)
  ensures finite_inf_nan_disjoint: all(b in patterns(kind): (if variant.Float_set(kind, "finite").storage.has(b) then 1 else 0) + (if variant.Float_set(kind, "infinities").storage.has(b) then 1 else 0) + (if variant.Float_set(kind, "nan").storage.has(b) then 1 else 0) == 1)
  ensures pos_neg_zero_nan_disjoint: all(b in patterns(kind): (if variant.Float_set(kind, "positive").storage.has(b) then 1 else 0) + (if variant.Float_set(kind, "negative").storage.has(b) then 1 else 0) + (if variant.Float_set(kind, "zeros").storage.has(b) then 1 else 0) + (if variant.Float_set(kind, "nan").storage.has(b) then 1 else 0) == 1)
  ensures positive_negative_disjoint: all(b in patterns(kind): not (variant.Float_set(kind, "positive").storage.has(b) and variant.Float_set(kind, "negative").storage.has(b)))
  ensures nonnegative_is_positive_or_zeros: all(b in patterns(kind): variant.Float_set(kind, "nonnegative").storage.has(b) == (variant.Float_set(kind, "positive").storage.has(b) or variant.Float_set(kind, "zeros").storage.has(b)))
  ensures float16_sizes: kind == "float16" implies variant.Float_set(kind, "all").storage.size == 65536 and variant.Float_set(kind, "nan").storage.size == 2046 and variant.Float_set(kind, "subnormal").storage.size == 2046 and variant.Float_set(kind, "finite").storage.size == 63488 and variant.Float_set(kind, "positive").storage.size == 31744 and variant.Float_set(kind, "nonnegative").storage.size == 31746
  ensures e5m2_nan_size: kind == "float8_e5m2" implies variant.Float_set(kind, "nan").storage.size == 6

# range(start, stop): the non-NaN values with start <= v < stop in numeric order, -0.0
# just below 0.0; None leaves an end open; bounds need not be representable.
fn variant.Float_range(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2", start: option<f64>, stop: option<f64>) -> BDDSet
  raises ValueError when (is_some(start) and is_nan(unwrap(start))) or (is_some(stop) and is_nan(unwrap(stop)))
  ensures codec: result.codec.width == fwidth(kind)
  ensures members: all(b in patterns(kind): is_nan_bits(kind, b) or in_interval(variant.Float_decode(kind, b), start, stop) == result.storage.has(b))
  ensures no_nan: all(b in patterns(kind): is_nan_bits(kind, b) implies not result.storage.has(b))
  ensures unbounded: is_none(start) and is_none(stop) implies result.storage.size == 2 ** fwidth(kind) - named_size(kind, "nan")
  ensures binade: is_some(start) and is_some(stop) and real(unwrap(start)) == 1 and real(unwrap(stop)) == 2 implies result.storage.size == 2 ** fman(kind)
  ensures infinity_closed_at_none: is_some(start) and real(unwrap(start)) == 0 and not signbit(unwrap(start)) and is_none(stop) implies result.storage.has(inf_bits(kind, false)) and not result.storage.has(2 ** (fwidth(kind) - 1))
  ensures infinity_open_at_inf: is_some(start) and real(unwrap(start)) == 0 and is_some(stop) and is_inf(unwrap(stop)) and not signbit(unwrap(stop)) implies not result.storage.has(inf_bits(kind, false))
  ensures negative_zero_start: is_some(start) and is_zero(unwrap(start)) and signbit(unwrap(start)) and is_none(stop) implies result.storage.has(0) and result.storage.has(2 ** (fwidth(kind) - 1))

# Iteration is in encoding order: the i-th member of all is decode(i).
fn variant.Float_getitem(kind: "float64" | "float32" | "float16" | "bfloat16" | "float8_e5m2", i: u16) -> f64
  requires i < 2 ** fwidth(kind)
  ensures decoded: same(result, variant.Float_decode(kind, i))
