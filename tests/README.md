# Test organization

- `api_contract/`: compile-time ownership and visibility contracts.
- `consumer/`, `archive_consumer/`, `ppm_consumer/`: end-to-end consumer
  programs built through DUB.
- `precision_consumer/`: numerical and bit-level behavior.
- `corpus/`: deterministic Python reference checks.
- `perf_consumer/`, `perf_primitives/`: benchmark-only executables.

Keep production behavior tests close to the smallest applicable target; use
the performance targets only for measurements, not correctness assertions.

