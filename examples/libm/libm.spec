spec libm

# Elementary functions over IEEE floats. cr.* are correctly rounded references.

error DomainError

fn cos(x: f64) -> f64
  partition x
    nan       = f64.nan
    inf       = f64.inf
    zero      = f64.zero
    subnormal = f64.subnormal
    small     = f64.range(-0x1p-26, 0x1p-26) & f64.normal
    moderate  = f64.range(-0x1p20, 0x1p20) & f64.normal - small
    huge      = f64.normal - small - moderate
  ensures accurate: qe(result, cr.cos(x)) <= 1
  ensures bounded: is_finite(x) implies is_finite(result) and -1 <= result and result <= 1
  relates even: not is_nan(x) implies same(cos(-x), result)
  impl_defined nan_payload

fn cos32(x: f32) -> f32
  partition x
    nan       = f32.nan
    inf       = f32.inf
    zero      = f32.zero
    subnormal = f32.subnormal
    small     = f32.range(-0x1p-12, 0x1p-12) & f32.normal
    moderate  = f32.range(-0x1p10, 0x1p10) & f32.normal - small
    huge      = f32.normal - small - moderate
  ensures accurate: qe(result, cr.cos(x)) <= 1
  relates even: not is_nan(x) implies same(cos32(-x), result)
  impl_defined nan_payload

# 65,536 inputs: small enough to run on every bit pattern.
fn cos16(x: f16) -> f16
  ensures accurate: qe(result, cr.cos(x)) <= 1
  impl_defined nan_payload

# IEEE 754 requires sqrt to be correctly rounded.
fn sqrt(x: f64) -> f64
  partition x
    nan       = f64.nan
    negative  = f64.negative - f64.nan - f64.zero
    zero      = f64.zero
    subnormal = f64.subnormal & f64.positive
    normal    = f64.normal & f64.positive
    inf       = f64.inf & f64.positive
  may_raise DomainError when not is_nan(x) and x < 0
  ensures correctly_rounded: qe(result, cr.sqrt(x)) == 0
  ensures signed_zero: is_zero(x) implies same(result, x)
  relates monotone: is_finite(x) and x > 0 and is_finite(next_up(x)) implies
    let y = sqrt(next_up(x)) in is_finite(result) and is_finite(y) and real(result) <= real(y)
  impl_defined nan_payload
