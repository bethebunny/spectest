# libm findings

What spectest found when it ran libm.spec and explore.spec against Python's math module and numpy. Each finding gives the clause, the counterexample, and an independent check. The plain test functions at the end of examples/libm/test_libm.py recompute the correctly rounded results with MPFR (gmpy2) directly, without spectest, and assert what is stated here. The specs were not changed.

Environment: Python 3.13, numpy 2.5.4, gmpy2 2.3.2, x86-64 Linux.

## 1. math.cos raises for infinite arguments (cos#raises, test_math)

**Counterexample.** x = inf (0x7ff0000000000000). `math.cos` raised `ValueError: math domain error`, which `errors={ValueError: "DomainError"}` maps to DomainError. libm.spec's `cos` has no raises or may_raise, so the built-in `cos#raises` fails. The same holds for -inf.

**Why it is a violation.** `cos.accurate` is `qe(result, cr.cos(x)) <= 1`, and `cr.cos(±inf)` is NaN. IEEE 754 makes cos(±∞) an invalid operation whose default result is a quiet NaN; C's cos returns NaN and raises the invalid flag. The spec therefore demands NaN, and docs/language.md says so for this very clause. CPython's math module turns the invalid flag into ValueError instead. numpy's cos returns NaN.

**Independent check.** `test_math_cos_raises_for_infinite_arguments`: `math.cos(±inf)` raises ValueError, `np.cos(±inf)` is NaN, and MPFR's correctly rounded cos of ±inf is NaN.

**Decision.** A real difference, not a harness bug. `cos#raises` is in test_math's expect_fail. Accepting Python's behaviour is a spec decision (`may_raise DomainError when is_inf(x)`). The seeded cos calls `math.sin(x + pi/2)`, which raises the same way, so test_seeded_bugs lists `cos#raises` too.

A deep run with 20,000 examples per item (seed 11) found no other failure:
- math: every other cos and sqrt clause passes.
- numpy: all 17 items pass (cos, cos32 and sqrt on 20,000 inputs each; cos16 on all 65,536).

## 2. Seeded bugs (test_seeded_bugs; all in expect_fail)

- **cos.accurate:** x = 15.813013859830104 (0x402fa0435a46547e). `sin(x + pi/2)` gives 0xbfefd2d6f1c1bc69; the correctly rounded value is 0xbfefd2d6f1c1bc67, so qe = 2. Checked by `test_seeded_cos_is_two_ulps_off`, which also confirms math.cos gives ...67.
- **cos.even:** x = 1.0. cos(1.0) gives 0x3fe14a280fb5068c but cos(-1.0) gives 0x3fe14a280fb5068b: `1 + pi/2` and `-1 + pi/2` round differently. Checked by `test_seeded_cos_is_not_even`.
- **cos#raises:** x = inf. math.sin(inf) raises ValueError, as in finding 1.
- **sqrt.correctly_rounded:** x = 5e-324 (0x1). `exp(log(x) / 2)` gives 0x1e60000000000064; the exact root is 2^-537 = 0x1e60000000000000, so qe = 100. Checked by `test_seeded_sqrt_is_a_hundred_ulps_off_at_the_smallest_subnormal`.
- **sqrt#raises:** x = 0.0. math.log(0.0) raises ValueError, and sqrt admits DomainError only for negative arguments. Checked by the same test.

## 3. Explore: numpy's half- and single-precision cos

These are questions, so they are not in expect_fail. The items fail and the report records the measured values.

**Is numpy's f16 cos correctly rounded on every input?** No, on two of 65,536.
- `cos16.correctly_rounded` (`sum(v in f16.all: qe(cos16(v), cr.cos(v))) == 0`) was evaluated on every f16 value and measured a sum of 2.
- The two inputs are x = ±0.0584716796875 (0x2b7c and 0xab7c), each one f16 step off.
- Mechanism: numpy computes in f32 and rounds that result to f16. The f32 result, 0.998291015625 (0x3f7f9000), lies exactly on the midpoint between the f16 values 0.998046875 (0x3bfc) and 0.99853515625 (0x3bfd). The tie goes to even (0x3bfc), but the exact cosine, 0.99829101832894..., is above the midpoint, so the correctly rounded value is 0x3bfd.
- Checked by `test_numpy_half_precision_cos_is_not_correctly_rounded`, which also asserts this mechanism.
- libm.spec's `cos16.accurate` (qe <= 1) passes on all 65,536 inputs.

**Is numpy's f32 cos correctly rounded on [-1, 1)?** No.
- `cos32.worst_small` (`max(v in f32.range(-1, 1): qe(...)) <= 0`) ranges over 2,130,706,433 values, so it was evaluated on a seeded sample of 10,000.
- The maximum is 1, reached on 11 of the sampled inputs. Example: x = 0.9705729484558105 (0x3f787778), where numpy gives 0.5648267865180969 (0x3f10987d) and the correctly rounded value is 0.5648268461227417 (0x3f10987e); the exact value is 0.56482682140511744879.
- Checked by `test_numpy_single_precision_cos_is_not_correctly_rounded`.
- A sample can only underestimate a maximum, so "not correctly rounded" is certain. libm.spec's `cos32.accurate` (qe <= 1) passes.
