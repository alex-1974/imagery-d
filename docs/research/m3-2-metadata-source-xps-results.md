# M3.2.18 — Independent Dell XPS ordered-ROI metadata source qualification

**Qualified on:** 2026-10-12. **Verdict:** independent source-level
evidence integrity **PASS**, old/new immutable metadata-generation
semantics **PASS**, actual calibrated mask-aware ROI pixel corners
**153,600/153,600 PASS**, and **0 measured GC bytes inside all 2,560
`@safe @nogc` packet-mapping calls**. This **does not** prove a public
owner API, cached Prepared binding across packets, zero-cost immutable
source construction, universal worst-case latency or new performance
speedup over M3.2.17.

Related: [issue #58](https://github.com/alex-1974/imagery-d/issues/58),
[stacked draft PR #59](https://github.com/alex-1974/imagery-d/pull/59),
[protocol](m3-2-long-lived-metadata-source-ordered-roi.md),
[prior M3.2.17 XPS research](m3-2-metadata-owner-xps-results.md).

## 1. Exact recorded provenance

- **Independently hashed uploaded archive:**
  `metadata-source-20261012T203340Z.tar.gz`, SHA-256
  **`38d29a92dc515d71d249d738806362bab2888dc9205ebf750a77b2fce17151fb`**.
  The raw archive is not checked into Git.
- **Measured imagery-d HEAD:**
  `214508687076228173dd73c958ace2a7579da3bc`,
  branch `research/m3-2-18-metadata-source-ordered-roi`.
  [Four-compiler correctness+hosted runner CI #38303903338](https://github.com/alex-1974/imagery-d/actions/runs/38303903338)
  **4/4 SUCCESS**: DMD 2.111/2.113, LDC 1.41/1.43.
- **Local raster-d HEAD:**
  `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
  which **differs from** the peeled `v0.2.0` tag
  `2f2415851e45001df92ce56dad409f680684ba8d`.
  The archived build says `raster-d ~release/0.2`.
  This is **local-state research, not an exact v0.2.0-release
  baseline**. No sibling repository has been modified.
- **Host/build:** Dell XPS 15, Intel Core i7-9750H,
  Ubuntu `6.17.0-22-generic`, `ldc2` 1.41.0
  (DMD frontend 2.111.0, LLVM 19.1.7), DUB 1.40.0,
  `release` build. CPU governor `powersave`,
  OS-default affinity; CPU frequency, contention and thermals
  were not independently fixed. Before-run available RAM
  was approximately 5.9 GiB; swap ~3.9/4.0 GiB occupied.
  Five system before/after windows show **zero change in
  `pswpin`, `pswpout` and `pgmajfault`**; full swap
  is a confound, **not evidence of swap I/O causing stalls**.
- **Reported optimized binary SHA-256:** 
  `f2d1b66f52cf978639888f514076548020368ccc1f8cf394cc1f8ef8e8af7f746221fd6`.
  The archive contains its hash manifest, symbol table and
  compressed `objdump` disassembly, but **not the executable
  bytes**; the binary hash cannot be independently reproduced.
  Build, existing safety/lifetime test logs and provenance remain
  separately archived. Prior workspace documents continue to govern
  future architecture and promotion.

## 2. Independent replay, not just trust in the in-repo analyzer

The raw archived run has:

- **5 repeats × 2 source modes × 2 ROI sides × 2 reuse counts = 40
  separate operating-system processes**.
- **32 original-generation + 32 refreshed-generation packet calls
  per process = 2,560 actual packets**.
- For both 4 and 16 ROIs per packet, **25,600 individually ordered,
  physically mapped ROI observations**, each with both pixel
  corners in all 3 output lanes: **153,600 separately checked
  floating-point pixel values**.

An independent replay, **not importing**
`tools/analyze_metadata_source.py`:

1. Checked every process filename, all 40 distinct required combinations
   and exact `original → refreshed`, packet and ROI index sequence,
   expected ROI origins, ROI side/reuse counts and completion marker.
   Missing, reordered and duplicated rows do not pass.
2. Reconstructed each expected pixel from the **actual source fixture
   and channel binding**, not a self-reported expected number:
   selected channels `(254, 253, 255)`;
   stored value `channel*16 + 2*y + x`;
   original calibration `0.625*v - 6`;
   refreshed calibration `0.6875*v - 7`;
   validity mask `(x+y)%11 == 0 → 0`;
   first and final `(side-1,side-1)` ROI pixels.
   The maximum observed absolute discrepancy caused by D's
   printed floating-point formatting was **0.005**.
   The independent acceptance criterion is **≤0.01001 absolute**,
   accounting for the test's default approximately six-significant-
   decimal-digit console representation at ~3,000 magnitude.
   It is a printed-evidence tolerance, not a numerical accuracy
   guarantee on unrounded internal float outputs.
3. Matched all **25,600 complete raw ROI records** against
   `metadata-source-rois.csv`, and all **2,560 complete packet
   records** against `metadata-source-packets.csv`, including every
   nonzero elapsed-time value and every zero GC-allocation delta.
4. Independently calculated and compared all **40 process totals,
   maximum elapsed times, ROI row counts and GC byte totals**
   against `metadata-source-processes.csv`. JSON summary counts
   and declared semantics match the raw evidence.
5. Confirmed first/last pixel values **really change as specified
   between generations**, with old-source phase returning old
   calibration after the original mutable arrays were modified,
   and explicitly reconstructed refreshed-source semantics
   returning the new calibration.
6. Each process also prints the D-side **full, all-pixel,
   all-three-component last-ROI oracle PASS** marker. This
   corroborates full last-ROI correctness; the *external*
   independent replayer checks **two opposed corners per ROI**,
   **not every interior pixel in every intermediate ROI**.
7. Validated the positive end markers for inherited
   M3.2.6/9/11/12 correctness and private lifetime/forgery
   negative test logs. Four-compiler hosted CI additionally
   qualifies the entire actual runner and analyzer fixtures,
   including adversarial reordered/forged ROI entries.
8. Archived LDC disassembly and symbol list contain the actual
   `ResearchLongLivedMetadataSource.tryMapOrderedInto`
   and `runMetadataSourceOrderedExperiment` symbols, the
   private checked 3-component pixel kernel
   `researchExecuteCheckedPixels` and its real call sites.
   Existing `gc_malloc` / `memcpy` routines also appear
   in the binary: they are used by fixture/snapshot creation
   and other experiment code, not proof that mapping allocates
   each call. The per-packet GC counter and `@nogc`
   compiler gate are the relevant hot-path evidence.

**Admission:** independent completeness and six-value-per-ROI
physical consistency **PASS**. The new ordered transcript closes
M3.2.17's *order-blind aggregate checksum* gap; it does not
fully certify unobserved interior pixels of intermediate ROIs.

## 3. Measured source-session packet times

For each **mode × ROI-side × ROI-count**, there are **five
independent processes × two phases × 32 packets = 320 observed
packet times**. Medians below are descriptive medians of packet
duration in **microseconds**. A packet comprises validation,
Prepared construction and actual repeated calibrated mask-aware
three-lane pixel mapping; original source construction or snapshot
refresh **does not appear in the timed packet**.

| ROI size | ROIs/packet | `immutable` median | `snapshot` median | `immutable` maximum | `snapshot` maximum |
|---|---:|---:|---:|---:|---:|
| 8×8 | 4 | **2.7 µs** | **2.7 µs** | 31.8 µs | 36.0 µs |
| 8×8 | 16 | **10.3 µs** | **10.3 µs** | 79.9 µs | 55.4 µs |
| 32×32 | 4 | **36.7 µs** | **36.7 µs** | 103.5 µs | 139.9 µs |
| 32×32 | 16 | **145.95 µs** | **145.7 µs** | 311.6 µs | **410.9 µs** |

Mode origin matters at **snapshot acquisition time**, not as a
repeated mapping representation difference; the caller's actual
semantic content and mappings are held equivalent for each
original/refreshed phase. The observed typical packet times
therefore agree closely in this workload.

There is **no consistent process-level performance winner**:
the per-process selected in-window total signs between modes
vary. Five processes are the independent repeat unit, not
320 iid randomized trials. These two source-owner modes
**also do not have equivalent caller construction costs**, so
no one-shot/full-lifecycle speedup ratio is admitted.

**Selected 64-packet sum, median of five process totals**
(millisecond, excludes provider initial construction and
refresh/fixture/GC measurement/integration overhead):

| ROI size | ROIs/packet | `immutable` | `snapshot` |
|---|---:|---:|---:|
| 8×8 | 4 | **0.1852 ms** | **0.1793 ms** |
| 8×8 | 16 | **0.7220 ms** | **0.7123 ms** |
| 32×32 | 4 | **2.7802 ms** | **3.0343 ms** |
| 32×32 | 16 | **10.3575 ms** | **10.0947 ms** |

The medians may conceal different across-process tails; the
underlying source-log and process-level evidence is retained
externally. Do not classify these different source initialization
models as paired equivalent consumer treatments.

## 4. Non-GC tails remain and their cause is unisolated

The **largest observed packet** was **410.9 µs** in
`snapshot` / 32×32 / 16 ROIs, refreshed phase, process repeat 1,
packet 24. The same stratum has multiple packets around 300–376 µs,
whereas its typical packet is ~146 µs. All sampled packet-GC
allocation counters were zero; this means the old snapshot
re-allocation issue was removed **from this measured hot path**,
not that the CPU/cache/OS runtime has no unrelated latency variance.

Unlike M3.2.16, M3.2.18 did **not** instrument per-packet collector
pause duration, minor/major faults, CPU scheduling or thermal
frequency. These tails cannot be attributed to a GC pause, a page
fault, paging or any particular optimization mechanism. Process
startups, CPU `powersave`, host contention and cache/memory
interference remain confounds. The five OS-level before/after
`pgfault` deltas include other host processes and are **not**
per-mapping minor-fault counts.

**No bounded worst-case latency / real-time guarantee is admitted.**
Zero per-packet GC allocation is narrower than zero GC activity
in the process, and substantially narrower than zero page faults.

## 5. Ownership/security interpretation

- `ResearchLongLivedMetadataSource` holds **GC-backed immutable
  ChannelDescriptor[] and IntrinsicChannel[]** through the existing
  `ResearchMetadataState`. `fromImmutable` borrows already truly
  immutable backing; `snapshot` explicitly copies potentially
  mutable/const arrays via `.idup`.
- In the XPS research fixture, the mutable source metadata is
  modified **after** creating the original metadata source.
  The already published original source retains the original
  scale, offset and `sourceLabel`, while the refreshed source
  captures the changed values. D-side fixed semantic checks and
  independent refreshed-vs-original pixel oracles pass.
- Pixmap and validity `RasterView` inputs are **only borrowed
  within the scoped call**; the owner does not store escaped
  borrowed raster references or promote a `PreparedSemanticMap`
  beyond the image/validity borrow lifetime. Existing DIP1000
  negative gates remain enabled.
- Two caller-owned output arrays record six observations per ROI;
  the actual output raster is reused. No new GC allocation
  is permitted/observed within the `@safe @nogc` mapping
  method; it nevertheless performs O(channelCount) verification
  **once per packet**. Cross-packet caching is **not tested**.
- Mutable→immutable **zero-copy freeze remains unsolved**.
  No cast-based alias bypass, general-purpose allocator,
  move-only unique metadata owner, new `containers-d`
  API or production `ImageLease` is introduced.
- The inherited negative gates do not alone prove every
  possible malformed-source or failure-path behavior of this
  experimental adapter. A dedicated source-lifetime, invalid
  window, destination mismatch and error-state matrix would
  be appropriate before considering public promotion.

## 6. Decision and next bounded gate

**Accepted research findings:** source metadata can be
initialized/explicitly snapped once, retained as genuine
immutable backing, and reused across original/refreshed
ROI sessions with **independent per-ROI ordered physical-pixel
observations**; all 2,560 packet calls allocate zero new
GC metadata bytes. The M3.2.17 unknown intermediate ROI
ordering has now been replaced by a test that detects
reordering and sample-coordinate corruption at six
different observed pixels per ROI.

**Not admitted:** new production/public API, metadata lifecycle
allocation being globally free, guaranteed absence of GC pauses
or page faults, performance advantage of `immutable` over
`snapshot`, identical results with exactly tagged raster-d,
cross-packet Prepared caching, mutable zero-copy ownership
transfer or a hard latency ceiling.

**Next targeted work** should be small:
validate source-adapter failure paths and newly introduced
scope contracts with both positive runtime matrices and
dedicated compiler-negative escape cases; provide optional
independent order-sensitive **full-ROI** hashing/oracle for
intermediate windows if needed for broader numerical
qualification; then separately test whether source-level
cached Prepared state is safe and actually amortizes
validation across packets. Any performance comparison needs
complete caller lifecycle accounting and repeatable
process-level reference controls, not a simple median
of isolated packet durations.

**PR #59 stays OPEN/DRAFT**, stacked on PR #57. No
merger into `develop` and no sibling repo writes.
