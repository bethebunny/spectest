# spectest report: deque

- **Spec:** `deque` (`examples/deque/deque.spec`)
- **Spec hash:** `dd6fc8d08e1c057fb0703c46fbd95e0352151f48db5d65577a838bd0048ad440`
- **Harness:** spectest 0.1.0.dev0, Hypothesis 6.170.9
- **Platform:** CPython 3.13.9, Linux 6.18.54.1-microsoft-standard-WSL2, x86_64
- **Packages:** gmpy2 2.3.2
- **Items:** 12: 2 passed, 10 expected failures
- **Clause results:** 456: 442 passed, 14 expected failures

## Results

| Item | Clause | Kind | Mode | Verdict | pass | fail | skip | spec error | inconclusive | Time |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].empty.items` | ensures | stateful | pass | 319 | 0 | 0 | 0 | 0 | 6.15s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].empty.unbounded` | ensures | stateful | pass | 319 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].empty#type` | type | stateful | pass | 319 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].empty#raises` | raises | stateful | pass | 319 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].bounded.items` | ensures | stateful | pass | 307 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].bounded.maxlen` | ensures | stateful | pass | 307 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].bounded#type` | type | stateful | pass | 307 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].bounded#raises` | raises | stateful | pass | 307 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].append#1` | modifies | stateful | pass | 2080 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].append.items` | ensures | stateful | pass | 2080 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].append.maxlen` | ensures | stateful | pass | 2080 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].append#type` | type | stateful | pass | 2080 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].append#raises` | raises | stateful | pass | 2080 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].appendleft#1` | modifies | stateful | pass | 1019 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].appendleft.items` | ensures | stateful | pass | 1019 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].appendleft.maxlen` | ensures | stateful | pass | 1019 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].appendleft#type` | type | stateful | pass | 1019 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].appendleft#raises` | raises | stateful | pass | 1019 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop#1` | raises | stateful | pass | 1473 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop#2` | modifies | stateful | pass | 1473 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop.value` | ensures | stateful | pass | 365 | 0 | 1108 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop.items` | ensures | stateful | pass | 365 | 0 | 1108 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop.maxlen` | ensures | stateful | pass | 365 | 0 | 1108 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop#type` | type | stateful | pass | 365 | 0 | 1108 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].pop#raises` | raises | stateful | pass | 1473 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft#1` | raises | stateful | pass | 1606 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft#2` | modifies | stateful | pass | 1606 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft.value` | ensures | stateful | pass | 697 | 0 | 909 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft.items` | ensures | stateful | pass | 697 | 0 | 909 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft.maxlen` | ensures | stateful | pass | 697 | 0 | 909 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft#type` | type | stateful | pass | 697 | 0 | 909 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].popleft#raises` | raises | stateful | pass | 1606 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].rotate#1` | modifies | stateful | pass | 1515 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].rotate.items` | ensures | stateful | pass | 1515 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].rotate.maxlen` | ensures | stateful | pass | 1515 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].rotate#type` | type | stateful | pass | 1515 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].rotate#raises` | raises | stateful | pass | 1515 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=i64]` | `Deque[T=i64].within_bound` | invariant | stateful | pass | 8319 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].empty.items` | ensures | stateful | pass | 235 | 0 | 0 | 0 | 0 | 6.40s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].empty.unbounded` | ensures | stateful | pass | 235 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].empty#type` | type | stateful | pass | 235 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].empty#raises` | raises | stateful | pass | 235 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].bounded.items` | ensures | stateful | pass | 386 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].bounded.maxlen` | ensures | stateful | pass | 386 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].bounded#type` | type | stateful | pass | 386 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].bounded#raises` | raises | stateful | pass | 386 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].append#1` | modifies | stateful | pass | 1846 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].append.items` | ensures | stateful | pass | 1846 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].append.maxlen` | ensures | stateful | pass | 1846 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].append#type` | type | stateful | pass | 1846 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].append#raises` | raises | stateful | pass | 1846 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].appendleft#1` | modifies | stateful | pass | 1387 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].appendleft.items` | ensures | stateful | pass | 1387 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].appendleft.maxlen` | ensures | stateful | pass | 1387 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].appendleft#type` | type | stateful | pass | 1387 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].appendleft#raises` | raises | stateful | pass | 1387 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop#1` | raises | stateful | pass | 1401 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop#2` | modifies | stateful | pass | 1401 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop.value` | ensures | stateful | pass | 550 | 0 | 851 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop.items` | ensures | stateful | pass | 550 | 0 | 851 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop.maxlen` | ensures | stateful | pass | 550 | 0 | 851 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop#type` | type | stateful | pass | 550 | 0 | 851 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].pop#raises` | raises | stateful | pass | 1401 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft#1` | raises | stateful | pass | 1540 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft#2` | modifies | stateful | pass | 1540 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft.value` | ensures | stateful | pass | 500 | 0 | 1040 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft.items` | ensures | stateful | pass | 500 | 0 | 1040 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft.maxlen` | ensures | stateful | pass | 500 | 0 | 1040 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft#type` | type | stateful | pass | 500 | 0 | 1040 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].popleft#raises` | raises | stateful | pass | 1540 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].rotate#1` | modifies | stateful | pass | 1855 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].rotate.items` | ensures | stateful | pass | 1855 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].rotate.maxlen` | ensures | stateful | pass | 1855 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].rotate#type` | type | stateful | pass | 1855 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].rotate#raises` | raises | stateful | pass | 1855 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_collections_deque::Deque[T=string]` | `Deque[T=string].within_bound` | invariant | stateful | pass | 8650 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].empty.items` | ensures | stateful | pass | 105 | 0 | 0 | 0 | 0 | 4.04s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].empty.unbounded` | ensures | stateful | pass | 105 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].empty#type` | type | stateful | pass | 105 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].empty#raises` | raises | stateful | pass | 105 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].bounded.items` | ensures | stateful | pass | 134 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].bounded.maxlen` | ensures | stateful | pass | 134 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].bounded#type` | type | stateful | pass | 134 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].bounded#raises` | raises | stateful | pass | 134 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].append#1` | modifies | stateful | pass | 740 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].append.items` | ensures | stateful | pass | 740 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].append.maxlen` | ensures | stateful | pass | 740 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].append#type` | type | stateful | pass | 740 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].append#raises` | raises | stateful | pass | 740 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].appendleft#1` | modifies | stateful | pass | 564 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].appendleft.items` | ensures | stateful | expected fail | 5 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].appendleft.maxlen` | ensures | stateful | pass | 564 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].appendleft#type` | type | stateful | pass | 564 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].appendleft#raises` | raises | stateful | pass | 564 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop#1` | raises | stateful | pass | 502 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop#2` | modifies | stateful | pass | 502 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop.value` | ensures | stateful | pass | 259 | 0 | 243 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop.items` | ensures | stateful | pass | 259 | 0 | 243 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop.maxlen` | ensures | stateful | pass | 259 | 0 | 243 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop#type` | type | stateful | pass | 259 | 0 | 243 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].pop#raises` | raises | stateful | pass | 502 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft#1` | raises | stateful | pass | 539 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft#2` | modifies | stateful | pass | 539 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft.value` | ensures | stateful | pass | 215 | 0 | 324 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft.items` | ensures | stateful | pass | 215 | 0 | 324 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft.maxlen` | ensures | stateful | pass | 215 | 0 | 324 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft#type` | type | stateful | pass | 215 | 0 | 324 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].popleft#raises` | raises | stateful | pass | 539 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].rotate#1` | modifies | stateful | pass | 300 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].rotate.items` | ensures | stateful | pass | 300 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].rotate.maxlen` | ensures | stateful | pass | 300 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].rotate#type` | type | stateful | pass | 300 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].rotate#raises` | raises | stateful | pass | 300 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]` | `Deque[T=i64].within_bound` | invariant | stateful | pass | 2883 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].empty.items` | ensures | stateful | pass | 98 | 0 | 0 | 0 | 0 | 6.40s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].empty.unbounded` | ensures | stateful | pass | 98 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].empty#type` | type | stateful | pass | 98 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].empty#raises` | raises | stateful | pass | 98 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].bounded.items` | ensures | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].bounded.maxlen` | ensures | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].bounded#type` | type | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].bounded#raises` | raises | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].append#1` | modifies | stateful | pass | 802 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].append.items` | ensures | stateful | pass | 802 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].append.maxlen` | ensures | stateful | pass | 802 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].append#type` | type | stateful | pass | 802 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].append#raises` | raises | stateful | pass | 802 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].appendleft#1` | modifies | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].appendleft.items` | ensures | stateful | expected fail | 1 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].appendleft.maxlen` | ensures | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].appendleft#type` | type | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].appendleft#raises` | raises | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop#1` | raises | stateful | pass | 397 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop#2` | modifies | stateful | pass | 397 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop.value` | ensures | stateful | pass | 184 | 0 | 213 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop.items` | ensures | stateful | pass | 184 | 0 | 213 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop.maxlen` | ensures | stateful | pass | 184 | 0 | 213 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop#type` | type | stateful | pass | 184 | 0 | 213 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].pop#raises` | raises | stateful | pass | 397 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft#1` | raises | stateful | pass | 610 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft#2` | modifies | stateful | pass | 610 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft.value` | ensures | stateful | pass | 219 | 0 | 391 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft.items` | ensures | stateful | pass | 219 | 0 | 391 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft.maxlen` | ensures | stateful | pass | 219 | 0 | 391 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft#type` | type | stateful | pass | 219 | 0 | 391 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].popleft#raises` | raises | stateful | pass | 610 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].rotate#1` | modifies | stateful | pass | 403 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].rotate.items` | ensures | stateful | pass | 403 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].rotate.maxlen` | ensures | stateful | pass | 403 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].rotate#type` | type | stateful | pass | 403 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].rotate#raises` | raises | stateful | pass | 403 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]` | `Deque[T=string].within_bound` | invariant | stateful | pass | 2915 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].empty.items` | ensures | stateful | pass | 112 | 0 | 0 | 0 | 0 | 6.61s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].empty.unbounded` | ensures | stateful | pass | 112 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].empty#type` | type | stateful | pass | 112 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].empty#raises` | raises | stateful | pass | 112 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].bounded.items` | ensures | stateful | pass | 147 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].bounded.maxlen` | ensures | stateful | pass | 147 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].bounded#type` | type | stateful | pass | 147 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].bounded#raises` | raises | stateful | pass | 147 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].append#1` | modifies | stateful | pass | 1012 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].append.items` | ensures | stateful | pass | 1012 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].append.maxlen` | ensures | stateful | pass | 1012 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].append#type` | type | stateful | pass | 1012 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].append#raises` | raises | stateful | pass | 1012 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].appendleft#1` | modifies | stateful | pass | 443 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].appendleft.items` | ensures | stateful | pass | 443 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].appendleft.maxlen` | ensures | stateful | pass | 443 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].appendleft#type` | type | stateful | pass | 443 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].appendleft#raises` | raises | stateful | pass | 443 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop#1` | raises | stateful | pass | 809 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop#2` | modifies | stateful | pass | 809 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop.value` | ensures | stateful | pass | 199 | 0 | 610 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop.items` | ensures | stateful | pass | 199 | 0 | 610 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop.maxlen` | ensures | stateful | pass | 199 | 0 | 610 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop#type` | type | stateful | pass | 199 | 0 | 610 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].pop#raises` | raises | stateful | pass | 809 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft#1` | raises | stateful | pass | 391 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft#2` | modifies | stateful | pass | 391 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft.value` | ensures | stateful | pass | 128 | 0 | 263 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft.items` | ensures | stateful | pass | 128 | 0 | 263 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft.maxlen` | ensures | stateful | pass | 128 | 0 | 263 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft#type` | type | stateful | pass | 128 | 0 | 263 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].popleft#raises` | raises | stateful | pass | 391 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].rotate#1` | modifies | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].rotate.items` | ensures | stateful | expected fail | 51 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].rotate.maxlen` | ensures | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].rotate#type` | type | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].rotate#raises` | raises | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]` | `Deque[T=i64].within_bound` | invariant | stateful | pass | 3383 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].empty.items` | ensures | stateful | pass | 118 | 0 | 0 | 0 | 0 | 5.94s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].empty.unbounded` | ensures | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].empty#type` | type | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].empty#raises` | raises | stateful | pass | 118 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].bounded.items` | ensures | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].bounded.maxlen` | ensures | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].bounded#type` | type | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].bounded#raises` | raises | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].append#1` | modifies | stateful | pass | 992 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].append.items` | ensures | stateful | pass | 992 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].append.maxlen` | ensures | stateful | pass | 992 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].append#type` | type | stateful | pass | 992 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].append#raises` | raises | stateful | pass | 992 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].appendleft#1` | modifies | stateful | pass | 743 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].appendleft.items` | ensures | stateful | pass | 743 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].appendleft.maxlen` | ensures | stateful | pass | 743 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].appendleft#type` | type | stateful | pass | 743 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].appendleft#raises` | raises | stateful | pass | 743 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop#1` | raises | stateful | pass | 471 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop#2` | modifies | stateful | pass | 471 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop.value` | ensures | stateful | pass | 114 | 0 | 357 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop.items` | ensures | stateful | pass | 114 | 0 | 357 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop.maxlen` | ensures | stateful | pass | 114 | 0 | 357 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop#type` | type | stateful | pass | 114 | 0 | 357 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].pop#raises` | raises | stateful | pass | 471 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft#1` | raises | stateful | pass | 327 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft#2` | modifies | stateful | pass | 327 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft.value` | ensures | stateful | pass | 103 | 0 | 224 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft.items` | ensures | stateful | pass | 103 | 0 | 224 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft.maxlen` | ensures | stateful | pass | 103 | 0 | 224 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft#type` | type | stateful | pass | 103 | 0 | 224 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].popleft#raises` | raises | stateful | pass | 327 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].rotate#1` | modifies | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].rotate.items` | ensures | stateful | expected fail | 26 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].rotate.maxlen` | ensures | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].rotate#type` | type | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].rotate#raises` | raises | stateful | pass | 488 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]` | `Deque[T=string].within_bound` | invariant | stateful | pass | 3257 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].empty.items` | ensures | stateful | pass | 78 | 0 | 0 | 0 | 0 | 2.84s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].empty.unbounded` | ensures | stateful | pass | 78 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].empty#type` | type | stateful | pass | 78 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].empty#raises` | raises | stateful | pass | 78 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].bounded.items` | ensures | stateful | pass | 183 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].bounded.maxlen` | ensures | stateful | pass | 183 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].bounded#type` | type | stateful | pass | 183 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].bounded#raises` | raises | stateful | pass | 183 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].append#1` | modifies | stateful | pass | 1022 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].append.items` | ensures | stateful | pass | 1022 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].append.maxlen` | ensures | stateful | pass | 1022 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].append#type` | type | stateful | pass | 1022 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].append#raises` | raises | stateful | pass | 1022 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].appendleft#1` | modifies | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].appendleft.items` | ensures | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].appendleft.maxlen` | ensures | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].appendleft#type` | type | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].appendleft#raises` | raises | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop#1` | raises | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop#2` | modifies | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop.value` | ensures | stateful | pass | 195 | 0 | 275 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop.items` | ensures | stateful | pass | 195 | 0 | 275 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop.maxlen` | ensures | stateful | pass | 195 | 0 | 275 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop#type` | type | stateful | pass | 195 | 0 | 275 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].pop#raises` | raises | stateful | pass | 470 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft#1` | raises | stateful | expected fail | 0 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft#2` | modifies | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft.value` | ensures | stateful | pass | 178 | 0 | 325 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft.items` | ensures | stateful | pass | 178 | 0 | 325 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft.maxlen` | ensures | stateful | pass | 178 | 0 | 325 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft#type` | type | stateful | expected fail | 0 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].popleft#raises` | raises | stateful | pass | 503 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].rotate#1` | modifies | stateful | pass | 317 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].rotate.items` | ensures | stateful | pass | 317 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].rotate.maxlen` | ensures | stateful | pass | 317 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].rotate#type` | type | stateful | pass | 317 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].rotate#raises` | raises | stateful | pass | 317 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]` | `Deque[T=i64].within_bound` | invariant | stateful | pass | 3074 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].empty.items` | ensures | stateful | pass | 126 | 0 | 0 | 0 | 0 | 2.55s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].empty.unbounded` | ensures | stateful | pass | 126 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].empty#type` | type | stateful | pass | 126 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].empty#raises` | raises | stateful | pass | 126 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].bounded.items` | ensures | stateful | pass | 104 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].bounded.maxlen` | ensures | stateful | pass | 104 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].bounded#type` | type | stateful | pass | 104 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].bounded#raises` | raises | stateful | pass | 104 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].append#1` | modifies | stateful | pass | 728 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].append.items` | ensures | stateful | pass | 728 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].append.maxlen` | ensures | stateful | pass | 728 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].append#type` | type | stateful | pass | 728 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].append#raises` | raises | stateful | pass | 728 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].appendleft#1` | modifies | stateful | pass | 586 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].appendleft.items` | ensures | stateful | pass | 586 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].appendleft.maxlen` | ensures | stateful | pass | 586 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].appendleft#type` | type | stateful | pass | 586 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].appendleft#raises` | raises | stateful | pass | 586 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop#1` | raises | stateful | pass | 521 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop#2` | modifies | stateful | pass | 521 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop.value` | ensures | stateful | pass | 194 | 0 | 327 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop.items` | ensures | stateful | pass | 194 | 0 | 327 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop.maxlen` | ensures | stateful | pass | 194 | 0 | 327 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop#type` | type | stateful | pass | 194 | 0 | 327 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].pop#raises` | raises | stateful | pass | 521 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft#1` | raises | stateful | expected fail | 0 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft#2` | modifies | stateful | pass | 484 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft.value` | ensures | stateful | pass | 185 | 0 | 299 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft.items` | ensures | stateful | pass | 185 | 0 | 299 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft.maxlen` | ensures | stateful | pass | 185 | 0 | 299 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft#type` | type | stateful | expected fail | 0 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].popleft#raises` | raises | stateful | pass | 484 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].rotate#1` | modifies | stateful | pass | 550 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].rotate.items` | ensures | stateful | pass | 550 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].rotate.maxlen` | ensures | stateful | pass | 550 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].rotate#type` | type | stateful | pass | 550 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].rotate#raises` | raises | stateful | pass | 550 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]` | `Deque[T=string].within_bound` | invariant | stateful | pass | 3097 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].empty.items` | ensures | stateful | pass | 119 | 0 | 0 | 0 | 0 | 2.85s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].empty.unbounded` | ensures | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].empty#type` | type | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].empty#raises` | raises | stateful | pass | 119 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].bounded.items` | ensures | stateful | pass | 123 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].bounded.maxlen` | ensures | stateful | pass | 123 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].bounded#type` | type | stateful | pass | 123 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].bounded#raises` | raises | stateful | pass | 123 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].append#1` | modifies | stateful | pass | 1101 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].append.items` | ensures | stateful | pass | 1101 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].append.maxlen` | ensures | stateful | pass | 1101 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].append#type` | type | stateful | pass | 1101 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].append#raises` | raises | stateful | pass | 1101 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].appendleft#1` | modifies | stateful | pass | 530 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].appendleft.items` | ensures | stateful | pass | 530 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].appendleft.maxlen` | ensures | stateful | pass | 530 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].appendleft#type` | type | stateful | pass | 530 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].appendleft#raises` | raises | stateful | pass | 530 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop#1` | raises | stateful | expected fail | 2 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop#2` | modifies | stateful | pass | 490 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop.value` | ensures | stateful | pass | 139 | 0 | 351 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop.items` | ensures | stateful | pass | 139 | 0 | 351 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop.maxlen` | ensures | stateful | pass | 139 | 0 | 351 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop#type` | type | stateful | pass | 139 | 0 | 351 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].pop#raises` | raises | stateful | expected fail | 2 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft#1` | raises | stateful | pass | 485 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft#2` | modifies | stateful | pass | 485 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft.value` | ensures | stateful | pass | 201 | 0 | 284 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft.items` | ensures | stateful | pass | 201 | 0 | 284 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft.maxlen` | ensures | stateful | pass | 201 | 0 | 284 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft#type` | type | stateful | pass | 201 | 0 | 284 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].popleft#raises` | raises | stateful | pass | 485 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].rotate#1` | modifies | stateful | pass | 520 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].rotate.items` | ensures | stateful | pass | 520 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].rotate.maxlen` | ensures | stateful | pass | 520 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].rotate#type` | type | stateful | pass | 520 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].rotate#raises` | raises | stateful | pass | 520 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]` | `Deque[T=i64].within_bound` | invariant | stateful | pass | 3366 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].empty.items` | ensures | stateful | pass | 91 | 0 | 0 | 0 | 0 | 3.30s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].empty.unbounded` | ensures | stateful | pass | 91 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].empty#type` | type | stateful | pass | 91 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].empty#raises` | raises | stateful | pass | 91 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].bounded.items` | ensures | stateful | pass | 131 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].bounded.maxlen` | ensures | stateful | pass | 131 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].bounded#type` | type | stateful | pass | 131 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].bounded#raises` | raises | stateful | pass | 131 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].append#1` | modifies | stateful | pass | 860 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].append.items` | ensures | stateful | pass | 860 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].append.maxlen` | ensures | stateful | pass | 860 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].append#type` | type | stateful | pass | 860 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].append#raises` | raises | stateful | pass | 860 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].appendleft#1` | modifies | stateful | pass | 596 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].appendleft.items` | ensures | stateful | pass | 596 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].appendleft.maxlen` | ensures | stateful | pass | 596 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].appendleft#type` | type | stateful | pass | 596 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].appendleft#raises` | raises | stateful | pass | 596 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop#1` | raises | stateful | expected fail | 3 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop#2` | modifies | stateful | pass | 297 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop.value` | ensures | stateful | pass | 143 | 0 | 154 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop.items` | ensures | stateful | pass | 143 | 0 | 154 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop.maxlen` | ensures | stateful | pass | 143 | 0 | 154 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop#type` | type | stateful | pass | 143 | 0 | 154 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].pop#raises` | raises | stateful | expected fail | 3 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft#1` | raises | stateful | pass | 606 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft#2` | modifies | stateful | pass | 606 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft.value` | ensures | stateful | pass | 201 | 0 | 405 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft.items` | ensures | stateful | pass | 201 | 0 | 405 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft.maxlen` | ensures | stateful | pass | 201 | 0 | 405 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft#type` | type | stateful | pass | 201 | 0 | 405 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].popleft#raises` | raises | stateful | pass | 606 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].rotate#1` | modifies | stateful | pass | 343 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].rotate.items` | ensures | stateful | pass | 343 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].rotate.maxlen` | ensures | stateful | pass | 343 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].rotate#type` | type | stateful | pass | 343 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].rotate#raises` | raises | stateful | pass | 343 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]` | `Deque[T=string].within_bound` | invariant | stateful | pass | 2922 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].empty.items` | ensures | stateful | pass | 113 | 0 | 0 | 0 | 0 | 2.25s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].empty.unbounded` | ensures | stateful | pass | 113 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].empty#type` | type | stateful | pass | 113 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].empty#raises` | raises | stateful | pass | 113 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].bounded.items` | ensures | stateful | pass | 95 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].bounded.maxlen` | ensures | stateful | pass | 95 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].bounded#type` | type | stateful | pass | 95 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].bounded#raises` | raises | stateful | pass | 95 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].append#1` | modifies | stateful | pass | 645 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].append.items` | ensures | stateful | pass | 645 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].append.maxlen` | ensures | stateful | pass | 645 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].append#type` | type | stateful | pass | 645 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].append#raises` | raises | stateful | pass | 645 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].appendleft#1` | modifies | stateful | pass | 456 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].appendleft.items` | ensures | stateful | pass | 456 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].appendleft.maxlen` | ensures | stateful | pass | 456 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].appendleft#type` | type | stateful | pass | 456 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].appendleft#raises` | raises | stateful | pass | 456 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop#1` | raises | stateful | pass | 634 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop#2` | modifies | stateful | pass | 634 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop.value` | ensures | stateful | pass | 215 | 0 | 419 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop.items` | ensures | stateful | pass | 215 | 0 | 419 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop.maxlen` | ensures | stateful | pass | 215 | 0 | 419 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop#type` | type | stateful | pass | 215 | 0 | 419 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].pop#raises` | raises | stateful | pass | 634 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft#1` | raises | stateful | pass | 464 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft#2` | modifies | stateful | pass | 464 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft.value` | ensures | stateful | pass | 207 | 0 | 257 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft.items` | ensures | stateful | pass | 207 | 0 | 257 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft.maxlen` | ensures | stateful | pass | 207 | 0 | 257 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft#type` | type | stateful | pass | 207 | 0 | 257 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].popleft#raises` | raises | stateful | pass | 464 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].rotate#1` | modifies | stateful | pass | 428 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].rotate.items` | ensures | stateful | pass | 428 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].rotate.maxlen` | ensures | stateful | expected fail | 0 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].rotate#type` | type | stateful | pass | 428 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].rotate#raises` | raises | stateful | pass | 428 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]` | `Deque[T=i64].within_bound` | invariant | stateful | pass | 2834 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].empty.items` | ensures | stateful | pass | 99 | 0 | 0 | 0 | 0 | 2.64s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].empty.unbounded` | ensures | stateful | pass | 99 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].empty#type` | type | stateful | pass | 99 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].empty#raises` | raises | stateful | pass | 99 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].bounded.items` | ensures | stateful | pass | 145 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].bounded.maxlen` | ensures | stateful | pass | 145 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].bounded#type` | type | stateful | pass | 145 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].bounded#raises` | raises | stateful | pass | 145 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].append#1` | modifies | stateful | pass | 757 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].append.items` | ensures | stateful | pass | 757 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].append.maxlen` | ensures | stateful | pass | 757 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].append#type` | type | stateful | pass | 757 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].append#raises` | raises | stateful | pass | 757 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].appendleft#1` | modifies | stateful | pass | 483 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].appendleft.items` | ensures | stateful | pass | 483 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].appendleft.maxlen` | ensures | stateful | pass | 483 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].appendleft#type` | type | stateful | pass | 483 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].appendleft#raises` | raises | stateful | pass | 483 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop#1` | raises | stateful | pass | 680 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop#2` | modifies | stateful | pass | 680 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop.value` | ensures | stateful | pass | 253 | 0 | 427 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop.items` | ensures | stateful | pass | 253 | 0 | 427 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop.maxlen` | ensures | stateful | pass | 253 | 0 | 427 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop#type` | type | stateful | pass | 253 | 0 | 427 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].pop#raises` | raises | stateful | pass | 680 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft#1` | raises | stateful | pass | 389 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft#2` | modifies | stateful | pass | 389 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft.value` | ensures | stateful | pass | 137 | 0 | 252 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft.items` | ensures | stateful | pass | 137 | 0 | 252 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft.maxlen` | ensures | stateful | pass | 137 | 0 | 252 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft#type` | type | stateful | pass | 137 | 0 | 252 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].popleft#raises` | raises | stateful | pass | 389 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].rotate#1` | modifies | stateful | pass | 338 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].rotate.items` | ensures | stateful | pass | 338 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].rotate.maxlen` | ensures | stateful | expected fail | 0 | 1 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].rotate#type` | type | stateful | pass | 338 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].rotate#raises` | raises | stateful | pass | 338 | 0 | 0 | 0 | 0 | 0.00s |
| `examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]` | `Deque[T=string].within_bound` | invariant | stateful | pass | 2890 | 0 | 0 | 0 | 0 | 0.00s |

