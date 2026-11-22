/++
Cross-block connectivity with caller-backed provisional label storage.

Labels are canonical scan-order representatives for one fixed analysis extent,
source revision and policy. Changing blockEdge does not change them. Changing
the analysis extent can change connectivity and IDs; crop finalized labels when
a viewport needs the full-domain result. Source/store callbacks are synchronous
and must not retain scratch slices. No threads are created.
+/
module imagery.analysis.feature_components;

import raster.region : Region2D;
import std.algorithm : min, max;
import std.math : isFinite, abs, atan2, PI;

@safe:

/// One observation. Default is valid but excluded; missing edge/texture are NaN.
struct ComponentSample
{
    enum State : ubyte { excluded, candidate, seed }
    State state;
    double[3] color = [0, 0, 0];
    double texture;
    double edge;
    /// Optional categorical assignment (for connected superpixel cleanup).
    uint category;
    /// False for NoData. A valid sample can still be excluded by policy.
    bool valid = true;
}

/// Fill one requested source row, without retaining its scratch slice.
alias ComponentReader = void delegate(Region2D, scope ComponentSample[]) @safe;
/// Read one exact row of the caller's label staging store.
alias LabelReader = void delegate(Region2D, scope uint[]) @safe;
/// Stage finite-observation validity, independent of excluded/seed-filtered labels.
alias ValidityWriter = void delegate(Region2D, scope const(bool)[]) @safe;
/// Copy one row into caller storage before returning; the slice is borrowed.
alias LabelWriter = void delegate(Region2D, scope const(uint)[]) @safe;

/// Caller-owned staging store, in RAM or on disk. Read must reproduce writes.
struct ComponentStore
{
    /// Read previously written labels.
    LabelReader read;
    /// Stage provisional/final labels.
    LabelWriter write;
}

/// Explicit connectivity, seed and single-link color policy. Default is 4-connected.
struct ComponentPolicy
{
    /// Retain a connected region only if any member is a seed.
    bool requireSeed;
    /// False is 4-connected; true is 8-connected.
    bool diagonal;
    /// Use finite nonnegative color distance, or infinity for no color test.
    double colorDistance = double.infinity;
    /// Optional source-anchored cell size for grid-constrained superpixels.
    size_t cellEdge;
    /// Join only equal category values, independently of color-distance tests.
    bool matchCategory;
}

/// Caller source identity plus the exact analysis domain and algorithm policy.
struct ComponentProvenance
{
    string identity, revision, grid, band, unit;
    size_t level;
    Region2D analysisExtent;
    ComponentPolicy policy;
    uint implementationVersion;
}

/// Final region measurements. Default id=0/pixels=0 is not a region.
/// Only accepted, finite-color pixels count; excluded valid pixels remain separate.
/// Variances are population variances. Texture/edge have independent finite counts.
struct ComponentStatistics
{
    uint id;
    Region2D bounds;
    ulong pixels;
    double[3] meanColor = [0, 0, 0];
    ulong textureSamples, edgeSamples;
    double meanTexture, meanEdge;
    /// Four-neighbor perimeter, including the analysis boundary.
    ulong perimeter;
    double[3] colorVariance = [0, 0, 0];
    double fillRatio = 0;
    double orientation = 0;
    /// Resolved principal spatial axis: covariance anisotropy must exceed
    /// 64 * double.epsilon * trace(covariance); otherwise orientation is zero.
    bool orientationValid;
    ComponentProvenance provenance;
}

alias ComponentSink = void delegate(ComponentStatistics) @safe;
/// Contacts are emitted once per shared horizontal or vertical pixel side.
alias ContactSink = void delegate(uint, uint) @safe;

private struct Node
{
    uint parent;
    bool seeded;
    ComponentStatistics stats;
    double meanX = 0, meanY = 0;
    double xx = 0, yy = 0, xy = 0;
}

private uint root(scope Node[] nodes, uint id)
{
    while (nodes[id].parent != id)
    {
        nodes[id].parent = nodes[nodes[id].parent].parent;
        id = nodes[id].parent;
    }
    return id;
}

