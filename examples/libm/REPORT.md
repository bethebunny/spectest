# spectest report: libm

- **Spec:** `libm` (`examples/libm/libm.spec`)
- **Spec hash:** `b323a107056a204b87b50df16ec266e7b8feabe805da834f0023c5820d2a9b1a`
- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9
- **Platform:** CPython 3.13.9, Linux 6.18.54.1-microsoft-standard-WSL2, x86_64
- **Packages:** numpy 2.5.4, gmpy2 2.3.2
- **Items:** 37: 31 passed, 6 expected failures
- **Clause results:** 37: 31 passed, 6 expected failures

## Results

| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive | Time |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/libm/test_libm.py::test_math::cos.accurate` | `cos.accurate` | ensures | hypothesis | pass | 98 | 0 | 2 (raised) | 0 | 0 | 0.25s |
| `examples/libm/test_libm.py::test_math::cos.bounded` | `cos.bounded` | ensures | hypothesis | pass | 98 | 0 | 2 (raised) | 0 | 0 | 0.15s |
| `examples/libm/test_libm.py::test_math::cos.even` | `cos.even` | relates | hypothesis | pass | 98 | 0 | 2 (raised) | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_math::cos#type` | `cos#type` | type | hypothesis | pass | 98 | 0 | 2 (raised) | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_math::cos#raises` | `cos#raises` | raises | hypothesis | expected fail | 11 | 1 | 0 | 0 | 0 | 0.03s |
| `examples/libm/test_libm.py::test_math::sqrt.correctly_rounded` | `sqrt.correctly_rounded` | ensures | hypothesis | pass | 84 | 0 | 16 (raised) | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_math::sqrt.signed_zero` | `sqrt.signed_zero` | ensures | hypothesis | pass | 76 | 0 | 24 (raised) | 0 | 0 | 0.15s |
| `examples/libm/test_libm.py::test_math::sqrt.monotone` | `sqrt.monotone` | relates | hypothesis | pass | 74 | 0 | 26 (raised) | 0 | 0 | 0.13s |
| `examples/libm/test_libm.py::test_math::sqrt#type` | `sqrt#type` | type | hypothesis | pass | 79 | 0 | 21 (raised) | 0 | 0 | 0.15s |
| `examples/libm/test_libm.py::test_math::sqrt#raises` | `sqrt#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_numpy::cos.accurate` | `cos.accurate` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_numpy::cos.bounded` | `cos.bounded` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.18s |
| `examples/libm/test_libm.py::test_numpy::cos.even` | `cos.even` | relates | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_numpy::cos#type` | `cos#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_numpy::cos#raises` | `cos#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_numpy::cos32.accurate` | `cos32.accurate` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_numpy::cos32.even` | `cos32.even` | relates | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.30s |
| `examples/libm/test_libm.py::test_numpy::cos32#type` | `cos32#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_numpy::cos32#raises` | `cos32#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.20s |
| `examples/libm/test_libm.py::test_numpy::cos16.accurate` | `cos16.accurate` | ensures | exhaustive | pass | 65536 | 0 | 0 | 0 | 0 | 5.19s |
| `examples/libm/test_libm.py::test_numpy::cos16#type` | `cos16#type` | type | exhaustive | pass | 65536 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/libm/test_libm.py::test_numpy::cos16#raises` | `cos16#raises` | raises | exhaustive | pass | 65536 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/libm/test_libm.py::test_numpy::sqrt.correctly_rounded` | `sqrt.correctly_rounded` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_numpy::sqrt.signed_zero` | `sqrt.signed_zero` | ensures | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_numpy::sqrt.monotone` | `sqrt.monotone` | relates | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.17s |
| `examples/libm/test_libm.py::test_numpy::sqrt#type` | `sqrt#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_numpy::sqrt#raises` | `sqrt#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.13s |
| `examples/libm/test_libm.py::test_seeded_bugs::cos.accurate` | `cos.accurate` | ensures | hypothesis | expected fail | 4 | 1 | 0 | 0 | 0 | 0.51s |
| `examples/libm/test_libm.py::test_seeded_bugs::cos.bounded` | `cos.bounded` | ensures | hypothesis | pass | 98 | 0 | 2 (raised) | 0 | 0 | 0.16s |
| `examples/libm/test_libm.py::test_seeded_bugs::cos.even` | `cos.even` | relates | hypothesis | expected fail | 1 | 1 | 0 | 0 | 0 | 0.04s |
| `examples/libm/test_libm.py::test_seeded_bugs::cos#type` | `cos#type` | type | hypothesis | pass | 98 | 0 | 2 (raised) | 0 | 0 | 0.15s |
| `examples/libm/test_libm.py::test_seeded_bugs::cos#raises` | `cos#raises` | raises | hypothesis | expected fail | 3 | 1 | 0 | 0 | 0 | 0.09s |
| `examples/libm/test_libm.py::test_seeded_bugs::sqrt.correctly_rounded` | `sqrt.correctly_rounded` | ensures | hypothesis | expected fail | 5 | 1 | 5 (raised) | 0 | 0 | 0.04s |
| `examples/libm/test_libm.py::test_seeded_bugs::sqrt.signed_zero` | `sqrt.signed_zero` | ensures | hypothesis | pass | 68 | 0 | 32 (raised) | 0 | 0 | 0.15s |
| `examples/libm/test_libm.py::test_seeded_bugs::sqrt.monotone` | `sqrt.monotone` | relates | hypothesis | pass | 78 | 0 | 22 (raised) | 0 | 0 | 0.15s |
| `examples/libm/test_libm.py::test_seeded_bugs::sqrt#type` | `sqrt#type` | type | hypothesis | pass | 75 | 0 | 25 (raised) | 0 | 0 | 0.14s |
| `examples/libm/test_libm.py::test_seeded_bugs::sqrt#raises` | `sqrt#raises` | raises | hypothesis | expected fail | 3 | 1 | 0 | 0 | 0 | 0.03s |

