spec libm_explore

# Questions rather than requirements: a failure reports the measured value.

fn cos16(x: f16) -> f16
  aggregate correctly_rounded: sum(v in f16.all: qe(cos16(v), cr.cos(v))) == 0

fn cos32(x: f32) -> f32
  aggregate worst_small: max(v in f32.range(-1, 1): qe(cos32(v), cr.cos(v))) <= 0