private uint join(scope Node[] nodes, uint a, uint b)
{
    if (a == 0)
        return root(nodes, b);
    a = root(nodes, a);
    b = root(nodes, b);
    const first = min(a, b), second = max(a, b);
    nodes[first].seeded |= nodes[second].seeded;
    nodes[second].parent = first;
    return first;
}

private bool accepted(ComponentSample sample)
{
    return sample.state != ComponentSample.State.excluded && observed(sample);
}

private bool observed(ComponentSample sample)
{
    return sample.valid && isFinite(sample.color[0]) && isFinite(sample.color[1]) && isFinite(sample.color[2]);
}

private bool connected(ComponentSample a, ComponentSample b, const ComponentPolicy policy)
{
    if (policy.matchCategory && a.category != b.category) return false;
    if (!isFinite(policy.colorDistance))
        return true;
    double distance = 0;
    foreach (i; 0 .. 3)
    {
        const delta = (a.color[i] - b.color[i]);
        if (abs(delta) > policy.colorDistance)
            return false;
        if (policy.colorDistance > 0)
            distance += (delta / policy.colorDistance) ^^ 2;
    }
    return distance <= 1;
}

private bool sameCell(size_t x, size_t y, size_t nx, size_t ny, size_t edge)
{
    return edge == 0 || (x / edge == nx / edge && y / edge == ny / edge);
}

private void accumulate(ref Node node, size_t x, size_t y, Region2D extent,
    const ComponentSample sample)
{
    auto stats = &node.stats;
    if (stats.pixels == 0)
        stats.bounds = Region2D(x, y, 1, 1);
    else
    {
        const bx = max(stats.bounds.x + stats.bounds.width - 1, x);
        const by = max(stats.bounds.y + stats.bounds.height - 1, y);
        stats.bounds.x = min(stats.bounds.x, x);
        stats.bounds.y = min(stats.bounds.y, y);
        stats.bounds.width = bx - stats.bounds.x + 1;
        stats.bounds.height = by - stats.bounds.y + 1;
    }
    const count = ++stats.pixels;
    foreach (i; 0 .. 3)
    {
        const delta = sample.color[i] - stats.meanColor[i];
        stats.meanColor[i] += delta / count;
        stats.colorVariance[i] += delta * (sample.color[i] - stats.meanColor[i]);
    }
    const px = cast(double)(x - extent.x), py = cast(double)(y - extent.y);
    const dx = px - node.meanX, dy = py - node.meanY;
    node.meanX += dx / count;
    node.meanY += dy / count;
    node.xx += dx * (px - node.meanX);
    node.yy += dy * (py - node.meanY);
    node.xy += dx * (py - node.meanY);
    if (isFinite(sample.texture))
    {
        ++stats.textureSamples;
        if (stats.textureSamples == 1)
            stats.meanTexture = sample.texture;
        else
            stats.meanTexture += (sample.texture - stats.meanTexture) / stats.textureSamples;
    }
    if (isFinite(sample.edge))
    {
        ++stats.edgeSamples;
        if (stats.edgeSamples == 1)
            stats.meanEdge = sample.edge;
        else
            stats.meanEdge += (sample.edge - stats.meanEdge) / stats.edgeSamples;
    }
}

/// Structured operational failures; notAttempted is the default sentinel.
enum ComponentError : ubyte
{
    notAttempted, none, invalidRequest, scratchBudgetExceeded,
    labelLimitExceeded, invalidStoreLabel, invalidSample, numericalOverflow,
    cancelled, callbackFailure
}

/// Exception form used by labelComponents; callback exceptions propagate unchanged.
class ComponentFailure : Exception
{
    /// Failure classification, never inferred from diagnostic text.
    ComponentError reason;
    /// Construct an operational failure with its diagnostic.
    this(ComponentError reason, string message) { super(message); this.reason = reason; }
}