Skips by cause: raised: the call raised.

## Coverage

Examples each clause judged (pass or fail), per partition class; a class with 0 examples was never exercised by that clause.

### `cos`

| Clause | x: nan | x: inf | x: zero | x: subnormal | x: small | x: moderate | x: huge |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `test_math::cos.accurate` | 21 | **0** | 2 | 14 | 17 | 19 | 25 |
| `test_math::cos.bounded` | 25 | **0** | 2 | 12 | 11 | 27 | 21 |
| `test_math::cos.even` | 22 | **0** | 2 | 15 | 15 | 22 | 22 |
| `test_math::cos#type` | 31 | **0** | 2 | 15 | 14 | 22 | 14 |
| `test_math::cos#raises` | 1 | 1 | 2 | 2 | 3 | **0** | 3 |
| `test_numpy::cos.accurate` | 29 | 2 | 2 | 21 | 11 | 13 | 22 |
| `test_numpy::cos.bounded` | 29 | 2 | 2 | 11 | 12 | 33 | 11 |
| `test_numpy::cos.even` | 34 | 2 | 2 | 10 | 15 | 16 | 21 |
| `test_numpy::cos#type` | 31 | 2 | 2 | 11 | 14 | 27 | 13 |
| `test_numpy::cos#raises` | 19 | 2 | 2 | 20 | 16 | 25 | 16 |
| `test_seeded_bugs::cos.accurate` | 1 | **0** | **0** | **0** | 2 | 2 | **0** |
| `test_seeded_bugs::cos.bounded` | 32 | **0** | 2 | 13 | 22 | 15 | 14 |
| `test_seeded_bugs::cos.even` | 1 | **0** | **0** | **0** | **0** | 1 | **0** |
| `test_seeded_bugs::cos#type` | 19 | **0** | 2 | 23 | 19 | 19 | 16 |
| `test_seeded_bugs::cos#raises` | 1 | 1 | 2 | **0** | **0** | **0** | **0** |

### `sqrt`

| Clause | x: nan | x: negative | x: zero | x: subnormal | x: normal | x: inf |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `test_math::sqrt.correctly_rounded` | 38 | **0** | 2 | 11 | 32 | 1 |
| `test_math::sqrt.signed_zero` | 29 | **0** | 2 | 12 | 32 | 1 |
| `test_math::sqrt.monotone` | 36 | **0** | 2 | 12 | 23 | 1 |
| `test_math::sqrt#type` | 36 | **0** | 2 | 18 | 22 | 1 |
| `test_math::sqrt#raises` | 41 | 20 | 2 | 11 | 25 | 1 |
| `test_numpy::sqrt.correctly_rounded` | 28 | 32 | 2 | 16 | 21 | 1 |
| `test_numpy::sqrt.signed_zero` | 38 | 20 | 2 | 17 | 22 | 1 |
| `test_numpy::sqrt.monotone` | 35 | 25 | 2 | 15 | 22 | 1 |
| `test_numpy::sqrt#type` | 35 | 20 | 2 | 17 | 25 | 1 |
| `test_numpy::sqrt#raises` | 30 | 25 | 2 | 11 | 31 | 1 |
| `test_seeded_bugs::sqrt.correctly_rounded` | 3 | **0** | **0** | **0** | 2 | 1 |
| `test_seeded_bugs::sqrt.signed_zero` | 34 | **0** | **0** | 14 | 19 | 1 |
| `test_seeded_bugs::sqrt.monotone` | 34 | **0** | **0** | 22 | 21 | 1 |
| `test_seeded_bugs::sqrt#type` | 31 | **0** | **0** | 25 | 18 | 1 |
| `test_seeded_bugs::sqrt#raises` | 1 | **0** | 1 | 2 | **0** | **0** |

