# Code organization

The repository has four layers:

```text
source/imagery/package.d       consumer-facing facade
source/imagery/presentation/   tone and exposure operations
source/imagery/analysis/       filters, edges, masks, segmentation, indices
source/imagery/compositing/    alpha/validity-aware compositing
source/imagery/pyramid/        overview-level selection
```

The small analysis modules (`filters`, `edges`, `morphology`, `segmentation`,
and `indices`) are the navigation surface. Their implementations currently
share the compatibility module `analysis.primitives`; new code should be
added to the relevant category module first and promoted to a dedicated
implementation module when it grows beyond a focused operation family.

Execution and raster-adapter contracts are advanced integration APIs. They are
not re-exported by `import imagery;`; consumers that need them import the
specialized modules explicitly.

Tests are grouped by contract (`api_contract`), consumer behavior, corpus
validation, precision, and performance. A change should add the smallest
focused test target that proves its contract rather than expanding a large
consumer executable.