/// Transactional result; .init.ok is false. Errors never authorize publication.
struct ComponentResult
{
    /// Explicit success/error channel.
    ComponentError error;
    /// True only after the caller's commit completed.
    bool ok() const { return error == ComponentError.none; }
}

/// Staging sinks plus atomic publication. All writes/records/contacts/validity
/// must remain private until commit. abort discards staging and preserves the
/// prior published store and its aliases. Both callbacks must be nonthrowing;
/// allocation, I/O and validation belong in staging callbacks, before commit.
/// The caller owns these resources and their semantic atomicity.
struct ComponentTransaction
{
    /// Provisional and final labels; never the currently published backing.
    ComponentStore store;
    /// Optional staged region records.
    ComponentSink components;
    /// Optional staged side contacts (not an aggregated graph).
    ContactSink contacts;
    /// Optional staged observation validity, separate from label zero.
    ValidityWriter validity;
    /// Publish the complete staged result atomically.
    void delegate() nothrow @safe commit;
    /// Discard staged changes on operational failures, exceptions or Errors.
    void delegate() nothrow @safe abort;
}

/// Conservative live engine payload: one provisional-node allocation plus fixed
/// row scratch. Excludes GC headers, runtime stack, providers and caller storage.
/// labelLimit limits provisional labels, not the final merged region count.
size_t componentScratchBytes(uint labelLimit)
{
    enum fixedBytes = 2 * 258 * ComponentSample.sizeof +
        (256 + 258) * uint.sizeof + 256 * bool.sizeof;
    if (cast(ulong)labelLimit + 1 > (size_t.max - fixedBytes) / Node.sizeof)
        throw new ComponentFailure(ComponentError.scratchBudgetExceeded, "Component budget is too large");
    return (cast(size_t)labelLimit + 1) * Node.sizeof +
        fixedBytes;
}