## Counterexamples

### `test_seeded_appendleft_wrong_end::Deque[T=i64].appendleft.items` (expected failure)

```text
Deque[T=i64].appendleft.items (ensures) failed as expected (expect_fail)
  ensures items: let ys = [x] + old(self.items) in self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) then ys[0:unwrap(self.maxlen)] else ys)
  in Deque.appendleft with T=i64

inputs:
  self = d1 = Deque { items: [1], maxlen: some(1) }
  x = 0
observed:
  steps:
  1. d1 = Deque.bounded(n=1)
  2. d1.append(x=1)
  3. d1.appendleft(x=0)
  result = unit
  Deque.appendleft.items is false
explanation:
  ys = [0, 1]
  self.items = [1]
  is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) = true
  if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) then ys[0:unwrap(self.maxlen)] else ys = [0]
verdicts: 5 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_appendleft_wrong_end::Deque[T=string].appendleft.items` (expected failure)

```text
Deque[T=string].appendleft.items (ensures) failed as expected (expect_fail)
  ensures items: let ys = [x] + old(self.items) in self.items == (if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) then ys[0:unwrap(self.maxlen)] else ys)
  in Deque.appendleft with T=string

inputs:
  self = d1 = Deque { items: ["0"], maxlen: some(1) }
  x = ""
observed:
  steps:
  1. d1 = Deque.bounded(n=1)
  2. d1.append(x="0")
  3. d1.appendleft(x="")
  result = unit
  Deque.appendleft.items is false
explanation:
  ys = ["", "0"]
  self.items = ["0"]
  is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) = true
  if is_some(self.maxlen) and len(ys) > unwrap(self.maxlen) then ys[0:unwrap(self.maxlen)] else ys = [""]
verdicts: 1 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_appendleft_wrong_end::Deque[T=string]' --spectest-seed=0
```

