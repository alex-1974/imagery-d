# ADR 0026: bounded ordered Gaussian derivative blocks

Date: 2026-11-24

Status: implementation candidate; final paired performance admission pending

Related: #217, ADR 0024

## Decision

Evaluate Hessian and tensor derivatives over two-dimensional blocks with
explicit source halos. Keep each pixel's original tap order, Float64 working
precision, source-edge replication, scale/polarity order and winner ties.
Do not fold smoothing taps, narrow intermediate storage, approximate exp/atan2
or substitute a recursive Gaussian.

Hessian stores three horizontal families over one block's vertical halo.
Smoothing retains -r..r order; derivatives share paired source loads while
retaining +1..r order. Fuse vertical work into rows and publish immediately.

Tensor computes gradient families over the composed halo, then products over
the integration support. Reuse gradient carriers for horizontal integration
once their inputs are dead, and product carriers for final vertical rows.
Global coordinates preserve whole-image/ROI equality.

Two-lane Float64 geometry uses architecture-neutral LLVM sqrt vectors under
LDC, with an exact scalar twin under DMD. Tensor and Hessian retain their
distinct quadratic expressions and multiplication order. Winner/validity and
scalar angle/Frangi library calls preserve the prior contract. No fast-math or
new CPU attribute is used. The finite Float32 input and parameter bounds make
sqrt radicands nonnegative; negative sqrt behavior is not substituted.

## Reservation and ownership

Keep reserve(samples) compatible: it retains full-plane capacity without
guessing an aspect ratio. Evaluation uses blocks within that capacity. New
shape-aware overloads take width, height, scales/parameters and optional block
dimensions. Only these forms claim reduced owned payload; evaluation never
silently allocates.

Hessian defaults to 128 rows by 128 columns after the retained 15-shape,
three-round sweep; tensor retains 32 rows by 128 columns because its small
timing difference does not justify the additional memory. Hessian uses three
halo carriers: 480 KiB at 1024², scales 1,2,4, plus a fixed
6 KiB row stack. Tensor accounts separately for two gradient/integration,
three product and one integration carrier, plus a fixed 7 KiB gradient-row
stack. Gaussian weights, metadata and caller input/output are additional.
Shape-aware payload above 8 MiB is rejected before replacement. These are
owned payloads, not RSS or a guarantee the whole workload fits L2.

Reservation is transactional. Evaluation checks shape, finiteness, destinations
and the scale/shape envelope before writes. Scratch copies still share storage
and require serial use with disjoint input/output.

## Qualification

Retain prior full-plane algorithms as private unittest twins. The dedicated
ImageryGaussianReference benchmark version invokes those original bodies with
legacy reservation; ordinary production builds do not emit them. Original pass
helpers remain unchanged for those references.

Exact tests cover every Hessian formula/polarity, fractional scales, narrow/odd
shapes, scientific offsets, signed zeros, multiple block sizes and zero GC
bytes. Tensor includes zero integration and maximum scales. Independent
scipy/NumPy and ROI/partition checks still qualify both compiler paths.

Record source/flags, fingerprints, halo-inclusive payloads and Callgrind cache
model. Sweep timings are descriptive; later complete paired ABBA cycles under
the unchanged #212 protocol support improvement/admission. Keep the post-#215
Hessian baseline (~414 ns/pixel) and 325 ns/pixel absolute first target distinct.
