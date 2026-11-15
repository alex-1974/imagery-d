/++ Cross-block connectivity with caller-backed provisional label storage. +/
module imagery.analysis.feature_components;

import raster.region : Region2D;
import std.algorithm : min, max;
import std.math : isFinite, abs;

@safe:

struct ComponentSample
{
    enum State : ubyte { excluded, candidate, seed }
    State state;
    double[3] color = [0, 0, 0];
    double texture;
    double edge;
}

alias ComponentReader = void delegate(Region2D, scope ComponentSample[]) @safe;
alias LabelReader = void delegate(Region2D, scope uint[]) @safe;
alias LabelWriter = void delegate(Region2D, scope const(uint)[]) @safe;

struct ComponentStore
{
    LabelReader read;
    LabelWriter write;
}

struct ComponentPolicy
{
    bool requireSeed;
    bool diagonal;
    /// Use finite nonnegative color distance, or infinity for no color test.
    double colorDistance = double.infinity;
    /// Optional source-anchored cell size for grid-constrained superpixels.
    size_t cellEdge;
}

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
}

alias ComponentSink = void delegate(ComponentStatistics) @safe;
/// Contacts are emitted once per shared horizontal or vertical pixel side.
alias ContactSink = void delegate(uint, uint) @safe;

private struct Node
{
    uint parent;
    bool seeded;
    ComponentStatistics stats;
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
    return sample.state != ComponentSample.State.excluded &&
        isFinite(sample.color[0]) && isFinite(sample.color[1]) && isFinite(sample.color[2]);
}

private bool connected(ComponentSample a, ComponentSample b, const ComponentPolicy policy)
{
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

private void accumulate(ref ComponentStatistics stats, size_t x, size_t y,
    const ComponentSample sample)
{
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
        stats.meanColor[i] += (sample.color[i] - stats.meanColor[i]) / count;
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

size_t componentScratchBytes(uint labelLimit)
{
    if (labelLimit >= size_t.max / Node.sizeof)
        throw new Exception("Component budget is too large");
    return (cast(size_t)labelLimit + 1) * Node.sizeof +
        2 * 258 * ComponentSample.sizeof + (256 + 258) * uint.sizeof;
}

/// Read and label an analysis extent in scan order. Label zero is excluded.
/// The store must support reading exactly what was written. Its contents
/// become consumable only on successful return.
void labelComponents(Region2D extent, ComponentReader input, ComponentStore store,
    ComponentPolicy policy, uint labelLimit, size_t blockEdge,
    scope ComponentSink components = null, scope ContactSink contacts = null)
{
    if (extent.empty || extent.width > size_t.max - extent.x ||
        extent.height > size_t.max - extent.y || extent.width > ulong.max / 4 / extent.height ||
        input is null || store.read is null || store.write is null || !labelLimit ||
        blockEdge == 0 || blockEdge > 256 || !(policy.colorDistance >= 0))
        throw new Exception("Invalid connected-component request");
    componentScratchBytes(labelLimit);
    auto nodes = new Node[cast(size_t)labelLimit + 1];
    uint next;
    ComponentSample[258] current, previous;
    uint[258] above;
    uint[256] row;

    foreach (y; extent.y .. extent.y + extent.height)
    {
        uint leftLabel;
        ComponentSample leftSample;
        for (size_t x = extent.x; x < extent.x + extent.width;)
        {
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
                if (isFinite(policy.colorDistance))
                    input(top, previous[0 .. previousWidth]);
            }
            foreach (i, sample; current[0 .. width])
            {
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
                            throw new Exception("Connected-component label budget exhausted");
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
            const width = min(blockEdge, extent.x + extent.width - x);
            const window = Region2D(x, y, width, 1);
            store.read(window, row[0 .. width]);
            if (components !is null)
                input(window, current[0 .. width]);
            if (y != extent.y)
                store.read(Region2D(x, y - 1, width, 1), above[0 .. width]);
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
                    accumulate(*stats, x + i, y, current[i]);
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
            x += width;
        }
    }

    if (components !is null)
        foreach (ref node; nodes[1 .. cast(size_t)next + 1])
            if (node.stats.pixels)
                components(node.stats);
}

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
