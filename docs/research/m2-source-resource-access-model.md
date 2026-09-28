# M2.1 — Source / Resource / Access Model

**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Issue:** `M2.1 — Define source / resource / provider model`
**Status:** Research draft — not a public API
**Date:** 2026-09-22

## Purpose

M2.1 defines the source-side architecture that sits above the accepted M1
imagery-product model and below later region materialization, caching and
request scheduling.

The problem is not merely how to open a file. `imagery-d` must eventually
support local files, memory, HTTP resources, range-readable imagery such as
COG, tiled services, archives/virtual files, generated sources, caches and
future application-specific backends.

The model must not make URL, filename, transport, codec, cache or provider
organization synonymous with resource identity.

No spelling below is a public API commitment.

## Inputs from M1

M1 already establishes that:

- product is not file;
- one product can have multiple resources;
- one resource can expose multiple product components;
- product components are semantic;
- `ImageView!T` is a resident common-grid processing view;
- `raster-d` owns decoded raster backing, leases, views, ROI and generic
  resident-raster mechanics.

M2.1 therefore concerns how source resources are described and accessed before
resident raster materialization.

## Reference-system findings

### GDAL VSI

GDAL's Virtual System Interface lets drivers access ordinary files, memory,
compressed archives and network-hosted data through a file-like abstraction.
VSI handlers can be chained, for example ZIP over HTTP.

Architectural lesson:

> byte access and raster decoding are separable responsibilities.

The main caution for `imagery-d` is that path-like backend prefixes are useful
locators but should not become semantic resource identity.

### OpenImageIO

OpenImageIO readers can operate through custom `IOProxy` objects rather than
only filesystem paths. Its `ImageCache` retains file handles and pixel tiles
and supports invalidation when the underlying file changes.

Architectural lessons:

- decoder and transport can be separated;
- open handles are operational state, not semantic identity;
- mutable resources require revision/invalidation semantics;
- already-held decoded pixel references may remain valid while newer access
  observes a changed source.

### libvips

libvips can load through explicit `VipsSource` objects as well as filenames.
Its evaluation model is demand-driven and can stream or partially evaluate data
depending on format and access pattern.

Architectural lessons:

- filename is only one source form;
- source capabilities matter;
- sequential-only and random-access sources are materially different;
- source access and image semantics should remain separate.

### STAC

A STAC Item has an identifier and a dictionary of Assets. Each Asset has an
item-local key plus an `href` locator, media type and semantic roles. STAC
separately models providers with roles such as producer, processor, licensor
and host.

Architectural lessons:

- semantic identity and storage/network location are distinct;
- asset role is not encoded in its URL;
- "provider" commonly means an organization rather than a technical access
  driver.

Because of that terminology collision, M2 should avoid `Provider` as the name
of the low-level technical access abstraction unless later evidence strongly
justifies it.

### HTTP validators

HTTP distinguishes a resource from a selected representation. ETag is an
opaque representation validator and can be strong or weak. Last-Modified is
another validator but is generally weaker.

Architectural lessons:

- URL is a locator, not immutable version identity;
- revision/version information is distinct from locator;
- validator strength matters;
- ETag is not a universal content hash;
- content hashes are stronger for byte identity when available.

## Provisional terminology

M2.1 should provisionally separate:

    Source
    Resource
    Locator
    Revision
    Access Backend
    Read Session

Provenance remains metadata rather than an access mechanism.

The pressure cases below require `Source` as a concept distinct from a concrete
byte-addressable Resource. A COG may map one Source to one Resource, while a
tile service maps one Source to a family of tile Resources, and a generated
Source may materialize raster data without any encoded Resource at all.

## Source

A **Source** is the stable imagery-side capability or origin from which one or
more product components can ultimately be materialized.

A Source is broader than one encoded object.

Examples:

- one fixed-file imagery source backed by a GeoTIFF/COG Resource;
- one WMTS or OGC API Tiles layer/tileset;
- one source that resolves requests to several mirrored Resources;
- one generated/procedural imagery source;
- one future processing/source node.

A Source can therefore resolve a materialization request in different ways:

    Source
        -> one fixed Resource

    Source
        -> one of many Resources selected by request coordinates

    Source
        -> generated raster data without an encoded byte Resource

This concept is required so that the core model does not force every imagery
origin into a POSIX-file-shaped abstraction.

`Source` is still provisional terminology and not a public D type.

## Source identity

Source identity answers:

> Which logical imagery-producing capability is this?

