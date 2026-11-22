module app;

import imagery.analysis.feature_components;
import imagery.analysis.feature_evidence : regionEvidence;
import imagery.analysis.feature_regions : Source, Sample;
import imagery.analysis.feature_segmentation : cannyComponents, imageComponents;
import raster.region : Region2D;
import core.memory : GC;
import core.time : MonoTime;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : isFinite;
import std.stdio : File, writeln;

// Test-only disk adapter. It validates the complete row before crossing File's
// @system I/O boundary; no borrowed array is retained by File.rawRead/rawWrite.
class DiskLabels
{
    File file;
    size_t width, height, originX, originY;
    this(string path, Region2D extent)
    {
        file = File(path, "w+b");
        width = extent.width; height = extent.height;
        originX = extent.x; originY = extent.y;
        auto zeros = new uint[width];
        foreach (y; 0 .. height) file.rawWrite(zeros);
    }
    size_t offset(Region2D row, size_t count) @safe
    {
        enforce(row.height == 1 && row.width == count && row.x >= originX &&
            row.y >= originY && row.y - originY < height && row.x - originX <= width &&
            count <= width - (row.x - originX));
        return (row.y - originY) * width + row.x - originX;
    }
    void read(Region2D row, scope uint[] values) @trusted
    {
        file.seek(cast(long)(offset(row, values.length) * uint.sizeof));
        enforce(file.rawRead(values).length == values.length);
    }
    void write(Region2D row, scope const(uint)[] values) @trusted
    {
        file.seek(cast(long)(offset(row, values.length) * uint.sizeof));
        file.rawWrite(values);
    }
}

JSONValue number(double value) { return isFinite(value) ? JSONValue(value) : JSONValue(null); }
JSONValue numbers(const(double)[] values)
{
    JSONValue[] array;
    foreach (value; values) array ~= number(value);
    return JSONValue(array);
}