### `test_seeded_rotate_backwards::Deque[T=i64].rotate.items` (expected failure)

```text
Deque[T=i64].rotate.items (ensures) failed as expected (expect_fail)
  ensures items: let xs = old(self.items) in self.items == (if len(xs) == 0 then xs else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)])
  in Deque.rotate with T=i64

inputs:
  self = d1 = Deque { items: [0, 0, 1], maxlen: none }
  n = 1
observed:
  steps:
  1. d1 = Deque.empty()
  2. d1.append(x=0)
  3. d1.append(x=0)
  4. d1.append(x=1)
  5. d1.rotate(n=1)
  result = unit
  Deque.rotate.items is false
explanation:
  xs = [0, 0, 1]
  self.items = [0, 1, 0]
  len(xs) == 0 = false
  if len(xs) == 0 then xs else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)] = [1, 0, 0]
verdicts: 51 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_rotate_backwards::Deque[T=string].rotate.items` (expected failure)

```text
Deque[T=string].rotate.items (ensures) failed as expected (expect_fail)
  ensures items: let xs = old(self.items) in self.items == (if len(xs) == 0 then xs else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)])
  in Deque.rotate with T=string

inputs:
  self = d1 = Deque { items: ["0", "", ""], maxlen: some(3) }
  n = 1
observed:
  steps:
  1. d1 = Deque.bounded(n=3)
  2. d1.append(x="0")
  3. d1.append(x="")
  4. d1.append(x="")
  5. d1.rotate(n=1)
  result = unit
  Deque.rotate.items is false
explanation:
  xs = ["0", "", ""]
  self.items = ["", "", "0"]
  len(xs) == 0 = false
  if len(xs) == 0 then xs else xs[len(xs) - n % len(xs):len(xs)] + xs[0:len(xs) - n % len(xs)] = ["", "0", ""]
verdicts: 26 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_rotate_backwards::Deque[T=string]' --spectest-seed=0
```