It must be stable independently of individual concrete fetch URLs or opened
sessions.

For a tiled service, Source identity may include the logical service/layer or
tileset plus intrinsic dimensions needed to distinguish the imagery source.
Individual tile coordinates are request/resource identity, not the Source
identity itself.

For a generated source, identity may derive from a stable operation/source ID
plus immutable configuration/provenance.

Source identity and Resource identity must therefore remain distinct:

    SourceId != ResourceId

A Source may expose zero, one or many Resources over its lifetime.

## Resource

A **Resource** is one concrete addressable representation/object exposed by a
Source or associated with an imagery product.

Examples:

- one GeoTIFF asset;
- one JPEG2000 file;
- one OpenEXR file;
- one metadata sidecar;
- one remote tile object;
- one generated encoded object.

A Resource is not a URL, file descriptor, decoder instance, cache entry,
resident `RasterLease`, or product component.

One resource can expose several components. Several resources can contribute
to one product.

## Resource identity

A resource needs stable identity within the imagery-product/source model.

Provisional invariant:

> Resource identity survives relocation when the logical resource remains the
> same.

Therefore absolute path, URL, redirect target, open handle, pointer or cache
slot are not sufficient resource identities by themselves.

Possible identity origins include:

- product-local stable resource ID;
- STAC item identity + asset key;
- provider-issued immutable object/version ID;
- application-generated stable ID;
- explicitly supplied content-addressed identity.

The representation of `ResourceId` is not frozen.

## Resource versus revision

A logical resource can change over time:

    ResourceId != ResourceRevision

A hosted object can retain logical identity while its encoded bytes change.

This distinction is mandatory for correct cache invalidation.

## Locator

A **Locator** describes one route by which a resource may currently be reached.

Examples:

    /data/scene.tif
    file:///data/scene.tif
    https://example.org/scene.tif
    s3://bucket/key
    memory object reference
    application-specific source key

A locator is operational access information, not automatically semantic
identity.

One resource may have multiple locators: mirrors, a local downloaded copy plus
canonical remote, or temporary signed URL plus stable catalog identity.

## Locator equality

Locator normalization can help operational access but must not silently define
resource equality.

Redirects, signed query parameters, symlinks, relative paths, host aliases and
encoding differences all make locator equality weaker than resource equality.

M2.3 may use normalized locator data as one cache-key component, but never as
the complete identity model.

## Revision

A **Revision** describes the observed version/state of an accessible resource
representation.

Possible strength classes:

    strong
    weak
    unknown

Strong examples:

- cryptographic content hash;
- immutable backend version ID;
- suitable strong HTTP ETag.

Weak examples:

- weak ETag;
- Last-Modified;
- local mtime + size;
- provider generation timestamp.

Unknown is valid and must not be replaced with invented certainty.

## Content hashes

Content hashes are useful for integrity, deduplication, immutable caching and
provenance, but should not replace semantic resource identity.

Two semantically distinct resources can contain identical bytes. One resource
can also acquire a new revision with different bytes.

Thus:

    content equality != semantic resource identity

## Access Backend

An **Access Backend** interprets a supported locator form and creates access to
resource data.

Illustrative examples:

    FileAccessBackend
    HttpAccessBackend
    MemoryAccessBackend
    GeneratedAccessBackend

An access backend is technical capability. It is not the data producer, host
organization, decoder or resource itself.

## Read Session

A **Read Session** is ephemeral operational state obtained when a backend opens
a locator.

It may expose capabilities such as:

- known size;
- sequential read;
- random byte-range read;
- seek;
- concurrent reads;
- observed revision/validator;
- cancellation integration.

A read session may contain a file descriptor, connection/pool state or memory
slice. It is not stable resource identity.

## Capability model

Not all readable sources are equivalent.

Useful capabilities include:

    sequential
    random-access
    known-size
    range-efficient
    concurrent-read-safe
    revision-observable

The important invariant is:

> consumers must not assume random access merely because a source is readable.

This matters for sequential codecs, HTTP servers without range support,
streams and generated sources.

## Capability versus access cost

M2.6 adds an important distinction:

    semantic capability
        !=
    efficient access capability / cost hint

A source may be able to satisfy an arbitrary logical region request while the
underlying format or decoder still requires a full-image or long sequential
decode.

Examples:

- a scanline-oriented decoder may support cropping only after substantial
  sequential work;
- a full-decode-only format can still satisfy a small logical request;
- a COG with HTTP range support can satisfy the same request much more
  efficiently.

