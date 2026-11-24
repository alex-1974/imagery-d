# Cross-block component regions

The opt-in `imagery.analysis.feature_components` module labels a fixed analysis
domain using explicit 4/8 connectivity, optional seeds, Euclidean single-link
color distance and optional source-anchored cell restrictions. It belongs in
imagery-d: raster-d supplies generic storage, while observations, segmentation
policy and region measurements are image-analysis concepts. General D consumers
can use masks or scalar/color features without adopting Dunia or a decoder.

`ComponentSample.init` is valid but excluded. Labels and validity are distinct:
zero means excluded, unseeded or unobserved, while the validity writer reports
the source's valid flag **and** finite values in all three color channels.
An excluded valid observation remains valid. Texture and edge may be absent
(NaN); each has its own finite sample count. They never change connectivity.

The caller fills requested row windows, keeps source observations stable across
passes and provides a `ComponentStore` that exactly reproduces writes. Windows
are at most 256 output pixels or 258 source/preceding-row pixels. Neither source
nor label storage is retained by the engine. Callbacks are synchronous; their
slices must not escape. DIP1000 rejects direct label-slice retention in the
compile-negative consumer. A RAM array, temporary file or another windowed store
can serve the same label contract.

## IDs and domain

Traversal is row-major regardless of processing block size. A pixel starts a
provisional label only when no accepted, connected preceding neighbor exists.
The final ID is the smallest such provisional label in the connected region;
IDs can have gaps. Seed filtering retains the entire connected region if any
member is a seed. `labelLimit` bounds provisional labels, even when many later
merge into one final component. Exhaustion fails explicitly.

IDs are stable across block sizes and RAM/file backings for the same domain,
revision and policy. They are not globally stable under source edits or changes
to the analysis extent. A smaller independent analysis can lose a connection
through pixels outside its bounds. A viewport therefore reads a crop of the
finalized global store to preserve the original IDs and connectivity. The
independent consumer checks this exact full-domain-to-ROI handoff.

Color distance is measured in the supplied three-channel coordinates. A finite
threshold tests neighboring samples, not a changing centroid or seed mean.
Infinity disables this test; zero requires exact equality. `cellEdge` restricts
joins to source-anchored grid cells, with integer coordinate division even above
2^53. This is connected single-link cell segmentation, **not color SLIC**.

`imageComponents` supplies OKLab for RGB or a scalar channel, optionally adding
texture/edge observations. `cannyComponents` supplies Sobel3x3/8 and asymmetric
directional NMS candidates; label with diagonal=true and requireSeed=true for
global hysteresis. This adapter differs from the legacy scalar primitive's
inclusive NMS and outer-ring contract. The reference tests its own declared
rules rather than equating these two APIs.

## Publication and failure

`labelComponents` is a low-level staging operation. Label writes and all sinks
may be partial on failure. They become usable only after successful return.

`tryLabelComponentsTransactional` makes the boundary explicit. Supply a
`ComponentTransaction` whose store, validity, region records and side contacts
all write private staging. Its nonthrowing `commit` publishes the complete
result, typically by swapping a prepared descriptor. Its nonthrowing `abort`
discards staging and preserves the prior published state and all aliases.
Allocate, perform I/O and validate before commit. The caller implements the
atomic store boundary; writing into an already published backing violates the
contract. A durable filesystem transaction or fsync is not provided.

After valid commit/abort callbacks are supplied, exactly one is called. Invalid
requests, budget/label exhaustion, malformed store labels, invalid states,
statistics overflow, cancellation and callback exceptions all abort. D Errors
also run abort and are rethrown. An absent commit/abort returns invalidRequest
without invoking either. `ComponentResult.init.ok` is false. A callback throwing
`ComponentFailure(none, ...)` cannot authorize publication.

Cancellation is polled initially, before every processing block in both passes,
and after final statistics callbacks. Cancelled jobs never commit. The documented
source unittest is an executable complete-publication example; regressions
preserve a previous published owner/alias for failures at each stage.

## Region measurements and neighbors

Records include ID, source-coordinate bounds, accepted-pixel area, three means
and population variances, finite texture/edge counts and means, four-neighbor
perimeter, fill ratio and spatial principal-axis orientation in [0, pi).
The axis is valid only when max(abs(xx-yy), abs(2xy)) exceeds
64*double.epsilon*trace of the centered spatial covariance. Symmetric footprints
do not acquire an orientation from roundoff. Requested statistics that overflow
fail instead of producing a successful NaN record.

`regionEvidence` derives compactness and texture/edge coverage. `ContactSink`
emits a sorted ID pair once per shared horizontal/vertical pixel side, excluding
label zero; a consumer can aggregate contacts into a weighted graph in RAM or
on disk. Diagonal connectivity does not invent a shared side.
`traceLabelLines` emits maximal constant-label runs in four grid directions;
intersections can participate in multiple runs. It is not a fitted vector-line
detector. Its approximately four single-pixel reads per pixel can be expensive
for file-backed stores; it runs separately from labeling.

Provenance preserves caller identity/revision/grid/band/unit/level and records
the exact extent, policy and implementationVersion=2. Schema/class interpretation
(water, building, road) remains with the consumer.

## Memory and qualification

The engine allocates one node table, sized by provisional labelLimit, plus fixed
row scratch. `componentScratchBytes` checks the product/sum and reports their
payload. The transactional entry point requires an explicit maxScratchBytes and
checks it before allocation or source reads. There is no full-source or full-domain
label allocation inside imagery-d. Caller-owned label/validity stores scale with
the analysis domain (4N+N bytes for this harness's compact RAM form); they can be
disk-backed. Records and contacts may be streamed into caller-controlled stores.

The bound excludes GC headers, runtime stack/closure bookkeeping, source-provider
memory, caller stores and callback allocations. In particular, image adapter
Engine cache/scratch is provider memory, not included in componentScratchBytes.
There is no @nogc/nothrow or allocation-free claim. Single-threaded scheduling
remains with the consumer. Computational work is two raster passes plus
union/find traversal and O(labelLimit) table setup/record traversal.

The [qualification receipt](benchmarks/component-regions-2026-11-22.md) covers
independent graph/SciPy references, exact partitions/backings/crops, actual
adapter cases and a real Marchfeld scene. This admits the bounded component
contract as a candidate. [Color-SLIC and the owned region graph](color-slic-region-graph.md)
are now implemented separately under ADR 0020. Manually reviewed Dunia
application acceptance remains open under #187.
