spec floatfn

# Formal spec of bitpattern 0.3.0's FloatFN codec float8_e4m3fn (section 3.5): no infinities,
# one NaN per sign (exponent and mantissa all ones). Its BDDSet record is not floats.spec's,
# whose codec is a Float, so its sets are here.

prelude "floats.prelude"

model bitpattern.intset.IntSet
  observe width: int
  observe size: int
  observe has(x: int): bool = operator.contains(self, x)

record FloatFN { width: u8, name: string, exponent: u8 }
record BDDSet { codec: FloatFN, storage: bitpattern.intset.IntSet }

fn variant.FloatFN_decode(b: u8) -> f64
  ensures nan: is_nan_bits("float8_e4m3fn", b) implies is_nan(result)
  ensures finite_value: not is_nan_bits("float8_e4m3fn", b) and not is_zero_bits("float8_e4m3fn", b) implies real(result) == value_of("float8_e4m3fn", b)

fn variant.FloatFN_set(name: "all" | "sign_clear" | "sign_set" | "zeros" | "positive" | "negative" | "nonnegative" | "subnormal" | "infinities" | "nan" | "finite") -> BDDSet
  ensures codec: result.codec.width == 8 and result.codec.exponent == 4 and result.storage.width == 8
  ensures size: result.storage.size == (if name == "all" then 256 else if name == "sign_clear" or name == "sign_set" then 128 else if name == "zeros" or name == "nan" then 2 else if name == "subnormal" then 14 else if name == "infinities" then 0 else if name == "positive" or name == "negative" then 126 else if name == "nonnegative" then 128 else 254)
  ensures members: all(b in range(0, 256): result.storage.has(b) == in_named("float8_e4m3fn", name, b))
  ensures nan_encodings: name == "nan" implies result.storage.has(127) and result.storage.has(255)
  ensures finite_count: name == "finite" implies result.storage.size == 254

# range(start, stop) as for Float; with no lower bound it starts at min.
fn variant.FloatFN_range(start: option<f64>, stop: option<f64>) -> BDDSet
  raises ValueError when (is_some(start) and is_nan(unwrap(start))) or (is_some(stop) and is_nan(unwrap(stop)))
  ensures members: all(b in range(0, 256): is_nan_bits("float8_e4m3fn", b) or in_interval(variant.FloatFN_decode(b), start, stop) == result.storage.has(b))
  ensures no_nan: not result.storage.has(127) and not result.storage.has(255)
  ensures binade: is_some(start) and is_some(stop) and real(unwrap(start)) == 1 and real(unwrap(stop)) == 2 implies result.storage.size == 8
  ensures unbounded: is_none(start) and is_none(stop) implies result.storage.size == 254