### `test_seeded_popleft_returns_none::Deque[T=i64].popleft#1` (expected failure)

```text
Deque[T=i64].popleft#1 (raises) failed as expected (expect_fail)
  raises IndexError when len(self.items) == 0
  in Deque.popleft with T=i64

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.popleft() returned NoneType None
  returned NoneType None, which is not i64
  IndexError was due (len(self.items) == 0 holds), but the call returned
explanation:
  raises IndexError when len(self.items) == 0 = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_popleft_returns_none::Deque[T=i64].popleft#type` (expected failure)

```text
Deque[T=i64].popleft#type (type) failed as expected (expect_fail)
  built-in: the result of Deque.popleft reads as its declared type
  in Deque.popleft with T=i64

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.popleft() returned NoneType None
  returned NoneType None, which is not i64
explanation:
  result = NoneType None
verdicts: 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_popleft_returns_none::Deque[T=string].popleft#1` (expected failure)

```text
Deque[T=string].popleft#1 (raises) failed as expected (expect_fail)
  raises IndexError when len(self.items) == 0
  in Deque.popleft with T=string

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.popleft() returned NoneType None
  returned NoneType None, which is not string
  IndexError was due (len(self.items) == 0 holds), but the call returned
explanation:
  raises IndexError when len(self.items) == 0 = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {}
  raised = nothing (the call returned)
verdicts: 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]' --spectest-seed=0
```

