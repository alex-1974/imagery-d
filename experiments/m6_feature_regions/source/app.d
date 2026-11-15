module app;

import imagery.analysis.feature_regions;
import advanced_checks : checkAdvanced, benchmarkAdvanced;
import imagery.analysis.feature_overviews;
import imagery.analysis.feature_requests;
import raster.region : Region2D;
import std.algorithm : clamp;
import std.datetime.stopwatch : StopWatch;
import std.file : read;
import std.math : abs, atan2, cbrt, exp, pow, sqrt;
import std.stdio : writeln;

void check(bool condition, string description) @safe
{
    if (!condition)
        throw new Exception(description);
}

void verify()
{
    auto image = Source("synthetic", "1", "pixel grid", "temperature", "K",
        0, 13, 9, false);
    bool valid(size_t x, size_t y) { return x != 5 || y != 3; }
    double value(size_t x, size_t y) { return 273 + 2.0 * x + 3.0 * y; }
    image.read = (Region2D window, scope Sample[] buffer) {
        foreach (y; 0 .. window.height)
            foreach (x; 0 .. window.width)
            {
                auto cell = &buffer[y * window.width + x];
                cell.scalar = value(window.x + x, window.y + y);
                cell.valid = valid(window.x + x, window.y + y);
            }
    };

    Engine engine;
    foreach (feature; [Feature.localStatistics, Feature.gradient])
        foreach (edge; [3, 8, 256])
            engine.run(image, Region2D(1, 1, 12, 8), feature, edge,
                (Region2D tile, scope const(Value)[] values, Provenance origin) {
                    check(origin.identity == "synthetic" && origin.revision == "1" &&
                        origin.band == "temperature" && origin.unit == "K" &&
                        origin.grid == "pixel grid" && origin.level == 0 &&
                        origin.gridWidth == 13 && origin.gridHeight == 9 &&
                        origin.extent == tile && origin.feature == feature &&
                        origin.implementationVersion == 1, "Scalar tile provenance");
                    foreach (i, result; values)
                    {
                        const x = tile.x + i % tile.width;
                        const y = tile.y + i / tile.width;
                        size_t count;
                        double sum = 0, squares = 0, gx = 0, gy = 0;
                        const radius = feature == Feature.gradient ? 1 : 3;
                        foreach (dy; -radius .. radius + 1)
                            foreach (dx; -radius .. radius + 1)
                            {
                                const sx = cast(size_t)clamp(cast(int)x + dx, 0, 12);
                                const sy = cast(size_t)clamp(cast(int)y + dy, 0, 8);
                                if (!valid(sx, sy))
                                    continue;
                                const v = value(sx, sy);
                                ++count;
                                sum += v;
                                squares += v * v;
                                gx += dx * (dy ? 1 : 2) * v;
                                gy += dy * (dx ? 1 : 2) * v;
                            }
                        if (feature == Feature.localStatistics)
                        {
                            check(result.valid == (valid(x, y) && count >= 25), "Local mask");
                            if (result.valid)
                            {
                                const mean = sum / count;
                                check(abs(result.channels[0] - mean) < 1e-6, "Mean");
                                check(abs(result.channels[1] -
                                    sqrt(squares / count - mean * mean)) < 1e-6, "Contrast");
                            }
                        }
                        else
                        {
                            check(result.valid == (count == 9), "Gradient mask");
                            if (result.valid)
                            {
                                check(abs(result.channels[0] - sqrt(gx * gx + gy * gy) / 8) <
                                    1e-6, "Sobel strength");
                                check(result.orientationValid &&
                                    abs(result.channels[1] - atan2(gy, gx)) < 1e-5,
                                    "Sobel orientation");
                            }
                        }
                    }
                });

    // A large, procedural source can service a tiny request with the same
    // tile memory as a small source. Constant finite fields have no direction.
    auto constant = Source("constant", "1", "pixel grid", "intensity", "K",
        0, 17, 17, false);
    constant.read = (Region2D tile, scope Sample[] results) {
        check(tile.width <= 6 && tile.height <= 6, "Read exceeds tile plus halo");
        results[] = Sample(273.125, [0, 0, 0], true);
    };
    Engine bounded;
    size_t fixedBytes;
    foreach (extent; [17, 1_000_017])
    {
        constant.width = constant.height = extent;
        bounded.run(constant, Region2D(extent - 5, extent - 7, 5, 7),
            Feature.gradient, 4, (Region2D tile, scope const(Value)[] results, Provenance origin) {
                foreach (result; results)
                    check(result.valid && !result.orientationValid &&
                        result.channels[0] == 0, "Constant gradient");
            });
        if (fixedBytes == 0)
            fixedBytes = bounded.metrics.peakTileBytes;
        check(bounded.metrics.peakTileBytes == fixedBytes, "Fixed tile storage");
    }

    auto color = Source("colors", "1", "pixel grid", "RGB", "", 0, 3, 1, true);
    color.read = (Region2D window, scope Sample[] buffer) {
        foreach (i, ref sample; buffer)
        {
            const x = window.x + i;
            sample.rgb = x == 0 ? [0, 0, 0] : [255, 255, 255];
            sample.valid = x != 2;
        }
    };
    const histogram = distribution(color, Region2D(0, 0, 3, 1));
    check(histogram.origin.extent == Region2D(0, 0, 3, 1) &&
        histogram.origin.feature == Feature.distribution, "Histogram provenance");
    check(histogram.count == 2 && histogram.bins[0] == 1 &&
        histogram.bins[255] == 1 && histogram.percentile(50) == 0 &&
        histogram.percentile(51) == 255, "Masked histogram");
    check(abs(histogram.mean - 0.5) < 1e-12 &&
        abs(histogram.variance - 0.25) < 1e-12, "Global moments");
    engine.run(color, Region2D(1, 0, 2, 1), Feature.oklab, 2,
        (Region2D tile, scope const(Value)[] results, Provenance origin) {
            check(results[0].valid && !results[1].valid, "Color validity");
            check(abs(results[0].channels[0] - 1) < 1e-5 &&
                abs(results[0].channels[1]) < 1e-4 &&
                abs(results[0].channels[2]) < 1e-4, "OKLab white");
        });
    const profile = fitLuminance(color, Region2D(0, 0, 3, 1), 50, 100);
    check(profile.usable && profile.lowerBound == 0 && profile.upperBound == 1,
        "Fitted black and white bounds");
    foreach (edge; [1, 3])
    {
        size_t seen;
        normalizeLuminance(engine, color, Region2D(0, 0, 3, 1), profile, edge,
            (Region2D tile, scope const(Value)[] samples, Provenance origin) {
                check(origin.feature == Feature.normalizedLuminance &&
                    origin.normalization.analysisExtent == Region2D(0, 0, 3, 1) &&
                    origin.normalization.lowerPercentile == 50 &&
                    origin.normalization.upperPercentile == 100, "Normalization provenance");
                foreach (sample; samples)
                {
                    check(sample.valid == (seen != 2), "Normalization validity");
                    if (sample.valid)
                        check(abs(sample.channels[0] - seen) < 1e-12, "Normalized luminance");
                    ++seen;
                }
            });
        check(seen == 3, "Normalization coverage");
    }
    check(!fitLuminance(color, Region2D(0, 0, 1, 1), 1, 100).usable,
        "Constant histogram");
    check(!fitLuminance(color, Region2D(2, 0, 1, 1), 1, 100).usable,
        "Empty histogram");
    auto revised = color;
    revised.revision = "different";
    bool rejected;
    try
        normalizeLuminance(engine, revised, Region2D(0, 0, 3, 1), profile, 3,
            (Region2D tile, scope const(Value)[] samples, Provenance origin) {
                check(false, "Mismatched normalization emitted a tile");
            });
    catch (Exception error)
        rejected = true;
    check(rejected, "Mismatched normalization revision was accepted");

    const before = engine.hits;
    const beforeWarm = engine.metrics;
    engine.run(color, Region2D(1, 0, 2, 1), Feature.oklab, 2,
        (Region2D tile, scope const(Value)[] results, Provenance origin) {});
    check(engine.hits == before + 1, "Cache hit");
    check(engine.metrics.scratchAllocations == beforeWarm.scratchAllocations &&
        engine.metrics.cachePayloadAllocations == beforeWarm.cachePayloadAllocations,
        "Warm request allocated a work buffer or cache payload");
    color.revision = "2";
    engine.run(color, Region2D(1, 0, 2, 1), Feature.oklab, 2,
        (Region2D tile, scope const(Value)[] results, Provenance origin) {});
    check(engine.hits == before + 1, "Revision invalidation");

    auto interrupted = Source("interrupted", "1", "pixel grid", "RGB", "", 0, 3, 1, true);
    bool failRead = true;
    interrupted.read = (Region2D tile, scope Sample[] samples) {
        if (tile.x == 1 && failRead)
            throw new Exception("Fixture read failure");
        samples[] = Sample(0, [0, 0, 0], true);
    };
    size_t delivered;
    Sink countTiles = (Region2D tile, scope const(Value)[] values, Provenance origin) {
        ++delivered;
    };
    try
        engine.run(interrupted, Region2D(0, 0, 3, 1), Feature.oklab, 1, countTiles);
    catch (Exception error)
        check(error.msg == "Fixture read failure", "Unexpected failure");
    check(delivered == 1, "Failed tile was delivered");
    failRead = false;
    const beforeRetry = engine.hits;
    engine.run(interrupted, Region2D(0, 0, 3, 1), Feature.oklab, 1, countTiles);
    check(delivered == 4 && engine.hits == beforeRetry + 1, "Retry after source failure");

}