### `cos32`

| Clause | x: nan | x: inf | x: zero | x: subnormal | x: small | x: moderate | x: huge |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `test_numpy::cos32.accurate` | 34 | 2 | 2 | 17 | 15 | 18 | 12 |
| `test_numpy::cos32.even` | 24 | 2 | 2 | 13 | 19 | 26 | 14 |
| `test_numpy::cos32#type` | 34 | 2 | 2 | 16 | 12 | 24 | 10 |
| `test_numpy::cos32#raises` | 29 | 2 | 2 | 16 | 10 | 15 | 26 |

## Counterexamples

### `test_math::cos#raises` (expected failure)

```text
cos#raises (raises) failed as expected (expect_fail)
  built-in: cos raises only what a raises or may_raise admits
  in cos

inputs:
  x = inf (0x7ff0000000000000)
observed:
  raised ValueError: math domain error (maps to DomainError)
  no raises or may_raise admits DomainError here
partitions:
  x: inf
explanation:
  errors that must be raised (R) = {}
  errors that may be raised (M) = {}
verdicts: 11 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/libm/test_libm.py::test_math::cos#raises' --spectest-seed=0
```

### `test_seeded_bugs::cos.accurate` (expected failure)

```text
cos.accurate (ensures) failed as expected (expect_fail)
  ensures accurate: qe(result, cr.cos(x)) <= 1
  in cos

inputs:
  x = 15.813013859830104 (0x402fa0435a46547e)
observed:
  result = -0.9944872590839512 (0xbfefd2d6f1c1bc69)
partitions:
  x: moderate
explanation:
  result = -0.9944872590839512 (0xbfefd2d6f1c1bc69)
  cr.cos(x) = -0.994487259083951 (0xbfefd2d6f1c1bc67)
  qe(result, cr.cos(x)) = 2
verdicts: 4 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/libm/test_libm.py::test_seeded_bugs::cos.accurate' --spectest-seed=0
```

### `test_seeded_bugs::cos.even` (expected failure)

```text
cos.even (relates) failed as expected (expect_fail)
  relates even: not is_nan(x) implies same(cos(-x), result)
  in cos

inputs:
  x = 1.0 (0x3ff0000000000000)
observed:
  result = 0.5403023058681398 (0x3fe14a280fb5068c)
partitions:
  x: moderate
explanation:
  cos(-x) = 0.5403023058681397 (0x3fe14a280fb5068b)
  result = 0.5403023058681398 (0x3fe14a280fb5068c)
  same(cos(-x), result) = false
verdicts: 1 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/libm/test_libm.py::test_seeded_bugs::cos.even' --spectest-seed=0
```

### `test_seeded_bugs::cos#raises` (expected failure)

```text
cos#raises (raises) failed as expected (expect_fail)
  built-in: cos raises only what a raises or may_raise admits
  in cos

inputs:
  x = inf (0x7ff0000000000000)
observed:
  raised ValueError: math domain error (maps to DomainError)
  no raises or may_raise admits DomainError here
partitions:
  x: inf
explanation:
  errors that must be raised (R) = {}
  errors that may be raised (M) = {}
verdicts: 3 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/libm/test_libm.py::test_seeded_bugs::cos#raises' --spectest-seed=0
```

### `test_seeded_bugs::sqrt.correctly_rounded` (expected failure)

```text
sqrt.correctly_rounded (ensures) failed as expected (expect_fail)
  ensures correctly_rounded: qe(result, cr.sqrt(x)) == 0
  in sqrt

inputs:
  x = 5e-324 (0x0000000000000001)
observed:
  result = 2.222758749485127e-162 (0x1e60000000000064)
partitions:
  x: subnormal
explanation:
  result = 2.222758749485127e-162 (0x1e60000000000064)
  cr.sqrt(x) = 2.2227587494850775e-162 (0x1e60000000000000)
  qe(result, cr.sqrt(x)) = 100
verdicts: 5 pass, 1 fail, 5 skip (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/libm/test_libm.py::test_seeded_bugs::sqrt.correctly_rounded' --spectest-seed=0
```

### `test_seeded_bugs::sqrt#raises` (expected failure)

```text
sqrt#raises (raises) failed as expected (expect_fail)
  built-in: sqrt raises only what a raises or may_raise admits
  in sqrt

inputs:
  x = 0.0 (0x0000000000000000)
observed:
  raised ValueError: math domain error (maps to DomainError)
  no raises or may_raise admits DomainError here
partitions:
  x: zero
explanation:
  may_raise DomainError when not is_nan(x) and x < 0 = false
  errors that must be raised (R) = {}
  errors that may be raised (M) = {}
verdicts: 3 pass, 1 fail (hypothesis)
seed: 0
reproduce: uv run pytest 'examples/libm/test_libm.py::test_seeded_bugs::sqrt#raises' --spectest-seed=0
```