JSONValue run(JSONValue request)
{
    const w = request["width"].integer.to!size_t;
    const h = request["height"].integer.to!size_t;
    const ox = request["origin_x"].integer.to!size_t;
    const oy = request["origin_y"].integer.to!size_t;
    enforce(w && h && w <= 4096 && h <= 4096);
    const extent = Region2D(ox, oy, w, h);
    const count = w * h;
    auto input = new ComponentSample[count];
    foreach (i, ref sample; input)
    {
        const entry = request["samples"].array[i];
        sample.state = cast(ComponentSample.State)entry[0].integer;
        sample.valid = entry[1].boolean;
        foreach (channel; 0 .. 3) sample.color[channel] = entry[channel+2].floating;
        sample.texture = entry[5].type == JSONType.null_ ? double.nan : entry[5].floating;
        sample.edge = entry[6].type == JSONType.null_ ? double.nan : entry[6].floating;
    }
    size_t reads, readPixels, maxWindow;
    ComponentReader reader = (Region2D row, scope ComponentSample[] values) @safe {
        enforce(row.height == 1 && row.x >= ox && row.y >= oy && row.y < oy+h &&
            row.x - ox + row.width <= w && row.width == values.length);
        ++reads; readPixels += values.length;
        if (values.length > maxWindow) maxWindow = values.length;
        const start = (row.y-oy)*w+row.x-ox;
        values[] = input[start .. start+values.length];
    };
    if ("adapter" in request.object)
    {
        enforce(ox == 0 && oy == 0);
        Source source;
        source.identity = "adapter-source"; source.revision = "1"; source.grid = "pixel-grid";
        source.width = w; source.height = h; source.band = "scalar"; source.unit = "1";
        source.read = (Region2D row, scope Sample[] values) @safe {
            foreach (i, ref sample; values)
            {
                const pixel = input[(row.y+i/row.width)*w+row.x+i%row.width];
                sample = Sample(pixel.color[0], [0,0,0], pixel.valid);
            }
        };
        reader = request["adapter"].str == "canny" ?
            cannyComponents(source,.04,.1) : imageComponents(source);
    }
    auto labels = new uint[count];
    auto validity = new bool[count];
    ComponentTransaction transaction;
    if (request["disk"].boolean)
    {
        auto disk = new DiskLabels(request["disk_path"].str, extent);
        transaction.store = ComponentStore(&disk.read, &disk.write);
    }
    else
    {
        transaction.store.read = (Region2D row, scope uint[] values) @safe {
            const start = (row.y-oy)*w+row.x-ox;
            enforce(start <= labels.length && values.length <= labels.length-start,
                "RAM store read outside extent: " ~ row.to!string ~ " / " ~ extent.to!string ~
                " start=" ~ start.to!string ~ " length=" ~ values.length.to!string);
            values[] = labels[start .. start+values.length];
        };
        transaction.store.write = (Region2D row, scope const(uint)[] values) @safe {
            const start = (row.y-oy)*w+row.x-ox;
            labels[start .. start+values.length] = values[];
        };
    }
    ComponentStatistics[] regions;
    uint[2][] contacts;
    LineSegment[] lines;
    transaction.components = (ComponentStatistics stats) @safe { regions ~= stats; };
    transaction.contacts = (uint a, uint b) @safe { contacts ~= [a,b]; };
    transaction.validity = (Region2D row, scope const(bool)[] values) @safe {
        const start = (row.y-oy)*w+row.x-ox;
        validity[start .. start+values.length] = values[];
    };
    uint commits, aborts;
    transaction.commit = () nothrow @safe { ++commits; };
    transaction.abort = () nothrow @safe { ++aborts; };
    ComponentPolicy policy;
    policy.requireSeed = request["seeded"].boolean;
    policy.diagonal = request["diagonal"].boolean;
    policy.cellEdge = request["cell"].integer.to!size_t;
    policy.colorDistance = request["distance"].type == JSONType.null_ ?
        double.infinity : request["distance"].floating;
    const limit = request["limit"].integer.to!uint;
    const block = request["block"].integer.to!size_t;
    const scratch = componentScratchBytes(limit);
    const before = GC.stats.allocatedInCurrentThread;
    const start = MonoTime.currTime;
    const result = tryLabelComponentsTransactional(extent, reader, transaction, policy,
        limit, block, scratch, ComponentProvenance("oracle-scene", "1", "pixel-grid", "RGB", "1"));
    const nanos = (MonoTime.currTime-start).total!"nsecs";
    const allocated = GC.stats.allocatedInCurrentThread-before;
    enforce(result.ok && commits == 1 && aborts == 0, result.error.to!string);
    if (request["disk"].boolean)
        foreach (y; 0 .. h)
            transaction.store.read(Region2D(ox,oy+y,w,1),labels[y*w .. (y+1)*w]);
    traceLabelLines(extent, transaction.store.read, 2,
        (LineSegment line) @safe { lines ~= line; });
    JSONValue output;
    output["labels"] = JSONValue(labels);
    output["validity"] = JSONValue(validity);
    output["elapsed_ns"] = JSONValue(nanos);
    output["gc_bytes"] = JSONValue(allocated);
    output["scratch_bytes"] = JSONValue(scratch);
    output["source_reads"] = JSONValue(reads);
    output["source_pixels"] = JSONValue(readPixels);
    output["max_source_window"] = JSONValue(maxWindow);
    JSONValue[] statsJson, contactJson, lineJson;
    foreach (stats; regions)
    {
        JSONValue item;
        item["id"] = JSONValue(stats.id);
        item["bounds"] = JSONValue([stats.bounds.x,stats.bounds.y,stats.bounds.width,stats.bounds.height]);
        item["pixels"] = JSONValue(stats.pixels);
        item["color"] = numbers(stats.meanColor[]);
        item["variance"] = numbers(stats.colorVariance[]);
        item["texture_count"] = JSONValue(stats.textureSamples);
        item["edge_count"] = JSONValue(stats.edgeSamples);
        item["texture"] = number(stats.meanTexture);
        item["edge"] = number(stats.meanEdge);
        item["perimeter"] = JSONValue(stats.perimeter);
        item["fill"] = number(stats.fillRatio);
        item["orientation"] = number(stats.orientation);
        item["oriented"] = JSONValue(stats.orientationValid);
        const evidence = regionEvidence(stats);
        item["evidence"] = numbers([evidence.compactness,evidence.edgeCoverage,evidence.textureCoverage]);
        enforce(stats.provenance.identity == "oracle-scene" && stats.provenance.revision == "1" &&
            stats.provenance.analysisExtent == extent && stats.provenance.policy == policy);
        statsJson ~= item;
    }
    foreach (contact; contacts) contactJson ~= JSONValue(contact[]);
    foreach (line; lines)
        lineJson ~= JSONValue([line.x0,line.y0,line.x1,line.y1,cast(size_t)line.component,line.pixels]);
    output["regions"] = JSONValue(statsJson);
    output["contacts"] = JSONValue(contactJson);
    output["lines"] = JSONValue(lineJson);
    // A viewport crops finalized global labels rather than relabeling a smaller
    // connectivity domain. Both RAM and disk stores support this same handoff.
    const crop = Region2D(ox+2, oy+3, 7, 5);
    auto cropLabels = new uint[crop.width*crop.height];
    auto cropValidity = new bool[cropLabels.length];
    foreach (y; 0 .. crop.height)
    {
        transaction.store.read(Region2D(crop.x,crop.y+y,crop.width,1),
            cropLabels[y*crop.width .. (y+1)*crop.width]);
        const cropStart = (crop.y+y-oy)*w+crop.x-ox;
        cropValidity[y*crop.width .. (y+1)*crop.width] = validity[cropStart .. cropStart+crop.width];
    }
    output["crop_labels"] = JSONValue(cropLabels);
    output["crop_validity"] = JSONValue(cropValidity);
    return output;
}

void main(string[] args)
{
    enforce(args.length == 2);
    auto requests = parseJSON(readText(args[1]));
    JSONValue[] output;
    foreach (request; requests.array) output ~= run(request);
    writeln(JSONValue(output).toString);
}
