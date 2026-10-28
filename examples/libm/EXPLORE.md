# spectest report: libm_explore

- **Spec:** `libm_explore` (`examples/libm/explore.spec`)
- **Spec hash:** `273a8a9858f6d88d293444b56ac5cb99055c0b3a6c9e47fea46cdddda25d38d2`
- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9
- **Platform:** CPython 3.13.9, Linux 6.18.54.1-microsoft-standard-WSL2, x86_64
- **Packages:** numpy 2.5.4, gmpy2 2.3.2
- **Items:** 6: 4 passed, 2 failed
- **Clause results:** 6: 4 passed, 2 failed

## Results

| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive | Time |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/libm/explore_libm.py::test_explore_numpy::cos16.correctly_rounded` | `cos16.correctly_rounded` | aggregate | exhaustive | **FAIL** | 0 | 1 | 0 | 0 | 0 | 18.88s |
| `examples/libm/explore_libm.py::test_explore_numpy::cos16#type` | `cos16#type` | type | exhaustive | pass | 65536 | 0 | 0 | 0 | 0 | 2.08s |
| `examples/libm/explore_libm.py::test_explore_numpy::cos16#raises` | `cos16#raises` | raises | exhaustive | pass | 65536 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/libm/explore_libm.py::test_explore_numpy::cos32.worst_small` | `cos32.worst_small` | aggregate | sampled | **FAIL** | 0 | 1 | 0 | 0 | 0 | 7.86s |
| `examples/libm/explore_libm.py::test_explore_numpy::cos32#type` | `cos32#type` | type | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.16s |
| `examples/libm/explore_libm.py::test_explore_numpy::cos32#raises` | `cos32#raises` | raises | hypothesis | pass | 100 | 0 | 0 | 0 | 0 | 0.09s |

## Aggregates

| Clause | Verdict | Value | Bound | Members |
| --- | --- | --- | --- | --- |
| `test_explore_numpy::cos16.correctly_rounded` | **FAIL** | 2 | 0 | 65536 evaluated, of 65536 (every member) |
| `test_explore_numpy::cos32.worst_small` | **FAIL** | 1 | 0 | 10000 evaluated, of 2130706433 (a seeded sample) |

## Counterexamples

### `test_explore_numpy::cos16.correctly_rounded`

```text
cos16.correctly_rounded (aggregate) failed
  aggregate correctly_rounded: sum(v in f16.all: qe(cos16(v), cr.cos(v))) == 0
  in cos16

inputs:
  v = every member of f16.all (65536 members)
observed:
  sum = 2, against the bound 0
value: 2 (bound 0)
members: 65536 evaluated, of 65536 (every member)
largest terms:
  0.05847 (0x2b7c): 1
  -0.05847 (0xab7c): 1
verdicts: 1 fail (exhaustive)
seed: 0
reproduce: uv run pytest 'examples/libm/explore_libm.py::test_explore_numpy::cos16.correctly_rounded' --spectest-seed=0
```

### `test_explore_numpy::cos32.worst_small`

```text
cos32.worst_small (aggregate) failed
  aggregate worst_small: max(v in f32.range(-1, 1): qe(cos32(v), cr.cos(v))) <= 0
  in cos32

inputs:
  v = a seeded sample of 10000 of f32.range(-1, 1) (2130706433 members)
observed:
  max = 1, against the bound 0
value: 1 (bound 0)
members: 10000 evaluated, of 2130706433 (a seeded sample)
largest terms:
  0.97057295 (0x3f787778): 1
  -0.5002324 (0xbf000f3b): 1
  -0.27870324 (0xbe8eb231): 1
  -0.21819796 (0xbe5f6f49): 1
  0.17822704 (0x3e368126): 1
  -0.9181282 (0xbf6b0a73): 1
  0.79690254 (0x3f4c01ce): 1
  -0.9690317 (0xbf781276): 1
  -0.56296974 (0xbf101ec9): 1
  0.6618318 (0x3f296dcf): 1
  -0.94465476 (0xbf71d4e5): 1
verdicts: 1 fail (sampled)
seed: 0
reproduce: uv run pytest 'examples/libm/explore_libm.py::test_explore_numpy::cos32.worst_small' --spectest-seed=0
```