/// Read and label an analysis extent in scan order. Label zero is excluded.
/// The store must support reading exactly what was written. Its contents
/// and every optional sink become consumable only on successful return. On
/// failure they may contain partial writes; use tryLabelComponentsTransactional
/// to enforce a staging/commit boundary. The source must be stable across reads.
///
/// Complexity is O(pixels * union-find traversal + labelLimit), with two raster
/// passes and optional rereads of the preceding row for a finite color policy.
/// IDs are the smallest provisional scan-order label in each merged component,
/// including gaps, independent of blockEdge. Seed filtering is component-wide.
/// Color distance is Euclidean single-link, not distance to a growing mean.
/// cellEdge anchors cells at source (0,0); it does not implement SLIC.
///
/// maxScratchBytes bounds the payload reported by componentScratchBytes before
/// allocation. Cancellation is polled before work, each block and final return.
/// Numerical overflow of requested statistics fails rather than publishing NaNs.
void labelComponents(Region2D extent, ComponentReader input, ComponentStore store,
    ComponentPolicy policy, uint labelLimit, size_t blockEdge,
    scope ComponentSink components = null, scope ContactSink contacts = null,
    scope ValidityWriter validity = null, ComponentProvenance provenance = ComponentProvenance.init,
    size_t maxScratchBytes = size_t.max, scope bool delegate() @safe cancelled = null)
{
    if (extent.empty || extent.width > size_t.max - extent.x ||
        extent.height > size_t.max - extent.y || extent.width > ulong.max / 4 / extent.height ||
        input is null || store.read is null || store.write is null || !labelLimit ||
        blockEdge == 0 || blockEdge > 256 || !(policy.colorDistance >= 0))
        throw new ComponentFailure(ComponentError.invalidRequest, "Invalid connected-component request");
    if (componentScratchBytes(labelLimit) > maxScratchBytes)
        throw new ComponentFailure(ComponentError.scratchBudgetExceeded, "Component scratch budget exhausted");
    void poll()
    {
        if (cancelled !is null && cancelled())
            throw new ComponentFailure(ComponentError.cancelled, "Component request cancelled");
    }
    void validateLabels(scope const(uint)[] labels, uint allocated)
    {
        foreach (label; labels)
            if (label > allocated)
                throw new ComponentFailure(ComponentError.invalidStoreLabel, "Invalid label returned by store");
    }
    poll();
    auto nodes = new Node[cast(size_t)labelLimit + 1];
    uint next;
    ComponentSample[258] current, previous;
    uint[258] above;
    uint[256] row;
    bool[256] validRow;

    foreach (y; extent.y .. extent.y + extent.height)
    {
        uint leftLabel;
        ComponentSample leftSample;
        for (size_t x = extent.x; x < extent.x + extent.width;)
        {
            poll();
            const width = min(blockEdge, extent.x + extent.width - x);
            const window = Region2D(x, y, width, 1);
            input(window, current[0 .. width]);
            const left = cast(size_t)(x > extent.x && policy.diagonal);
            const right = cast(size_t)(x + width < extent.x + extent.width && policy.diagonal);
            const previousWidth = width + left + right;
            if (y != extent.y)
            {
                const top = Region2D(x - left, y - 1, previousWidth, 1);
                store.read(top, above[0 .. previousWidth]);
                validateLabels(above[0 .. previousWidth], next);
                if (isFinite(policy.colorDistance) || policy.matchCategory)
                    input(top, previous[0 .. previousWidth]);
            }
            foreach (i, sample; current[0 .. width])
            {
                if (sample.state > ComponentSample.State.seed)
                    throw new ComponentFailure(ComponentError.invalidSample, "Invalid component state");
                uint label;
                if (accepted(sample))
                {
                    const px = x + i;
                    if (leftLabel && sameCell(px, y, px - 1, y, policy.cellEdge) &&
                        connected(sample, leftSample, policy))
                        label = root(nodes, leftLabel);
                    if (y != extent.y)
                    {
                        const middle = cast(int)(i + left);
                        const radius = cast(int)policy.diagonal;
                        foreach (j; max(0, middle - radius) .. min(cast(int)previousWidth, middle + radius + 1))
                            if (above[j] && sameCell(px, y, x - left + j, y - 1, policy.cellEdge) &&
                                connected(sample, previous[j], policy))
                                label = join(nodes, label, above[j]);
                    }
                    if (!label)
                    {
                        if (next == labelLimit)
                            throw new ComponentFailure(ComponentError.labelLimitExceeded, "Connected-component label budget exhausted");
                        label = ++next;
                        nodes[label].parent = label;
                    }
                    nodes[label].seeded |= sample.state == ComponentSample.State.seed;
                }
                row[i] = leftLabel = label;
                leftSample = sample;
            }
            store.write(window, row[0 .. width]);
            x += width;
        }
    }

    foreach (y; extent.y .. extent.y + extent.height)
    {
        uint leftLabel;
        for (size_t x = extent.x; x < extent.x + extent.width;)
        {
            poll();
            const width = min(blockEdge, extent.x + extent.width - x);
            const window = Region2D(x, y, width, 1);
            store.read(window, row[0 .. width]);
            validateLabels(row[0 .. width], next);
            if (components !is null || validity !is null)
                input(window, current[0 .. width]);
            if (y != extent.y)
            {
                store.read(Region2D(x, y - 1, width, 1), above[0 .. width]);
                validateLabels(above[0 .. width], next);
            }
            foreach (i, ref label; row[0 .. width])
            {
                if (label)
                {
                    label = root(nodes, label);
                    if (policy.requireSeed && !nodes[label].seeded)
                        label = 0;
                }
                if (label && components !is null)
                {
                    auto stats = &nodes[label].stats;
                    stats.id = label;
                    accumulate(nodes[label], x + i, y, extent, current[i]);
                    stats.perimeter += 4;
                }
                foreach (neighbor; [leftLabel, y == extent.y ? 0u : above[i]])
                {
                    if (!label || !neighbor)
                        continue;
                    if (neighbor == label)
                    {
                        if (components !is null)
                            nodes[label].stats.perimeter -= 2;
                    }
                    else if (contacts !is null)
                        contacts(min(label, neighbor), max(label, neighbor));
                }
                leftLabel = label;
            }
            store.write(window, row[0 .. width]);
            if (validity !is null)
            {
                foreach (i; 0 .. width)
                    validRow[i] = observed(current[i]);
                validity(window, validRow[0 .. width]);
            }
            x += width;
        }
    }

    if (components !is null)
    {
        provenance.analysisExtent = extent;
        provenance.policy = policy;
        provenance.implementationVersion = 2;
        foreach (ref node; nodes[1 .. cast(size_t)next + 1])
        {
            auto stats = &node.stats;
            if (!stats.pixels)
                continue;
            foreach (i, ref variance; stats.colorVariance)
            {
                if (!isFinite(variance) || !isFinite(stats.meanColor[i]))
                    throw new ComponentFailure(ComponentError.numericalOverflow, "Component color statistics overflow");
                variance = max(0.0, variance / stats.pixels);
            }
            if ((stats.textureSamples && !isFinite(stats.meanTexture)) ||
                (stats.edgeSamples && !isFinite(stats.meanEdge)))
                throw new ComponentFailure(ComponentError.numericalOverflow, "Component auxiliary statistics overflow");
            stats.fillRatio = stats.pixels / (cast(double)stats.bounds.width * stats.bounds.height);
            const delta = node.xx - node.yy;
            // A symmetric footprint has no resolved principal axis. Do not let
            // roundoff of online covariance invent an orientation for a square.
            if (max(abs(delta), abs(2 * node.xy)) >
                64 * double.epsilon * (node.xx + node.yy))
            {
                const angle = 0.5 * atan2(2 * node.xy, delta);
                stats.orientation = angle < 0 ? angle + PI : angle;
                stats.orientationValid = true;
            }
            stats.provenance = provenance;
            components(*stats);
        }
    }
    poll();
}