void verifyRadiometry()
{
    auto impulse = Source("impulse", "1", "pixels", "RGB", "", 0, 9, 9, true);
    impulse.read = (Region2D window, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const x = window.x + i % window.width;
            const y = window.y + i / window.width;
            sample.rgb = x == 4 && y == 4 ? [255, 255, 255] : [0, 0, 0];
            sample.valid = x != 0 || y != 0;
        }
    };
    Engine engine;
    const delta = exp(-50.0);
    const features = [
        Feature.box, Feature.gaussian, Feature.median, Feature.bilateral,
        Feature.laplacian, Feature.sharpness, Feature.noise, Feature.dynamicRange,
        Feature.localNormalization, Feature.clipping, Feature.underexposure, Feature.diffusion
    ];
    const expected = [1.0 / 9, 0.25, 0, 4 / (4 + 12 * delta), -4, 4, 0, 1,
        sqrt(48.0), 1, 0, 1 - 0.8 * exp(-100.0)];
    foreach (i, feature; features)
    {
        Value[81] reference;
        foreach (edge; [9, 2])
            engine.run(impulse, Region2D(0, 0, 9, 9), feature, edge,
                (Region2D tile, scope const(Value)[] results, Provenance origin) {
                    foreach (j, value; results)
                    {
                        const x = tile.x + j % tile.width;
                        const y = tile.y + j / tile.width;
                        const index = y * 9 + x;
                        if (edge == 9)
                            reference[index] = value;
                        else
                            check(value == reference[index], "Radiometry changed at tile boundary");
                        if (x == 4 && y == 4)
                            check(value.valid && abs(value.channels[0] - expected[i]) < 1e-12,
                                "Impulse reference");
                        if (x == 0 && y == 0)
                            check(!value.valid, "NoData in radiometry");
                        if (x == 8 && y == 8)
                            check(value.valid && value.channels[0] ==
                                (feature == Feature.underexposure ? 1 : 0), "Constant field");
                    }
                });
    }

    auto target = Source("reference", "1", "pixels", "RGB", "", 0, 2, 1, true);
    target.read = (Region2D window, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const shade = cast(ubyte)(window.x + i == 0 ? 80 : 160);
            sample = Sample(0, [shade, shade, shade], true);
        }
    };
    const base = fitLuminance(impulse, Region2D(3, 4, 2, 1), 50, 100);
    const matched = fitLuminance(target, Region2D(0, 0, 2, 1), 50, 100);
    matchExposure(engine, impulse, Region2D(3, 4, 2, 1), base, matched, 2,
        (Region2D tile, scope const(Value)[] values, Provenance origin) {
            check(values[0].channels[0] == matched.lowerBound &&
                values[1].channels[0] == matched.upperBound &&
                origin.feature == Feature.exposureMatched &&
                origin.exposureReference.sourceIdentity == "reference", "Exposure match");
        });

    auto cells = Source("clahe", "1", "pixels", "RGB", "", 0, 79, 67, true);
    cells.read = (Region2D window, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const x = window.x + i % window.width;
            const y = window.y + i / window.width;
            const shade = cast(ubyte)(x >= 64 ? 128 : (x + y) % 2 * 255);
            sample = Sample(0, [shade, shade, shade], !(x >= 32 && x < 64 && y >= 32));
        }
    };
    Value[79 * 67] whole;
    equalizeLuminanceLocally(engine, cells, Region2D(0, 0, 79, 67), 79,
        (Region2D tile, scope const(Value)[] values, Provenance origin) {
            whole[] = values[];
        });
    check(abs(whole[0].channels[0] - 11.0 / 1024) < 1e-12 &&
        whole[1].channels[0] == 1, "Hand-counted clipped histogram");
    check(abs(whole[62].channels[0] - (1 - 14.5 / 32) * 11.0 / 1024) < 1e-12,
        "Interpolation between equalized and constant cells");
    check(!whole[48 + 48 * 79].valid && whole[65 + 48 * 79].valid,
        "Missing and constant CLAHE cells");
    equalizeLuminanceLocally(engine, cells, Region2D(5, 3, 74, 64), 11,
        (Region2D tile, scope const(Value)[] values, Provenance origin) {
            foreach (i, value; values)
            {
                const x = tile.x + i % tile.width;
                const y = tile.y + i / tile.width;
                check(value == whole[y * 79 + x] && origin.feature == Feature.clahe,
                    "CLAHE output changed for a non-origin region");
            }
        });
}