The source model should therefore expose, where known, both:

- what access/materialization is semantically possible;
- planning hints about the likely cost or preferred access geometry.

Possible cost/capability hints include:

    natural block size
    sequential-only / preferred order
    random-access support
    range efficiency
    overview availability
    full-decode-only behavior
    concurrent-read capability

These are operational planning facts.

They do not change Source or Resource identity and must not become image
semantics.

## Decoder boundary

A decoder interprets encoded data as image/raster structure. It is separate
from the Access Backend.

Conceptually:

    ResourceDescriptor
        |
        v
    Locator
        |
        v
    AccessBackend
        |
        v
    ReadSession
        |
        v
    decoder
        |
        v
    region materialization
        |
        v
    RasterLease!T
        |
        v
    ImageView!T

M2.2 will define the lower half of this bridge.

## Format detection

Decoder selection must not rely solely on filename extension.

Inputs may be extensionless URLs, signed URLs, memory, virtual resources or
mislabeled files.

Selection may use declared media metadata, explicit caller choice,
signature/probing or backend-specific knowledge.

## Provenance

Provenance is related to a resource but distinct from access.

Examples:

- producer;
- processor;
- host;
- acquisition source;
- processing chain;
- original product identity;
- derived-from relations.

Changing host or access backend must not automatically change producer
provenance.

Example:

    producer = ESA
    processor = downstream processing service
    host = cloud object store
    access backend = imagery-d HTTP implementation

These are distinct concepts.

## Mirrors

A resource may have multiple locators expected to expose the same logical
resource.

That expectation does not by itself prove byte equality. Where exact byte
identity matters, a strong revision/content check is needed.

Mirror failover is access policy, not resource identity.

## Redirects

Following an HTTP redirect should not automatically create a new semantic
resource identity.

The effective locator can still matter operationally for credentials, caching,
audit and diagnostics, so requested and effective locator may both be retained.

## Temporary signed URLs

Temporary signed URLs are a decisive reason not to make locator text stable
identity. Signature/query parameters may change while the underlying object is
the same logical resource.

## Local files

A pathname is also only a locator.

The same file may be reached through relative/absolute paths, symlinks, mounts
or a relocated workspace.

Local revision heuristics such as size, mtime or filesystem identity are
backend observations, not universal Resource IDs.

## Memory resources

Memory-backed sources should fit the same model.

A memory source may refer to immutable bytes, a mutable application buffer or a
retained blob object. Lifetime and mutability must be explicit.

A raw pointer is not a resource identity.

## Generated resources

Future imagery sources may be generated rather than read as encoded files.

Examples include procedural test imagery, a prior processing node or a
synthesized overview.

These still need identity, revision/provenance and declared capabilities.
Therefore the source model must not require every resource to behave like a
POSIX file.

## Failure separation

M2.1 should distinguish access failures from decode/materialization failures.

Provisional access-layer categories:

    unsupported locator/backend
    not found
    unauthorized
    forbidden
    temporarily unavailable
    timeout
    transport I/O failure
    capability unavailable
    resource changed during access
    integrity/revision mismatch
    cancelled

This is not yet a final error enum.

Decode failures such as malformed TIFF, corrupt JPEG, unsupported compression
or unsupported OpenEXR structure belong to the decoder/materialization layer.

## Retry semantics

Not every failure is retryable.

Potentially retryable:

- timeout;
- temporary server failure;
- connection reset;
- some rate limiting.

Usually not retryable without a state/configuration change:

- missing authentication;
- unsupported scheme;
- malformed data;
- unsupported codec.

The backend should report enough structure for scheduling policy to decide.
It should not hard-code application retry loops.

## Resource changed during read

A source can change while a multi-range decode is in progress.

This is a correctness problem.

Where a strong revision validator exists, one materialization should remain
bound to that revision or detect mismatch.

A decoder must not silently assemble one image from byte ranges belonging to
different revisions.

## Immutable publication rule

Once decoded raster data have been published through a retained
`RasterLease!T`, later discovery that the source changed must not mutate those
published bytes in place.

Instead:

    old lease -> remains valid for old decoded revision
    new request -> may materialize new revision

This aligns naturally with the M1/raster-d lease model.

## Source descriptor

A future immutable source/resource descriptor may conceptually contain:

    ResourceId
    ResourceLocator[]
    media/format hints
    expected revision/integrity information
    provenance references
    access hints

It does not contain an open file/network handle.