/// Label through private caller/disk staging. Commit runs exactly once on
/// success; abort runs exactly once on every other exit after valid transaction
/// callbacks have been supplied, including D Errors (which are rethrown).
/// Exceptions from readers/writers/sinks become callbackFailure; operational
/// ComponentFailure retains its reason. Invalid commit/abort returns invalidRequest
/// without calling either callback. No additional pixel storage is allocated here.
/// No @nogc or nothrow promise: allocation Errors still propagate.
ComponentResult tryLabelComponentsTransactional(Region2D extent, ComponentReader input,
    ComponentTransaction transaction, ComponentPolicy policy, uint labelLimit,
    size_t blockEdge, size_t maxScratchBytes,
    ComponentProvenance provenance = ComponentProvenance.init,
    scope bool delegate() @safe cancelled = null)
{
    if (transaction.commit is null || transaction.abort is null)
        return ComponentResult(ComponentError.invalidRequest);
    bool committed;
    scope(exit) if (!committed) transaction.abort();
    try
    {
        labelComponents(extent, input, transaction.store, policy, labelLimit, blockEdge,
            transaction.components, transaction.contacts, transaction.validity, provenance,
            maxScratchBytes, cancelled);
    }
    catch (ComponentFailure failure)
        return ComponentResult(failure.reason == ComponentError.none ||
            failure.reason == ComponentError.notAttempted ?
            ComponentError.callbackFailure : failure.reason);
    catch (Exception failure)
        return ComponentResult(ComponentError.callbackFailure);
    transaction.commit();
    committed = true;
    return ComponentResult(ComponentError.none);
}