void verifyInteractive()
{
    size_t reads;
    auto finest = Source("measurements", "1", "grid", "temperature", "K", 0, 5, 3, false);
    finest.read = (Region2D window, scope Sample[] samples) {
        ++reads;
        foreach (i, ref sample; samples)
        {
            const x = window.x + i % window.width;
            const y = window.y + i / window.width;
            sample = Sample(3.0*x + 8.0*y, [0, 0, 0], x != 4 || y != 2);
        }
    };
    auto reduced = resampleFeatureSource(finest, 3, 2, 1, FeatureResampling.bilinearScalar);
    auto nearest = resampleFeatureSource(finest, 3, 2, 1, FeatureResampling.nearest);
    const overview = selectFeatureOverview([finest, reduced], 3, 2);
    check(overview.source.level == 1 && overview.scaleX == 5.0 / 3 &&
        overview.scaleY == 1.5 && overview.avoidsUndersampling, "Overview resolution");
    const deficit = selectFeatureOverview([finest, reduced], 6, 2);
    check(deficit.source.level == 0 && !deficit.avoidsUndersampling, "Overview deficit");
    check(nearest.grid != reduced.grid, "Resampling policy identity");
    Sample[6] resampled;
    reduced.read(Region2D(0, 0, 3, 2), resampled[]);
    check(resampled[0].valid && abs(resampled[0].scalar - 3) < 1e-12 &&
        abs(resampled[1].scalar - 8) < 1e-12 && !resampled[5].valid,
        "Bilinear centre mapping and NoData");
    Sample[4] cropped;
    reduced.read(Region2D(1, 0, 2, 2), cropped[]);
    foreach (i, value; cropped)
    {
        const expected = resampled[1 + i % 2 + (i / 2) * 3];
        check(value.valid == expected.valid &&
            (!value.valid || value.scalar == expected.scalar), "Resampled region equivalence");
    }
    const descriptor = describeTileFeature(Feature.gradient);
    check(descriptor.usesScalar && descriptor.halo == 1 &&
        descriptor.implementationVersion == featureImplementationVersion, "Gradient descriptor");

    auto queue = new FeatureRequests;
    size_t successes, errors, cancelledCalls;
    size_t firstX = size_t.max;
    Sink deliver = (Region2D tile, scope const(Value)[] values, Provenance origin) {
        if (++successes == 1)
            firstX = tile.x;
    };
    RequestFailure failed = (Exception error) { ++errors; };
    Sink cancelled = (Region2D tile, scope const(Value)[] values, Provenance origin) {
        ++cancelledCalls;
    };
    const background = Region2D(0, 0, 1, 1);
    const visible = Region2D(1, 0, 1, 1);
    const bg = queue.submit(finest, background, Feature.luminance,
        RequestPriority.background, deliver, failed);
    const thumb = queue.submit(finest, visible, Feature.luminance,
        RequestPriority.background, cancelled, failed);
    const foreground = queue.submit(finest, visible, Feature.luminance,
        RequestPriority.visible, deliver, failed);
    const second = queue.submit(finest, visible, Feature.luminance,
        RequestPriority.visible, deliver, failed);
    check(bg && thumb && foreground && second && queue.cancel(thumb) && !queue.cancel(thumb),
        "Subscriber cancellation");
    const before = reads;
    check(queue.pump() && firstX == visible.x && successes == 2 &&
        queue.executed == 1 && reads == before + 1, "Visible single-flight");
    check(queue.pump() && !queue.pump() && successes == 3 &&
        queue.executed == 2 && cancelledCalls == 0 && errors == 0, "Queue completion");

    auto transient = finest;
    transient.revision = "2";
    auto original = finest.read;
    ulong activeToken;
    size_t lateDeliveries;
    transient.read = (Region2D tile, scope Sample[] samples) {
        check(queue.cancel(activeToken), "In-flight cancellation");
        const late = queue.submit(transient, tile, Feature.luminance,
            RequestPriority.visible,
            (Region2D r, scope const(Value)[] output, Provenance origin) {
                ++lateDeliveries;
            }, failed);
        check(late != 0, "Joining active job");
        original(tile, samples);
    };
    activeToken = queue.submit(transient, visible, Feature.luminance,
        RequestPriority.visible, cancelled, failed);
    const beforeActive = reads;
    check(activeToken && queue.pump() && lateDeliveries == 1 &&
        reads == beforeActive + 1 && cancelledCalls == 0, "In-flight sharing");

    auto broken = finest;
    broken.revision = "3";
    broken.read = (Region2D tile, scope Sample[] samples) { throw new Exception("Read failed"); };
    check(queue.submit(broken, visible, Feature.luminance, RequestPriority.visible,
        deliver, failed) && queue.pump() && errors == 1 && successes == 3, "Failure publication");
    broken.read = finest.read;
    check(queue.submit(broken, visible, Feature.luminance, RequestPriority.visible,
        deliver, failed) && queue.pump() && errors == 1 && successes == 4, "Retry after failure");

    ulong[128] tokens;
    foreach (ref token; tokens)
        token = queue.submit(finest, visible, Feature.luminance,
            RequestPriority.background, cancelled, failed);
    check(tokens[$-1] && queue.submit(finest, visible, Feature.luminance,
        RequestPriority.visible, cancelled, failed) == 0, "Subscriber backpressure");
    foreach (token; tokens)
        check(queue.cancel(token), "Release queued subscriber");
    check(!queue.pump(), "Unobserved queued work was dropped");
}

