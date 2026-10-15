# M3 RGBA — public raster-d pre/post-commit metadata ENOMEM control

**2026-10-15 · Issue #75 · stacked Draft PR #73 · research-only.**
**Qualification:** IMPLEMENTED; the current exact-commit four-compiler
CI must pass before reporting the test as successful. No public
imagery-d source, package API, allocator, cache or release change.

## Previously established contracts

An independent `imagery-d` consumer already verifies one public
`tryImportOwnedRaster!SRgba8` invalid-stride failure:
`invalidPlaneLayout + unchanged`, followed by a successful
import of the **same armed OwnedByteResource**. That is an
*ordinary layout failure*, not an actual native allocation failure.

The [separate true pixel malloc control]
(m3-rgba-native-pixel-malloc-fault-contract.md)
qualifies direct `malloc == NULL` at two explicitly owned
pixelbuffer allocation sites, including scratch lifetime,
quota refund and subsequent recovery. Those calls happen
**before** `raster-d`'s own metadata allocation steps.
Neither test had previously induced both pre-commit and
post-commit importer metadata failures through the **public**
import surface.

Read-only audit of pinned
`raster-d v0.2.0` SHA
`2f2415851e45001df92ce56dad409f680684ba8d`:

- [`import_single_resource.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/import_single_resource.d):
  one temporary `PlaneDescriptor` allocation precedes
  `relinquishResource()`; its failure leaves the owned
  resource armed.
- [`construction.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/construction.d):
  ownership is adopted on entry. Failure of the first
  retained `ResourceEntry` metadata allocation releases
  that resource on unwind, with no resulting backing.
- [`import_owned.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/import_owned.d):
  maps the first failure to public
  `temporaryMetadataAllocationFailed + unchanged`,
  and the second to
  `backingAllocationFailed + releasedAfterCommit`.
- [`owned_resource.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/owned_resource.d):
  the `OwnedByteResource` token is move-only and, while
  armed, releases its physical allocation exactly once.
  A disarmed token must not release the same allocation.

The above source audit establishes the expected branch
semantics; this new research test must **independently
exercise them** through the public import API. The existing
package-internal raster-d unit tests also inject metadata
allocation failure with private allocator hooks; we are not
copying those hooks or modifying that sibling repository.

## Implemented fault-control design

Extend the already separate opt-in research-only
`native-pixel-faults` DUB configuration in
`experiments/m3_rgba_layer_compositing/smoke`, with the
glibc `LD_PRELOAD` shim
`alloc_events/m3_fail_pixel_malloc.c`.

The existing real pixelbuffer-ENOMEM tests (kinds 1 and 2)
remain as before. New **kind 3 and kind 4** trials begin with
an independently allocated 1,024-byte packed-RGBA backing
actually obtained via `malloc`, adopted via public
`tryAdoptMallocResource`, and placed in a local armed
`OwnedByteResource`. The C shim records the particular
backing's ephemeral physical pointer solely to distinguish
its release from unrelated malloc/free calls. No pointer
is exported to users or stored in the production code.

Each trial opens a **narrow interval** around the public
`tryImportOwnedRaster!SRgba8` call; the shim injects a
single `malloc` failure with `errno=ENOMEM` for the
specified metadata request size in this interval and
immediately disarms. Source-backed x86-64
`PlaneDescriptor.sizeof=24` and
`ResourceEntry.sizeof=40` are **pinned request-size
selectors, not a portable size contract**. If a compiler
or upstream ABI changes the real request sizes, the
test must fail and be re-audited instead of accepting a
different allocation.

| Trial | Injected importer metadata request | Expected public outcome | Pixel owner and C free-count |
|---|---|---|---|
| **3: pre-commit** | 24 B temporary `PlaneDescriptor` array | `temporaryMetadataAllocationFailed`, `resourceDisposition=unchanged` | Armed token remains owner; zero frees before leaving its scope, **exactly one** free on scope exit |
| **4: post-commit** | 40 B stable `ResourceEntry` metadata | `backingAllocationFailed`, `resourceDisposition=releasedAfterCommit` | Token is disarmed; raw physical allocation is already freed **once** before return and is never freed again |

Both tests additionally require exactly one injected
`malloc` failure, the correct selected fault kind,
a genuinely empty `RasterLease!SRgba8` result,
and one initial tracked packed allocation. After each
fault, disarm and reset the shim, then complete a fresh
public `makeOwnedPacked(16,16)` import, verify that its
lease is live, and observe exactly one pixel release
when the last local owner leaves scope.

CI compiles C under `-std=c11 -O2 -Wall -Wextra -Werror
-fPIC -shared`, runs the independent DUB release consumer
on DMD 2.112.1 / 2.113.0 and LDC 1.42.0 / 1.43.0,
and rejects a run missing either
`M3 NATIVE IMPORT ENOMEM PASS: kind=3` or
`kind=4` trailer, in addition to the pre-existing
pixel-ENOMEM receipts.

## Narrow conclusions and remaining admission gaps

**If CI passes:** the exact pinned public import
contract behaves consistently at **both** real native
metadata allocation-failure points under the four
compiler configurations. The one physical backing
release is not duplicated or lost and no invalid
retained result is published.

**Still NOT established:** failure of a later retained
descriptor allocation or backing-control allocation,
GC.addRange/Error-level OOM, arbitrary alternative
allocators/platforms, threads and cancellation,
failure after an unrelated import callback, or a
whole-process memory upper bound. The C interposer
matches a requested-size event during a constrained
call window; these tests intentionally do **not**
claim a generic allocation-site tracer or allocator
usable-size meter.

The research owned output helper still throws for
native pixel allocation failure, even when its
reservation is correctly refunded, and validates some
semantic input conditions after scratch creation.
Selection of that **public** error/failure model,
early image preflight and the nonaliased destination
alternative remain separate Issue #75 design gates.

**Decision:** ADAPT the constrained real importer
failure evidence into the design review; DEFER
public M3 API, merge and release. Preserve the
stacked grandfathered PR #73 and write only to
`imagery-d`.