/// Private staging publishes only a complete seeded region.
@safe unittest
{
    auto staging = new uint[6];
    uint[] published = [99u];
    auto retained = published;
    ComponentReader reader = (Region2D row, scope ComponentSample[] samples) {
        foreach (i, ref sample; samples)
        {
            sample = ComponentSample.init;
            sample.state = row.x + i == 0 ? ComponentSample.State.seed :
                ComponentSample.State.candidate;
        }
    };
    ComponentTransaction transaction;
    transaction.store.read = (Region2D row, scope uint[] labels) {
        const start = row.y * 3 + row.x;
        labels[] = staging[start .. start + labels.length];
    };
    transaction.store.write = (Region2D row, scope const(uint)[] labels) {
        const start = row.y * 3 + row.x;
        staging[start .. start + labels.length] = labels[];
    };
    uint commits, aborts;
    transaction.commit = () nothrow { published = staging; ++commits; };
    transaction.abort = () nothrow { ++aborts; };
    const result = tryLabelComponentsTransactional(Region2D(0, 0, 3, 2), reader,
        transaction, ComponentPolicy(true), 4, 2, componentScratchBytes(4));
    assert(result.ok && commits == 1 && aborts == 0);
    assert(published == [1, 1, 1, 1, 1, 1] && retained == [99]);
}

@system unittest
{
    assert(!ComponentResult.init.ok);
    enum width = 3, height = 2;
    foreach (mode; 0 .. 13)
    {
        auto staging = new uint[width * height];
        uint[] published = [99u];
        const retained = published;
        uint commits, aborts, reads, writes, polls;
        auto input = (Region2D row, scope ComponentSample[] samples) {
            ++reads;
            if (mode == 0 && reads == 3) throw new Exception("reader failed");
            if (mode == 9 && reads == 3) throw new Error("provider Error");
            if (mode == 12) throw new ComponentFailure(ComponentError.none, "not a success");
            foreach (i, ref sample; samples)
            {
                sample = ComponentSample.init;
                sample.state = ComponentSample.State.candidate;
                if (mode == 5) sample.state = cast(ComponentSample.State)255;
                if (mode == 6) sample.color[0] = (row.x + i) % 2 ? -double.max : double.max;
            }
        };
        ComponentTransaction transaction;
        transaction.store.read = (Region2D row, scope uint[] labels) {
            if (mode == 3) throw new Exception("store read failed");
            const start = row.y * width + row.x;
            labels[] = staging[start .. start + labels.length];
            if (mode == 4) labels[] = uint.max;
        };
        transaction.store.write = (Region2D row, scope const(uint)[] labels) {
            if (mode == 1 && ++writes == 3) throw new Exception("store write failed");
            const start = row.y * width + row.x;
            staging[start .. start + labels.length] = labels[];
        };
        transaction.components = (ComponentStatistics stats) {
            if (mode == 2) throw new Exception("statistics sink failed");
        };
        transaction.validity = (Region2D row, scope const(bool)[] validity) {
            if (mode == 10) throw new Exception("validity sink failed");
        };
        transaction.contacts = (uint a, uint b) {
            if (mode == 11) throw new Exception("contact sink failed");
        };
        transaction.commit = () nothrow { published = staging; ++commits; };
        transaction.abort = () nothrow { ++aborts; };
        bool errored;
        ComponentResult result;
        try
            result = tryLabelComponentsTransactional(Region2D(0, 0, width, height), input,
                transaction, ComponentPolicy(false, false, double.infinity,
                    mode == 7 || mode == 11 ? 1 : 0), mode == 7 ? 1 : 8, 2,
                mode == 8 ? 0 : componentScratchBytes(8));
        catch (Error failure) { assert(mode == 9); errored = true; }
        assert((!result.ok || errored) && commits == 0 && aborts == 1);
        assert(published is retained && published == [99]);
        if (mode == 4) assert(result.error == ComponentError.invalidStoreLabel);
        if (mode == 5) assert(result.error == ComponentError.invalidSample);
        if (mode == 6) assert(result.error == ComponentError.numericalOverflow);
        if (mode == 7) assert(result.error == ComponentError.labelLimitExceeded);
        if (mode == 8) assert(result.error == ComponentError.scratchBudgetExceeded && reads == 0);
        if (mode != 9 && (mode < 4 || mode > 9)) assert(result.error == ComponentError.callbackFailure);

        // Poll after both passes and all sinks: publication must still roll back.
        if (mode == 8)
        {
            transaction.components = null;
            transaction.validity = null;
            const cancelled = tryLabelComponentsTransactional(Region2D(0, 0, width, height), input,
                transaction, ComponentPolicy.init, 8, 2, componentScratchBytes(8),
                ComponentProvenance.init, () { return ++polls == 10; });
            assert(cancelled.error == ComponentError.cancelled && commits == 0 && aborts == 2);
            assert(published is retained);
        }
    }
}

