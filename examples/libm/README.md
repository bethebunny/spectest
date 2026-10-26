# libm

`libm.spec` specifies four elementary functions over IEEE floats:
- `cos` over f64, with partitions from NaN to huge arguments;
- `cos32` over f32 and `cos16` over f16;
- `sqrt` over f64. IEEE 754 requires sqrt to be correctly rounded.

`explore.spec` asks two questions instead of stating requirements. A failure there reports the measured value.

The case exercises:
- quantized error: `qe(result, cr.cos(x)) <= 1` and `qe(result, cr.sqrt(x)) == 0`, against MPFR's correctly rounded references `cr.*`;
- IEEE special cases: NaN, signed zero, infinities, subnormals;
- bitpattern partitions of the input space (`f64.range(-0x1p-26, 0x1p-26) & f64.normal`, ...) and their coverage;
- `same`, `real()` and `next_up` in relations (`cos.even`, `sqrt.monotone`);
- `may_raise` mapped to Python exceptions with `errors=`;
- `impl_defined nan_payload`;
- exhaustive checking: `cos16` runs on all 65,536 inputs;
- `aggregate` clauses: an L1 budget over all of f16 and a maximum over an f32 range.

## Files

- `libm.spec`: the requirement.
- `explore.spec`: the questions.
- `libm_impls.py`: the seeded bugs, `cos(x) = sin(x + pi/2)` and `sqrt(x) = exp(log(x) / 2)`.
- `test_libm.py`: three conformances, plus plain tests that check FINDINGS.md with MPFR (gmpy2) directly, without spectest.
- `explore_libm.py`: the conformance over `explore.spec`. It does not match `test_*.py`, so pytest collects it only when it is named.
- `REPORT.md` and `EXPLORE.md`: written by the report commands below.
- `FINDINGS.md`: what the runs found, with independent checks.

## Conformances

| Conformance | Binds | Expected |
| --- | --- | --- |
| `test_math` | `math.cos`, `math.sqrt`; `ValueError` maps to DomainError | every clause passes except `cos#raises`: `math.cos(±inf)` raises where IEEE 754 returns NaN |
| `test_numpy` | `np.cos` as cos, cos32 and cos16; `np.sqrt`; numpy scalars | every clause passes |
| `test_seeded_bugs` | the two seeded formulas | `cos.accurate`, `cos.even`, `cos#raises`, `sqrt.correctly_rounded` and `sqrt#raises` fail |
| `test_explore_numpy` (explore) | `np.cos` as cos16 and cos32 | both aggregates fail with the measured value: 2 of 65,536 f16 inputs are not correctly rounded, and f32 cos is off by 1 step on [-1, 1) |

## Running

```
uv run pytest examples/libm
uv run pytest examples/libm --spectest-report=examples/libm/REPORT.md
uv run pytest examples/libm/explore_libm.py --spectest-report=examples/libm/EXPLORE.md
```

The first command collects only `test_libm.py`. Expect all items to pass, with the expected failures listed above reported as xfailed. The explore command reports its two aggregates as failed, so it exits 1: each failure is a measured answer, and EXPLORE.md gives the value and the worst inputs.

Failing items store their counterexamples under `.spectest/`, and a rerun replays them first. To search afresh, delete `.spectest/counterexamples/<hash of libm.spec>`.