### `test_seeded_popleft_returns_none::Deque[T=string].popleft#type` (expected failure)

```text
Deque[T=string].popleft#type (type) failed as expected (expect_fail)
  built-in: the result of Deque.popleft reads as its declared type
  in Deque.popleft with T=string

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.popleft() returned NoneType None
  returned NoneType None, which is not string
explanation:
  result = NoneType None
verdicts: 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_popleft_returns_none::Deque[T=string]' --spectest-seed=0
```

### `test_seeded_pop_raises_keyerror::Deque[T=i64].pop#1` (expected failure)

```text
Deque[T=i64].pop#1 (raises) failed as expected (expect_fail)
  raises IndexError when len(self.items) == 0
  in Deque.pop with T=i64

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.pop() raised KeyError: -1 (no spec error maps it)
  raised KeyError: -1 (no spec error maps it)
  IndexError was due (len(self.items) == 0 holds), but the call raised KeyError: -1 (no spec error maps it)
explanation:
  raises IndexError when len(self.items) == 0 = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {}
  raised = KeyError: -1 (no spec error maps it)
verdicts: 2 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_pop_raises_keyerror::Deque[T=i64].pop#raises` (expected failure)

```text
Deque[T=i64].pop#raises (raises) failed as expected (expect_fail)
  built-in: Deque.pop raises only what a raises or may_raise admits
  in Deque.pop with T=i64

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.pop() raised KeyError: -1 (no spec error maps it)
  raised KeyError: -1 (no spec error maps it)
  no spec error maps KeyError, so no raises or may_raise admits it
explanation:
  raises IndexError when len(self.items) == 0 = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {}
verdicts: 2 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_pop_raises_keyerror::Deque[T=string].pop#1` (expected failure)