@safe unittest
{
    // No transaction callback may treat the default result or a callback's
    // fabricated "none" exception as permission to publish.
    ComponentTransaction transaction;
    uint commits, aborts;
    transaction.commit = () nothrow { ++commits; };
    transaction.abort = () nothrow { ++aborts; };
    auto result = tryLabelComponentsTransactional(Region2D.init, null, transaction,
        ComponentPolicy.init, 1, 1, 1024);
    assert(result.error == ComponentError.invalidRequest && commits == 0 && aborts == 1);
    result = tryLabelComponentsTransactional(Region2D.init, null, ComponentTransaction.init,
        ComponentPolicy.init, 1, 1, 1024);
    assert(result.error == ComponentError.invalidRequest && commits == 0 && aborts == 1);

    enum width = 7;
    uint[width*width] labels;
    ComponentStore store;
    store.read = (Region2D row, scope uint[] output) {
        const start = row.y*width+row.x;
        output[] = labels[start .. start+output.length];
    };
    store.write = (Region2D row, scope const(uint)[] input) {
        const start = row.y*width+row.x;
        labels[start .. start+input.length] = input[];
    };
    ComponentReader source = (Region2D row, scope ComponentSample[] output) {
        foreach (ref sample; output)
        {
            sample = ComponentSample.init;
            sample.state = ComponentSample.State.candidate;
        }
    };
    uint emitted;
    labelComponents(Region2D(0,0,width,width), source, store, ComponentPolicy.init, 1, 3,
        (ComponentStatistics stats) {
            ++emitted;
            assert(stats.pixels == 49 && stats.perimeter == 28 && !stats.orientationValid);
            assert(stats.orientation == 0 && stats.provenance.implementationVersion == 2);
        });
    assert(emitted == 1);
}

/// A maximal straight grid run in one finalized component, including endpoints.
struct LineSegment
{
    size_t x0, y0, x1, y1;
    uint component;
    size_t pixels;
}

alias LineSink = void delegate(LineSegment) @safe;

/// Emit maximal straight runs within one canonical label, in four directions.
/// Use labels from Canny or another line-candidate mask. Intersections can
/// contribute to more than one segment.
void traceLabelLines(Region2D extent, LabelReader read, size_t minimum, scope LineSink sink)
{
    if (extent.empty || extent.width > size_t.max - extent.x ||
        extent.height > size_t.max - extent.y || minimum < 2 || read is null || sink is null)
        throw new Exception("Invalid line tracing request");

    const endX = extent.x + extent.width;
    const endY = extent.y + extent.height;
    immutable int[2][4] steps = [[1, 0], [0, 1], [1, 1], [-1, 1]];
    void trace(size_t x, size_t y, int[2] step)
    {
        LineSegment segment;
        uint[1] label;
        while (x >= extent.x && x < endX && y < endY)
        {
            read(Region2D(x, y, 1, 1), label[]);
            if (label[0] != segment.component)
            {
                if (segment.pixels >= minimum)
                    sink(segment);
                segment = LineSegment(x, y, x, y, label[0], 0);
            }
            if (label[0])
            {
                segment.x1 = x;
                segment.y1 = y;
                ++segment.pixels;
            }
            if (step[0] < 0 && x == extent.x)
                break;
            x = step[0] < 0 ? x - 1 : x + step[0];
            y += step[1];
        }
        if (segment.pixels >= minimum)
            sink(segment);
    }
    foreach (step; steps)
    {
        if (step[1])
            foreach (x; extent.x .. endX)
                trace(x, extent.y, step);
        if (step[0])
            foreach (y; extent.y + cast(size_t)(step[1] != 0) .. endY)
                trace(step[0] < 0 ? endX - 1 : extent.x, y, step);
    }
}