## Access policy

Mirror preference, network permission, credentials, retry counts, timeouts,
proxy settings and offline/cache-only mode are access policy.

They must not become intrinsic resource identity.

This allows the same product description to work in online, offline, test and
cache-only environments.

## Credentials

Credentials are operational secrets.

They must not participate directly in semantic resource identity or persistent
cache keys. Credential rotation should not create a new resource.

Credential-bearing URLs/headers must also be handled carefully in logs and
provenance.

## Resource roles

A resource may carry semantic roles similar to STAC, for example:

    data
    metadata
    overview
    thumbnail
    quality
    mask
    visual

Roles belong to imagery/product semantics. The access backend should not
interpret them.

## Resource-to-component binding

M1 allows one resource to expose multiple product components:

    Resource
        +-- Component A
        +-- Component B
        `-- Component C

The source layer opens the resource. Decoder/materializer logic identifies or
extracts selected components.

## Equivalent semantics, different resources

A product may expose semantically related imagery in different encodings or
resolutions, for example an analysis COG, visual JPEG and original JPEG2000.

These normally remain different Resource identities because their encoded
representations and access capabilities differ.

Higher product semantics may express derivation/equivalence.

## Pressure case P1 — Remote COG / HTTP range access

An HTTP-hosted Cloud Optimized GeoTIFF is the cleanest case for the original
Resource/Locator/Revision model.

The OGC COG standard explicitly depends on HTTP range access so a client can
retrieve only required TIFF structures/tiles rather than the complete object.

Conceptually:

    Source
        -> one COG Resource
            -> HTTPS Locator
            -> HTTP AccessBackend
            -> random-range ReadSession
            -> TIFF/GeoTIFF decoder

Result:

**PASS, with a strengthened consistency rule.**

A region materialization may need several byte-range requests from the same
remote Resource. Those ranges must belong to one representation revision.

HTTP provides relevant mechanisms:

- strong ETags can identify representation changes;
- `If-Match` can make a GET conditional on a strong ETag;
- `If-Range` can condition a range request on a strong validator.

M2 does not require the core model to expose HTTP headers directly, but it does
require the backend/session contract to be able to maintain or detect
representation consistency when the transport supports it.

New invariant:

> One materialization must not silently combine byte ranges from different
> revisions of the same Resource.

If revision consistency cannot be established, that limitation must be an
explicit capability/risk, not hidden by the decoder.

This also confirms that transport-level range caching belongs below image
semantics and will need explicit coordination with M2.3.

## Pressure case P2 — Local file changes while in use

Case:

1. a local image file is opened and decoded;
2. decoded pixels are published through a `RasterLease!T`;
3. another process replaces or modifies the file;
4. a later request accesses the same logical Source/Resource again.

OpenImageIO's ImageCache provides a useful precedent: invalidating an image can
force subsequent queries to reopen/reload it while already-held reference-
counted tile references remain valid until their holders release them.

Result:

**PASS.**

The M2/M1 model should behave analogously:

    old materialization
        -> retains old immutable decoded bytes through RasterLease

    resource revision changes
        -> invalidates future cache/access assumptions

    new materialization
        -> observes or establishes the new revision

A local pathname remains a Locator. It does not become the revision.

Size/mtime/filesystem identity can be backend observations used for weak or
backend-specific revision detection, but they are not universal semantic IDs.

New invariant:

> Source invalidation affects future materialization/cache decisions; it does
> not mutate already-published raster storage.

## Pressure case P3 — WMTS / OGC API Tiles

A tile service does not naturally fit the model:

    one Source == one persistent encoded Resource

OGC tile standards describe a tileset/tile matrix structure and URL templates
from which concrete tile URLs are produced. A tile is identified within the
tiling scheme by tile matrix, row and column; style, dimensions, format and
layer/tileset context may also participate in selecting the actual
representation.

WMTS also explicitly allows a server to generate a tile response on demand;
there need not be a corresponding server-side file tree.

Result:

**REQUIRES SOURCE/RESOURCE SPLIT.**

Conceptually:

    Tile Source
        identity:
            service / logical tileset or layer
            intrinsic style/dimensions where applicable
            tile-matrix-set semantics

        request:
            tile matrix
            row
            column
            dimensions
            requested representation format

        resolves to:
            concrete tile Resource / representation
            and its Locator

The URL template is therefore:

    locator recipe

not:

    SourceId
    ResourceId

A concrete tile may be represented as a Resource once request parameters have
selected it.

This prevents a product from needing to persist millions of tile Resource
descriptors up front.

It also prepares M2.3 for correct tile cache keys: a tile cache key must include
all semantically relevant request dimensions, not merely the expanded URL text.

## Pressure case P4 — Generated / non-file source

A generated imagery source may have no encoded byte object at all.

Examples:

- procedural test imagery;
- generated overview;
- synthetic background;
- future processing node;
- dynamically rendered source.

OpenImageIO explicitly exposes format capability discovery for procedural image
creation, and custom I/O systems demonstrate that decoding need not start from a
filesystem pathname.

Result:

**REQUIRES SOURCE ABOVE ACCESS BACKEND.**

Conceptually:

    Generated Source
        -> receives a materialization request
        -> produces raster data
        -> RasterLease!T

There may be no:

    Locator
    byte Resource
    AccessBackend
    ReadSession
    Decoder

for that path.

Therefore the byte-access stack is an important Source implementation family,
not a universal mandatory pipeline.

This is the decisive reason to retain `Source` as a separate semantic/execution
concept.

## Revised source families

M2.1 now distinguishes at least these conceptual families:

### Resource-backed Source

    Source
        -> Resource
        -> Locator
        -> AccessBackend
        -> ReadSession
        -> Decoder

Examples:

- local TIFF;
- remote COG;
- OpenEXR file;
- memory-backed encoded blob.

### Resource-family Source

    Source + request
        -> concrete Resource
        -> Locator
        -> AccessBackend
        -> decoder

Examples:

- WMTS;
- OGC API Tiles;
- XYZ/TMS-style tile services.

### Generated Source

    Source + request
        -> direct/generated materialization

Examples:

- procedural imagery;
- processing-derived source;
- synthetic test source.

These families should share source identity/provenance concepts without being
forced through one byte-I/O interface.

## Three identity axes

M2.1 should explicitly separate:

### Semantic identity

What logical product/resource/component is this?

### Representation revision

Which encoded state/version is this?

### Operational access

How and where are we reaching it now?

This is the central M2.1 finding.

## Candidate conceptual graph

    ImageryProduct
        |
        +-- ProductComponent
        |
        `-- SourceDescriptor
                |
                +-- SourceId
                +-- provenance / source semantics
                |
                +-----------------------------+
                |                             |
                v                             v
        Resource-backed                 Generated/direct
        source path                     source path
                |                             |
                v                             |
        ResourceDescriptor                    |
                |                             |
                +-- ResourceId                |
                +-- roles/media hints         |
                +-- Locator(s)                |
                `-- expected revision         |
                         |                    |
                         v                    |
                  AccessBackend               |
                         |                    |
                         v                    |
                    ReadSession               |
                         |                    |
                  observed revision           |
                         |                    |
                         v                    |
                       Decoder                |
                         |                    |
                         +----------+---------+
                                    |
                                    v
                           region materialization
                                    |
                                    v
                               RasterLease!T
                                    |
                                    v
                                ImageView!T

No box name is yet a frozen public D type.

## Candidate invariants

1. Source identity is distinct from Resource identity.
2. A Source may expose zero, one or many Resources.
3. Resource identity is not locator identity.
4. Resource identity is not cache identity.
5. Resource identity is not an open handle/session.
6. One Resource may have multiple locators.
7. A locator may fail while the Source/Resource remains semantically valid.
8. A Resource may have multiple revisions over time.
9. Revision strength is explicit; unknown is valid.
10. ETag is a representation validator, not universal content hash.
11. Last-Modified alone is not strong byte identity.
12. Technical access backend is distinct from producer/processor/host
    provenance.
13. Decoder is distinct from access backend.
14. Read session is ephemeral operational state.
15. Random-access capability is not assumed.
16. Multi-read materialization must not silently mix Resource revisions.
17. Published RasterLease data are not mutated by later source invalidation.
18. Credentials/retry policy are operational policy, not semantic identity.
19. Source architecture must work without filesystem paths.
20. Source architecture must work without HTTP URLs.
21. Source architecture must support request-addressed resource families such
    as tile services.
22. Source architecture must support generated sources with no encoded byte
    Resource.
23. URL templates are locator recipes, not stable source/resource identity.
24. M2.1 does not create a second raster ownership model.
25. M2.1 does not admit production API by itself.

## Rejected early alternatives

### `Source = string URI`

Reject. It conflates identity, access route, version and backend selection.

### `Source = open handle`

Reject. A handle is ephemeral state and unsuitable for persistent product
description.

### Technical `Provider` as the central name

Avoid for now. In geospatial metadata such as STAC, provider already commonly
means producer/processor/host organization.

Prefer a clearly operational term such as `AccessBackend` until naming is
settled.

### Decoder owns networking/filesystem

Reject. It prevents storage-independent codecs and duplicates patterns already
demonstrated by GDAL, OIIO and libvips.

### Cache owns source identity

Reject. Caches consume identity/revision information; they must not invent
semantic identity.

### Hash is the only ResourceId

Reject. Content identity is useful but does not encode semantic product
identity and is not always known before access.

## M2.6 terminology validation

The combined M2.6 reference and consumer matrix validates the provisional
terminology:

    Source
    Resource
    Locator
    Revision
    Access Backend
    Read Session

The distinction remains useful across:

- local files;
- remote COG;
- WMTS / tile-resource families;
- generated sources;
- cached access;
- heterogeneous product materialization.

`Provider` remains intentionally avoided as the technical access-layer name
because geospatial metadata systems such as STAC already use it for producer,
processor, licensor and host organizations.

The `Source` concept also survived the M2.6 check without needing to become a
general workflow-graph abstraction.

A Source identifies one imagery-producing capability and resolves
materialization needs; internal dependency scheduling remains an execution
concern outside Source identity.

## Open questions

### Q1 — ResourceId scope

Product-local, workspace-global, or optionally externally supplied?

M1 requires only stable product-local identity.

### Q2 — Multiple locators

Should one ResourceDescriptor own multiple locators directly, or should mirror
relations be separate?

### Q3 — Revision type

How should strong/weak/unknown validators be represented without embedding HTTP
semantics into core types?

### Q4 — Minimal read capability

What is the smallest access contract real decoders need without building a
general filesystem abstraction?

### Q5 — Async boundary

Should AccessBackend itself be asynchronous/cancellable, or should M2.4 wrap a
simpler access capability?

### Q6 — Source-side byte cache

Should backends expose byte ranges to common M2.3 cache infrastructure or own
transport caches internally?

### Q7 — Decoder discovery

Where does format probing live for custom, memory and generated resources?

## Provisional decision

The strongest current model is:

    SourceDescriptor
        = stable identity/provenance for one imagery-producing capability
        + rules/metadata needed to resolve materialization requests

    ResourceDescriptor
        = one concrete addressable representation/object when the Source is
          resource-backed
        + stable ResourceId
        + one or more access locators
        + media/format hints
        + optional revision/integrity expectations

    AccessBackend
        = operational mechanism that understands a locator form

    ReadSession
        = ephemeral access with explicit capabilities
        + observed revision information where available

    Decoder
        = interprets accessible encoded data
        + remains separate from transport

A Source may instead be generated/direct and bypass the
Resource/AccessBackend/Decoder path.

This preserves M1 while leaving caching, scheduling and exact region
materialization contracts to later M2 issues.

## Status

M2.1 architecture has now passed the M2.6 cross-reference and consumer
validation.

The validated pressure cases include:

- remote COG / HTTP range access;
- local-file revision/invalidation;
- WMTS / OGC API Tiles;
- generated/non-file sources;
- bounded and inefficient/full-decode materialization capability;
- cache and scheduler integration.

The Source/Resource split, terminology and capability/cost distinction are
therefore suitable for M2 synthesis.

M2.1 should remain open only until the focused M2 contract experiment and final
M2 ADR confirm that no implementation evidence contradicts these semantics.

No production Source API is admitted by this result.

## References

- OGC Cloud Optimized GeoTIFF Standard:
  https://www.ogc.org/standards/ogc-cloud-optimized-geotiff/

- OGC Two Dimensional Tile Matrix Set and OGC API - Tiles:
  https://www.ogc.org/standards/tms/
  https://www.ogc.org/standards/ogcapi-tiles/

- OGC Web Map Tile Service:
  https://www.ogc.org/standards/wmts/

- GDAL Virtual File Systems:
  https://gdal.org/en/stable/user/virtual_file_systems.html

- OpenImageIO documentation, custom I/O and ImageCache:
  https://openimageio.readthedocs.io/

- libvips current API and technical background:
  https://www.libvips.org/API/current/

- STAC Specification:
  https://github.com/radiantearth/stac-spec

- RFC 9110, HTTP Semantics:
  https://www.rfc-editor.org/rfc/rfc9110.html