```text
Deque[T=string].pop#1 (raises) failed as expected (expect_fail)
  raises IndexError when len(self.items) == 0
  in Deque.pop with T=string

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.pop() raised KeyError: -1 (no spec error maps it)
  raised KeyError: -1 (no spec error maps it)
  IndexError was due (len(self.items) == 0 holds), but the call raised KeyError: -1 (no spec error maps it)
explanation:
  raises IndexError when len(self.items) == 0 = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {}
  raised = KeyError: -1 (no spec error maps it)
verdicts: 3 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]' --spectest-seed=0
```

### `test_seeded_pop_raises_keyerror::Deque[T=string].pop#raises` (expected failure)

```text
Deque[T=string].pop#raises (raises) failed as expected (expect_fail)
  built-in: Deque.pop raises only what a raises or may_raise admits
  in Deque.pop with T=string

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.pop() raised KeyError: -1 (no spec error maps it)
  raised KeyError: -1 (no spec error maps it)
  no spec error maps KeyError, so no raises or may_raise admits it
explanation:
  raises IndexError when len(self.items) == 0 = true
  errors that must be raised (R) = {IndexError}
  errors that may be raised (M) = {}
verdicts: 3 pass, 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_pop_raises_keyerror::Deque[T=string]' --spectest-seed=0
```