void verifyPhoto(string path)
{
    enum width = 64, height = 48, stride = width * 3 + 17;
    const raw = cast(const(ubyte)[])read(path);
    check(raw.length == width * height * 3, "Expected 64×48 RGB8 photograph");
    auto padded = new ubyte[stride * height];
    padded[] = 0xCC;
    foreach (y; 0 .. height)
        padded[y * stride .. y * stride + width * 3] =
            raw[y * width * 3 .. (y + 1) * width * 3];

    auto photo = Source(path, "1", "pixels", "RGB", "", 0, width, height, true);
    photo.read = (Region2D window, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const offset = (window.y + i / window.width) * stride +
                (window.x + i % window.width) * 3;
            sample.rgb[] = padded[offset .. offset + 3];
            sample.valid = true;
        }
    };

    double decode(ubyte encoded)
    {
        const double v = encoded / 255.0;
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    }
    double[3] rgb(size_t x, size_t y)
    {
        const offset = (y * width + x) * 3;
        return [decode(raw[offset]), decode(raw[offset + 1]), decode(raw[offset + 2])];
    }

    Engine engine;
    const region = Region2D(5, 7, 59, 41);
    // Use the direct linear RGB matrix as an independent reference for the
    // production library's RGB → XYZ → OKLab path.
    foreach (edge; [7, 256])
    {
        engine.run(photo, region, Feature.oklab, edge,
            (Region2D tile, scope const(Value)[] results, Provenance origin) {
                foreach (i, result; results)
                {
                    const c = rgb(tile.x + i % tile.width, tile.y + i / tile.width);
                    const l = cbrt(0.4122214708*c[0] + 0.5363325363*c[1] + 0.0514459929*c[2]);
                    const m = cbrt(0.2119034982*c[0] + 0.6806995451*c[1] + 0.1073969566*c[2]);
                    const s = cbrt(0.0883024619*c[0] + 0.2817188376*c[1] + 0.6299787005*c[2]);
                    check(result.valid && abs(result.channels[0] -
                        (0.2104542553*l + 0.7936177850*m - 0.0040720468*s)) < 1e-6 &&
                        abs(result.channels[1] -
                        (1.9779984951*l - 2.4285922050*m + 0.4505937099*s)) < 1e-6 &&
                        abs(result.channels[2] -
                        (0.0259040371*l + 0.7827717662*m - 0.8086757660*s)) < 1e-6,
                        "Photograph OKLab reference");
                }
            });
        engine.run(photo, region, Feature.localStatistics, edge,
            (Region2D tile, scope const(Value)[] results, Provenance origin) {
                foreach (i, result; results)
                {
                    const x = cast(int)(tile.x + i % tile.width);
                    const y = cast(int)(tile.y + i / tile.width);
                    double sum = 0, squares = 0;
                    foreach (dy; -3 .. 4)
                        foreach (dx; -3 .. 4)
                        {
                            const c = rgb(clamp(x + dx, 0, width - 1),
                                clamp(y + dy, 0, height - 1));
                            const v = 0.2126*c[0] + 0.7152*c[1] + 0.0722*c[2];
                            sum += v;
                            squares += v*v;
                        }
                    const mean = sum / 49;
                    check(result.valid && abs(result.channels[0] - mean) < 1e-6 &&
                        abs(result.channels[1] - sqrt(squares / 49 - mean*mean)) < 1e-6,
                        "Photograph contrast reference");
                }
            });
    }
    const profile = fitLuminance(photo, Region2D(0, 0, width, height), 5, 95);
    check(profile.usable && profile.lowerBound > 0 && profile.upperBound < 1,
        "Photograph percentile interval");
    size_t clippedLow, clippedHigh;
    normalizeLuminance(engine, photo, Region2D(0, 0, width, height), profile, 7,
        (Region2D tile, scope const(Value)[] results, Provenance origin) {
            foreach (i, result; results)
            {
                const c = rgb(tile.x + i % tile.width, tile.y + i / tile.width);
                const base = 0.2126*c[0] + 0.7152*c[1] + 0.0722*c[2];
                const expected = clamp((base - profile.lowerBound) /
                    (profile.upperBound - profile.lowerBound), 0.0, 1.0);
                check(result.valid && abs(result.channels[0] - expected) < 1e-12,
                    "Photograph normalization reference");
                clippedLow += expected == 0;
                clippedHigh += expected == 1;
            }
        });
    check(clippedLow > 0 && clippedHigh > 0, "Photograph clipping coverage");
    writeln("Strided photograph checks passed");
}