### `test_seeded_rotate_loses_bound::Deque[T=i64].rotate.maxlen` (expected failure)

```text
Deque[T=i64].rotate.maxlen (ensures) failed as expected (expect_fail)
  ensures maxlen: self.maxlen == old(self.maxlen)
  in Deque.rotate with T=i64

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
  n = 0
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.rotate(n=0)
  result = unit
  Deque.rotate.maxlen is false
explanation:
  self.maxlen = none
  old(self.maxlen) = some(0)
verdicts: 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=i64]' --spectest-seed=0
```

### `test_seeded_rotate_loses_bound::Deque[T=string].rotate.maxlen` (expected failure)

```text
Deque[T=string].rotate.maxlen (ensures) failed as expected (expect_fail)
  ensures maxlen: self.maxlen == old(self.maxlen)
  in Deque.rotate with T=string

inputs:
  self = d1 = Deque { items: [], maxlen: some(0) }
  n = 0
observed:
  steps:
  1. d1 = Deque.bounded(n=0)
  2. d1.rotate(n=0)
  result = unit
  Deque.rotate.maxlen is false
explanation:
  self.maxlen = none
  old(self.maxlen) = some(0)
verdicts: 1 fail (stateful)
seed: 0
reproduce: uv run pytest 'examples/deque/test_deque.py::test_seeded_rotate_loses_bound::Deque[T=string]' --spectest-seed=0
```