void benchmark(string path)
{
    const raw = cast(const(ubyte)[])read(path);
    check(raw.length == 2048 * 1024 * 3, "Expected 2048×1024 RGB8 bytes");
    auto image = Source(path, "1", "pixels", "RGB", "", 0, 2048, 1024, true);
    image.read = (Region2D window, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const index = 3 * ((window.y + i / window.width) * image.width +
                window.x + i % window.width);
            sample.rgb[] = raw[index .. index + 3];
            sample.valid = true;
        }
    };
    Engine engine;
    double checksum = 0;
    void consume(Region2D tile, scope const(Value)[] results, Provenance origin) @safe
    {
        foreach (result; results)
            if (result.valid)
                checksum += result.channels[0];
    }
    StopWatch watch;
    watch.start();
    const global = distribution(image, Region2D(0, 0, image.width, image.height));
    watch.stop();
    writeln("Histogram: ", watch.peek.total!"msecs", " ms, ", global.count, " samples");
    const region = Region2D(273, 183, 512, 384);
    foreach (pass; 0 .. 2)
    {
        watch.reset();
        watch.start();
        engine.run(image, region, Feature.gradient, 256, &consume);
        engine.run(image, region, pass == 0 ? Feature.localStatistics : Feature.oklab,
            256, &consume);
        watch.stop();
        writeln("Pass ", pass + 1, ": ", watch.peek.total!"msecs",
            " ms, cumulative cache hits ", engine.hits);
    }
    const measured = engine.metrics;
    check(engine.hits == 4, "Second consumer did not reuse all gradient tiles");
    check(measured.peakTileBytes <= 8 * 1024 * 1024, "Tile budget exceeded");
    check(measured.peakCacheBytes <= 16 * 1024 * 1024, "Cache budget exceeded");
    writeln("Tile buffer allocations: ", measured.scratchAllocations,
        ", peak tile buffer bytes: ", measured.peakTileBytes);
    writeln("Cache payload allocations: ", measured.cachePayloadAllocations,
        ", index growth requests: ", measured.cacheIndexGrowths,
        ", live cache bytes: ", measured.liveCacheBytes,
        ", peak cache bytes: ", measured.peakCacheBytes);
    writeln("Histogram scratch allocations: 1, scratch bytes: ", 256 * 256 * Sample.sizeof);
    foreach (feature; [Feature.localNormalization, Feature.gaussian, Feature.box,
        Feature.median, Feature.bilateral, Feature.diffusion, Feature.laplacian,
        Feature.clipping, Feature.underexposure, Feature.sharpness, Feature.noise,
        Feature.dynamicRange])
    {
        Engine radiometry;
        watch.reset();
        watch.start();
        radiometry.run(image, region, feature, 256, &consume);
        watch.stop();
        writeln(feature, ": ", watch.peek.total!"msecs", " ms, ",
            radiometry.metrics.peakTileBytes, " peak tile bytes");
    }
    const reference = fitLuminance(image, Region2D(0, 0, 1024, 512), 5, 95);
    watch.reset();
    watch.start();
    const sourceProfile = fitLuminance(image, Region2D(0, 0, image.width, image.height), 5, 95);
    watch.stop();
    writeln("Exposure profile: ", watch.peek.total!"msecs", " ms");
    watch.reset();
    watch.start();
    matchExposure(engine, image, region, sourceProfile, reference, 256, &consume);
    watch.stop();
    writeln("Exposure matching: ", watch.peek.total!"msecs", " ms");
    watch.reset();
    watch.start();
    equalizeLuminanceLocally(engine, image, region, 256, &consume);
    watch.stop();
    writeln("CLAHE: ", watch.peek.total!"msecs", " ms");
    auto overviewSource = resampleFeatureSource(image, 1024, 512, 1,
        FeatureResampling.nearest);
    const overview = selectFeatureOverview([image, overviewSource], 1024, 512);
    auto queue = new FeatureRequests;
    size_t deliveries;
    Sink receive = (Region2D tile, scope const(Value)[] values, Provenance origin) {
        ++deliveries;
        consume(tile, values, origin);
    };
    RequestFailure fail = (Exception error) { throw error; };
    const zoomTile = Region2D(320, 113, 256, 256);
    const panTile = Region2D(448, 113, 256, 256);
    const fineTile = Region2D(640, 226, 256, 256);
    watch.reset();
    watch.start();
    check(queue.submit(overview.source, panTile, Feature.gradient,
        RequestPriority.background, receive, fail) != 0, "Prefetch enqueue");
    foreach (i; 0 .. 2)
        check(queue.submit(overview.source, zoomTile, Feature.gradient,
            RequestPriority.visible, receive, fail) != 0, "Shared zoom enqueue");
    check(queue.pump(), "Zoom tile");
    check(queue.submit(image, fineTile, Feature.gradient,
        RequestPriority.visible, receive, fail) != 0, "Fine zoom enqueue");
    while (queue.pump()) {}
    watch.stop();
    check(deliveries == 4 && queue.executed == 3 &&
        queue.metrics.peakTileBytes <= 8 * 1024 * 1024 &&
        queue.metrics.peakCacheBytes <= 16 * 1024 * 1024, "Interactive budgets and sharing");
    writeln("Zoom/pan replay: ", watch.peek.total!"msecs", " ms, ", deliveries,
        " deliveries from ", queue.executed, " executed jobs; ",
        queue.metrics.peakTileBytes, " core peak tile bytes; ",
        queue.metrics.peakCacheBytes, " peak live cache bytes");
    writeln("Checksum: ", checksum);
    benchmarkAdvanced(image);
}

void main(string[] args)
{
    verify();
    verifyRadiometry();
    verifyInteractive();
    checkAdvanced();
    writeln("Feature reference checks passed");
    if (args.length == 3 && args[1] == "--photo")
        verifyPhoto(args[2]);
    else if (args.length == 2)
        benchmark(args[1]);
}
