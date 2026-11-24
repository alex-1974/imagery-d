module advanced_checks;

import imagery.analysis.feature_regions;
import imagery.analysis.feature_components;
import imagery.analysis.feature_segmentation;
import imagery.analysis.feature_evidence;
import imagery.analysis.feature_overviews;
import std.traits : EnumMembers;
import raster.region : Region2D;
import std.math : abs, cos, exp, PI, sin, sqrt;
import std.algorithm : clamp, min, max;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;

@safe:

private void expect(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

private bool windowEquivalent(Value a,Value b)
{
    if(a.valid!=b.valid || a.orientationValid!=b.orientationValid)return false;
    if(!a.valid)return true;
    foreach(c;0..3)if(abs(a.channels[c]-b.channels[c])>=1e-10)return false;
    return true;
}

private ComponentStore memoryLabels(uint[] labels, size_t width)
{
    return ComponentStore(
        (Region2D row, scope uint[] target) {
            const offset = row.y * width + row.x;
            target[] = labels[offset .. offset + row.width];
        },
        (Region2D row, scope const(uint)[] values) {
            const offset = row.y * width + row.x;
            labels[offset .. offset + row.width] = values[];
        });
}

void checkAdvanced()
{
    checkContracts();
    checkSharedView();
    checkDependencyOrder();
    checkProfileIdentity();
    checkRadiometryOracle();
    checkStructure();
    checkSquareMorphology();
    checkComponents();
    checkSpectral();
}

private void checkContracts()
{
    foreach (feature; EnumMembers!Feature)
    {
        const descriptor = describeFeature(feature);
        expect(descriptor.feature == feature && descriptor.parameters.length &&
            descriptor.channels.length && descriptor.validity.length && descriptor.usesSelectedLevel &&
            descriptor.implementationVersion == featureImplementationVersion,
            "Every feature has formal metadata");
    }
    const gabor = describeFeature(Feature.gaborCoarse45);
    expect(gabor.parameters == "wavelength=4;angle-deg=45;sigma=2;border=clamp" &&
        gabor.halo == 4 && gabor.channels[1].unit == FeatureUnit.radians &&
        gabor.channels[2].unit == FeatureUnit.pixels &&
        gabor.dependencyCount == 1 && gabor.dependencies[0] == Feature.luminance,
        "Gabor parameters and contract");
    const profile = describeFeature(Feature.exposureMatched);
    expect(profile.access == FeatureAccess.fittedProfile && profile.dependencyCount == 2 &&
        profile.dependencies[1] == Feature.distribution, "Fitted dependency chain");

    size_t reads;
    auto source = Source("metadata", "1", "grid", "temperature", "K", 0, 4, 4, false);
    source.metadata = ImageSourceMetadata(ImageEncoding.scalar, ImageBandRole.measured,
        ImageGridMetadata("EPSG:32633", true, [10, 2, 0, 20, 0, -3], 2, 3, "m"));
    source.metadata.product = ImageProductMetadata("fixture provider", "fixture sensor",
        "2026-11-15T00:00:00Z", 1, true, 0, 300);
    source.read = (Region2D tile, scope Sample[] samples) {
        ++reads;
        samples[] = Sample(7, [0, 0, 0], true);
    };
    const overview = resampleFeatureSource(source, 2, 2, 1, FeatureResampling.bilinearScalar);
    expect(overview.metadata.spatial.pixelSizeX == 4 && overview.metadata.spatial.pixelSizeY == 6 &&
        overview.metadata.spatial.affine == [10, 4, 0, 20, 0, -6],
        "Physical metadata of resampled grid");
    expect(overview.metadata.resampling.policy == "bilinearScalar" &&
        overview.metadata.resampling.parentGrid == "grid" &&
        overview.metadata.resampling.parentWidth == 4 &&
        overview.metadata.product == source.metadata.product, "Explicit resampling provenance");
    Engine engine;
    const region = Region2D(0, 0, 2, 2);
    const requested = [Feature.luminance, Feature.gradient];
    runFeatureView(engine, source, region, requested, 2,
        (Region2D tile, scope const(Value)[] samples, Provenance provenance) {
            expect(provenance.metadata == source.metadata &&
                provenance.parameters == describeFeature(provenance.feature).parameters,
                "Feature-view provenance");
        });
    expect(reads == 1 && engine.metrics.scalarTilePreparations == 1, "One scalar preparation per tile");
    runFeatureView(engine, source, region, requested, 2,
        (Region2D tile, scope const(Value)[] samples, Provenance provenance) {});
    expect(reads == 1, "Same feature metadata reuses results");
    source.metadata.spatial.crs = "EPSG:32632";
    runFeatureView(engine, source, region, requested, 2,
        (Region2D tile, scope const(Value)[] samples, Provenance provenance) {});
    expect(reads == 2, "Physical metadata participates in cache identity");
}

private void checkSharedView()
{
    enum width = 31, height = 15;
    auto image = Source("shared", "1", "grid", "RGB", "1", 0, width, height, true);
    image.read = (Region2D region, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const x = region.x + i % region.width, y = region.y + i / region.width;
            const shade = cast(ubyte)((x*x + 7*x*y + y) % 255);
            sample = Sample(0, [shade, shade, shade], x != 8 || y != 6);
        }
    };
    const features = [Feature.oklab, Feature.localStatistics, Feature.gradient,
        Feature.relativeDarkness, Feature.localNormalization, Feature.shadowCandidate,
        Feature.edgeEvidence, Feature.openingProfile];
    const region = Region2D(2, 1, 29, 14);
    Value[width * height][8] expected;
    Engine independent;
    foreach (index, feature; features)
        // Distinct identity keeps statistics/gradients out of the dependency cache.
        {
            auto source = image;
            source.revision = [ "a", "b", "c", "d", "e", "f", "g", "h" ][index];
            independent.run(source, region, feature, 9,
                (Region2D tile, scope const(Value)[] values, Provenance origin) {
                    foreach (i, value; values)
                        expected[index][(tile.y + i / tile.width) * width +
                            tile.x + i % tile.width] = value;
                });
        }

    size_t seen;
    Engine sharedEngine;
    void compare(Region2D tile, scope const(Value)[] values, Provenance origin)
    {
        size_t index;
        while (features[index] != origin.feature)
            ++index;
        ++seen;
        foreach (i, value; values)
        {
            const expectedValue = expected[index][(tile.y + i / tile.width) * width +
                tile.x + i % tile.width];
            expect(value == expectedValue, "Shared feature view differs from separate requests");
        }
    }
    runFeatureView(sharedEngine, image, region, features, 9, &compare);
    const cold = sharedEngine.metrics;
    expect(cold.sourceTileReads == 8 && cold.scalarTilePreparations == 8 &&
        cold.dependencyTileHits == 32 && cold.peakTileBytes <= 8 * 1024 * 1024 &&
        seen == 64, "Feature dependency reuse and bounded working set");
    runFeatureView(sharedEngine, image, region, features, 9, &compare);
    expect(seen == 128 && sharedEngine.metrics.sourceTileReads == cold.sourceTileReads &&
        sharedEngine.metrics.scratchAllocations == cold.scratchAllocations &&
        sharedEngine.hits == 64, "Warm shared view reuses every output");
}

private void checkDependencyOrder()
{
    expect(resolveFeaturePlan([Feature.localNormalization, Feature.localStatistics]) ==
        [Feature.luminance, Feature.localStatistics, Feature.localNormalization],
        "Transitive dependency order");
    expect(resolveFeaturePlan([Feature.exposureMatched]) ==
        [Feature.luminance, Feature.distribution, Feature.exposureMatched], "Fitted operation plan");

    auto image = Source("", "", "grid", "RGB", "1", 0, 15, 11, true);
    image.read = (Region2D region, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const x = region.x + i % region.width, y = region.y + i / region.width;
            const shade = cast(ubyte)((x*x + y*7) % 255);
            sample = Sample(0, [shade, shade, shade], x != 6 || y != 3);
        }
    };
    const order = [Feature.localStatistics, Feature.localNormalization, Feature.relativeDarkness,
        Feature.shadowCandidate, Feature.gradient, Feature.edgeEvidence];
    Value[15 * 11][6] whole;
    size_t slot(Feature feature)
    {
        foreach (i, candidate; order)
            if (candidate == feature)
                return i;
        assert(0, "Unexpected published dependency");
    }
    Engine baseline;
    runFeatureView(baseline, image, Region2D(0, 0, 15, 11), order, 64,
        (Region2D tile, scope const(Value)[] values, Provenance origin) {
            whole[slot(origin.feature)][] = values[];
        });
    import std.math : atan2, pow;
    double decoded(int x, int y)
    {
        x = clamp(x, 0, 14);
        y = clamp(y, 0, 10);
        if (x == 6 && y == 3)
            return double.nan;
        const encoded = ((x*x + y*7) % 255) / 255.0;
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4);
    }
    import std.math : isFinite;
    foreach (y; 0 .. 11)
        foreach (x; 0 .. 15)
        {
            const gx = ((decoded(x + 1, y - 1) - decoded(x - 1, y - 1)) +
                2*(decoded(x + 1, y) - decoded(x - 1, y)) +
                (decoded(x + 1, y + 1) - decoded(x - 1, y + 1))) / 8;
            const gy = ((decoded(x - 1, y + 1) - decoded(x - 1, y - 1)) +
                2*(decoded(x, y + 1) - decoded(x, y - 1)) +
                (decoded(x + 1, y + 1) - decoded(x + 1, y - 1))) / 8;
            const valid = isFinite(gx) && isFinite(gy) && isFinite(decoded(x, y));
            const gradient = whole[slot(Feature.gradient)][y * 15 + x];
            const edge = whole[slot(Feature.edgeEvidence)][y * 15 + x];
            expect(gradient.valid == valid && edge.valid == valid, "Sobel independent mask");
            if (valid)
            {
                const strength = sqrt(gx*gx + gy*gy);
                expect(abs(gradient.channels[0] - strength) < 1e-12 &&
                    abs(edge.channels[0] - min(1.0, strength / 0.125)) < 1e-12,
                    "Sobel and edge evidence oracle");
                if (strength > 1e-12)
                {
                    const delta = gradient.channels[1] - atan2(gy, gx);
                    expect(gradient.orientationValid && abs(sin(delta/2)) < 1e-11,
                        "Sobel orientation oracle");
                }
            }
        }

    const reversed = [Feature.edgeEvidence, Feature.gradient, Feature.shadowCandidate,
        Feature.relativeDarkness, Feature.localNormalization, Feature.localStatistics];
    foreach (region; [Region2D(3, 0, 1, 11), Region2D(3, 1, 11, 10), Region2D(0, 0, 15, 11)])
    {
        Engine engine;
        size_t emitted;
        runFeatureView(engine, image, region, reversed, 4,
            (Region2D tile, scope const(Value)[] values, Provenance origin) {
                expect(origin.feature == reversed[emitted++ % reversed.length], "Publication order");
                foreach (i, value; values)
                {
                    const x = tile.x + i % tile.width;
                    const y = tile.y + i / tile.width;
                    const prior=whole[slot(origin.feature)][y*15+x];
                    const moments=origin.feature==Feature.localStatistics ||
                        origin.feature==Feature.localNormalization || origin.feature==Feature.relativeDarkness ||
                        origin.feature==Feature.shadowCandidate;
                    expect(moments ? windowEquivalent(value,prior) : value==prior,
                        "Reordered overlapping feature values and validity");
                }
            });
        const tiles = ((region.width + 3) / 4) * ((region.height + 3) / 4);
        const metrics = engine.metrics;
        expect(emitted == tiles * 6 && metrics.dependencyEvaluations == tiles * 2 &&
            metrics.featureEvaluations == tiles * 4 && metrics.sourceTileReads == tiles &&
            metrics.scalarTilePreparations == tiles && metrics.dependencyCacheMisses == tiles * 2 &&
            metrics.dependencyCacheHits == tiles * 2, "One dependency evaluation per tile without cache");
    }

    auto scalar = Source("", "", "grid", "scalar", "K", 0, 15, 11, false);
    scalar.read = (Region2D tile, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const x = tile.x + i % tile.width, y = tile.y + i / tile.width;
            sample = Sample(x == 6 && y == 3 ? double.nan : 0, [0, 0, 0], true);
        }
    };
    Engine scalarEngine;
    runFeatureView(scalarEngine, scalar, Region2D(5, 3, 3, 1),
        [Feature.localNormalization, Feature.localStatistics], 4,
        (Region2D tile, scope const(Value)[] samples, Provenance origin) {
            expect(samples[0].valid && samples[0].channels[0] == 0 &&
                !samples[1].valid && samples[2].valid, "Finite zero versus nonfinite center");
        });

    image.identity = "failure";
    image.revision = "1";
    auto readGood = image.read;
    image.read = (Region2D tile, scope Sample[] samples) {
        readGood(tile, samples);
        throw new Exception("dependency read failed");
    };
    Engine retry;
    bool failed;
    size_t delivered;
    Sink count = (Region2D tile, scope const(Value)[] values, Provenance origin) { ++delivered; };
    try
        runFeatureView(retry, image, Region2D(0, 0, 3, 1), reversed, 4, count);
    catch (Exception error)
        failed = error.msg == "dependency read failed";
    expect(failed && !delivered && !retry.metrics.liveCacheBytes, "Dependency failure publishes nothing");
    image.read = readGood;
    runFeatureView(retry, image, Region2D(0, 0, 3, 1), reversed, 4, count);
    expect(delivered == 6 && retry.metrics.dependencyEvaluations == 2, "Retry a failed dependency");
}

private void checkProfileIdentity()
{
    auto image = Source("fit", "1", "grid", "RGB", "1", 0, 4, 1, true);
    image.read = (Region2D tile, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const shade = cast(ubyte)[0, 64, 128, 255][tile.x + i];
            sample = Sample(0, [shade, shade, shade], true);
        }
    };
    const region = Region2D(1, 0, 1, 1);
    const broad = fitLuminance(image, Region2D(0, 0, 4, 1), 25, 100);
    const narrow = fitLuminance(image, Region2D(0, 0, 3, 1), 25, 100);
    const otherRanks = fitLuminance(image, Region2D(0, 0, 4, 1), 50, 100);
    Engine engine;
    double last;
    Sink collect = (Region2D tile, scope const(Value)[] values, Provenance origin) {
        expect(values.length == 1 && values[0].valid, "Fitted tile");
        last = values[0].channels[0];
    };
    normalizeLuminance(engine, image, region, broad, 4, collect);
    const first = last;
    const cold = engine.metrics;
    normalizeLuminance(engine, image, region, narrow, 4, collect);
    expect(last > first && engine.metrics.cachePayloadAllocations == cold.cachePayloadAllocations + 1,
        "Fit extent isolates normalized tile");
    normalizeLuminance(engine, image, region, otherRanks, 4, collect);
    expect(last < first && engine.metrics.cachePayloadAllocations == cold.cachePayloadAllocations + 2,
        "Percentile parameters isolate normalized tile");
    const before = engine.hits;
    normalizeLuminance(engine, image, region, broad, 4, collect);
    expect(last == first && engine.hits == before + 2, "Fitted tile cache replay");
}

private void checkRadiometryOracle()
{
    import std.algorithm : sort;
    import std.math : pow;
    enum width = 13, height = 11;
    Sample read(int x, int y)
    {
        x = clamp(x, 0, width - 1);
        y = clamp(y, 0, height - 1);
        const v = cast(ubyte)((x*x + 19*x*y + 7*y) % 256);
        return Sample(0, [v, v, v], (x + 2*y) % 11 != 0);
    }
    double decode(Sample sample)
    {
        const v = sample.rgb[0] / 255.0;
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    }
    auto image = Source("radiometry oracle", "1", "grid", "RGB", "1", 0, width, height, true);
    image.read = (Region2D tile, scope Sample[] values) {
        foreach (i, ref value; values)
            value = read(cast(int)(tile.x + i % tile.width), cast(int)(tile.y + i / tile.width));
    };

    Value reference(Feature feature, int x, int y)
    {
        const center = read(x, y);
        if (!center.valid)
            return Value.init;
        const value = decode(center);
        auto result = Value([0, 0, 0], true, false);
        if (feature == Feature.clipping || feature == Feature.underexposure)
        {
            result.channels[0] = feature == Feature.clipping ? center.rgb[0] == 255 : value <= 0.01;
            return result;
        }
        if (feature == Feature.diffusion || feature == Feature.laplacian || feature == Feature.sharpness)
        {
            double response = 0;
            foreach (axis; [[0, -1], [0, 1], [-1, 0], [1, 0]])
            {
                const neighbor = read(x + axis[0], y + axis[1]);
                if (!neighbor.valid)
                    return Value.init;
                const delta = decode(neighbor) - value;
                response += feature == Feature.diffusion ? delta * exp(-100*delta*delta) : delta;
            }
            result.channels[0] = feature == Feature.diffusion ? value + response/5 :
                feature == Feature.sharpness ? abs(response) : response;
            return result;
        }

        const large = feature == Feature.localStatistics || feature == Feature.dynamicRange ||
            feature == Feature.localNormalization || feature == Feature.relativeDarkness ||
            feature == Feature.shadowCandidate;
        const radius = large ? 3 : 1;
        double[49] elements;
        size_t count;
        double sum = 0, weighted = 0, weights = 0;
        foreach (dy; -radius .. radius + 1)
            foreach (dx; -radius .. radius + 1)
            {
                const sample = read(x + dx, y + dy);
                if (!sample.valid)
                    continue;
                const v = decode(sample);
                elements[count++] = v;
                sum += v;
                if (large)
                    continue;
                double weight = feature == Feature.box ? 1 : (2 - abs(dx)) * (2 - abs(dy));
                if (feature == Feature.bilateral)
                    weight *= exp(-50 * (v - value) * (v - value));
                weighted += weight * v;
                weights += weight;
            }
        if (count < (large ? 25 : 5))
            return Value.init;
        auto window = elements[0 .. count];
        if (feature == Feature.noise || feature == Feature.median)
        {
            sort(window);
            if (feature == Feature.noise)
            {
                const middle = (window[(count - 1) / 2] + window[count / 2]) / 2;
                foreach (ref v; window)
                    v = abs(v - middle);
                sort(window);
            }
            result.channels[0] = (window[(count - 1) / 2] + window[count / 2]) / 2;
            return result;
        }
        if (!large)
        {
            result.channels[0] = weighted / weights;
            return result;
        }

        const mean = sum / count;
        double sse = 0, low = double.infinity, high = -double.infinity;
        foreach (v; window)
        {
            sse += (v - mean) * (v - mean);
            low = min(low, v);
            high = max(high, v);
        }
        const sigma = sqrt(sse / count);
        if (feature == Feature.localStatistics)
            result.channels = [mean, sigma, 0];
        else if (feature == Feature.dynamicRange)
            result.channels[0] = high - low;
        else if (feature == Feature.localNormalization)
            result.channels[0] = sigma ? (value - mean) / sigma : 0;
        else
        {
            const darkness = mean ? clamp(1 - value / mean, 0.0, 1.0) : 0;
            result.channels[0] = feature == Feature.shadowCandidate ?
                darkness * clamp(1 - value/0.15, 0.0, 1.0) : darkness;
        }
        return result;
    }

    const features = [Feature.clipping, Feature.underexposure, Feature.diffusion, Feature.laplacian,
        Feature.sharpness, Feature.gaussian, Feature.box, Feature.median, Feature.bilateral,
        Feature.noise, Feature.localStatistics, Feature.dynamicRange, Feature.localNormalization,
        Feature.relativeDarkness, Feature.shadowCandidate];
    Engine engine;
    foreach (edge; [4, 64])
        runFeatureView(engine, image, Region2D(1, 0, width - 1, height), features, edge,
            (Region2D tile, scope const(Value)[] values, Provenance origin) {
                foreach (i, value; values)
                {
                    const expected = reference(origin.feature, cast(int)(tile.x + i % tile.width),
                        cast(int)(tile.y + i / tile.width));
                    expect(value.valid == expected.valid, "Radiometry oracle mask");
                    if (value.valid)
                        foreach (j; 0 .. 3)
                            expect(abs(value.channels[j] - expected.channels[j]) < 1e-11,
                                "Radiometry oracle value");
                }
            });
}

private immutable Feature[] structuralFeatures = [
    Feature.entropy, Feature.localBinaryPattern, Feature.cooccurrence, Feature.edgeDensity,
    Feature.directedEdges, Feature.orientationHistogram, Feature.gabor, Feature.ridge,
    Feature.lineResponse, Feature.erosion, Feature.dilation, Feature.opening, Feature.closing,
    Feature.topHat, Feature.bottomHat, Feature.pathOpening, Feature.pathClosing,
    Feature.openingProfile, Feature.closingProfile, Feature.directedOpening,
    Feature.directedClosing, Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90,
    Feature.gaborFine135, Feature.gaborCoarse0, Feature.gaborCoarse45, Feature.gaborCoarse90,
    Feature.gaborCoarse135,
    Feature.relativeDarkness, Feature.shadowCandidate, Feature.visibility, Feature.edgeEvidence
];

private void checkStructure()
{
    enum width = 17, height = 15;
    Source image = Source("structure", "1", "grid", "RGB", "", 0, width, height, true);
    image.read = (Region2D region, scope Sample[] samples) {
        foreach (i, ref sample; samples)
        {
            const x = region.x + i % region.width;
            const y = region.y + i / region.width;
            const shade = cast(ubyte)(x == 8 ? 255 : 0);
            sample = Sample(0, [shade, shade, shade], x != 0 || y != 0);
        }
    };
    Engine engine;
    foreach (feature; structuralFeatures)
    {
        Value[width * height] whole;
        engine.run(image, Region2D(0, 0, width, height), feature, 32,
            (Region2D tile, scope const(Value)[] samples, Provenance origin) {
                whole[] = samples[];
            });
        engine.run(image, Region2D(1, 1, width - 1, height - 1), feature, 4,
            (Region2D tile, scope const(Value)[] samples, Provenance origin) {
                foreach (i, sample; samples)
                {
                    const x = tile.x + i % tile.width;
                    const y = tile.y + i / tile.width;
                    expect(sample == whole[y * width + x], "Structural region equivalence");
                }
            });
        expect(!whole[0].valid, "Structural NoData");
        if (feature >= Feature.gaborFine0 && feature <= Feature.gaborCoarse135)
        {
            // Independent spatial convolution with complex Gaussian weights.
            const index = feature - Feature.gaborFine0;
            const radius = index < 4 ? 2 : 4;
            const angle = (index % 4) * PI / 4;
            foreach (y; 0 .. height)
                foreach (x; 0 .. width)
                {
                    bool valid = true;
                    double realPart = 0, imagPart = 0, normalizer = 0;
                    foreach (dy; -radius .. radius + 1)
                        foreach (dx; -radius .. radius + 1)
                        {
                            const sx = clamp(x + dx, 0, width - 1);
                            const sy = clamp(y + dy, 0, height - 1);
                            valid &= sx != 0 || sy != 0;
                            const coefficient = exp(-2.0 * (dx*dx + dy*dy) / (radius*radius));
                            const phase = 2 * PI * (dx*cos(angle) + dy*sin(angle)) / radius;
                            const delta = cast(int)(sx == 8) - cast(int)(x == 8);
                            realPart += delta * coefficient * cos(phase);
                            imagPart += delta * coefficient * sin(phase);
                            normalizer += coefficient;
                        }
                    const actual = whole[y * width + x];
                    expect(actual.valid == valid, "Gabor independent support");
                    if (valid)
                    {
                        const magnitude = sqrt(realPart*realPart + imagPart*imagPart) / normalizer;
                        expect(abs(actual.channels[0] - magnitude) < 1e-12,
                            "Gabor independent magnitude");
                        if (magnitude > 1e-12)
                            expect(actual.orientationValid && abs(actual.channels[1] - angle) < 1e-12 &&
                                actual.channels[2] == radius, "Gabor orientation and scale");
                    }
                }
        }
        const line = whole[7 * width + 8];
        const side = whole[7 * width + 7];
        expect(line.valid && side.valid, "Structural support");
        switch (feature)
        {
            case Feature.entropy:
                const p = 1.0 / 7;
                import std.math : log2;
                expect(abs(line.channels[0] + p * log2(p) +
                    (1 - p) * log2(1 - p)) < 1e-12, "Binary entropy reference");
                break;
            case Feature.localBinaryPattern:
                expect(line.channels[0] == 34, "Vertical neighbor bits");
                break;
            case Feature.cooccurrence:
                expect(abs(line.channels[0] - 75) < 1e-12 &&
                    abs(line.channels[1] - 0.5) < 1e-12 &&
                    abs(line.channels[2] - 0.6875) < 1e-12, "Cooccurrence reference");
                break;
            case Feature.edgeDensity:
                expect(abs(line.channels[0] - 0.4) < 1e-12, "Edge density reference");
                break;
            case Feature.directedEdges:
                expect(abs(side.channels[0] - 0.5) < 1e-12, "Directed central difference");
                break;
            case Feature.orientationHistogram:
                expect(side.channels == [1, 0, 0], "Axial histogram reference");
                break;
            case Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90, Feature.gaborFine135,
                 Feature.gaborCoarse0, Feature.gaborCoarse45, Feature.gaborCoarse90,
                 Feature.gaborCoarse135:
                expect(line.channels[0] >= 0 && line.channels[2] ==
                    (feature <= Feature.gaborFine135 ? 2 : 4), "Gabor bank response");
                break;
            case Feature.directedOpening:
                expect(abs(line.channels[1] - 1) < 1e-12 &&
                    line.channels[0] == 0 && line.channels[2] == 0, "Directional opening");
                break;
            case Feature.directedClosing:
                foreach (sample; line.channels)
                    expect(abs(sample - 1) < 1e-12, "Directional closing");
                break;
            case Feature.gabor:
                expect(line.channels[0] > 0 && line.orientationValid, "Line Gabor response");
                break;
            case Feature.ridge, Feature.lineResponse:
                expect(abs(line.channels[0] - 1) < 1e-12 &&
                    line.orientationValid && line.channels[2] == 1, "Ridge response");
                break;
            case Feature.erosion, Feature.opening:
                expect(line.channels[0] == 0, "Bright impulse removed");
                break;
            case Feature.openingProfile:
                expect(line.channels == [0, 0, 0], "Bright line removed on all square scales");
                break;
            case Feature.dilation, Feature.closing, Feature.pathOpening, Feature.pathClosing:
                expect(abs(line.channels[0] - 1) < 1e-12, "Line morphology reference");
                break;
            case Feature.closingProfile:
                foreach (sample; line.channels)
                    expect(abs(sample - 1) < 1e-12, "Closing profile");
                break;
            case Feature.topHat, Feature.bottomHat:
                expect(abs(line.channels[0] - (feature == Feature.topHat ? 1 : 0)) < 1e-12,
                    "Hat response");
                break;
            case Feature.relativeDarkness, Feature.shadowCandidate:
                expect(line.channels[0] == 0 && side.channels[0] == 1,
                    "Darkness evidence reference");
                break;
            case Feature.visibility:
                expect(line.channels[0] == 0 && side.channels[0] == 0,
                    "Exposure evidence reference");
                break;
            case Feature.edgeEvidence:
                expect(line.channels[0] == 0 && side.channels[0] == 1, "Sobel evidence reference");
                break;
            default:
                assert(0);
        }
    }
}

private void checkSquareMorphology()
{
    enum width = 19, height = 17;
    Sample reference(int x, int y)
    {
        x = clamp(x, 0, width - 1);
        y = clamp(y, 0, height - 1);
        return Sample((x*x + 31*y + 7*x*y) % 91 - 55.0, [0, 0, 0],
            (x != 8 || y != 7) && (x != 0 || y != 16));
    }

    auto image = Source("square reference", "1", "grid", "measurement", "K", 0,
        width, height, false);
    image.read = (Region2D region, scope Sample[] result) {
        foreach (i, ref sample; result)
            sample = reference(cast(int)(region.x + i % region.width),
                cast(int)(region.y + i / region.width));
    };
    Value oracle(int x, int y, Feature feature)
    {
        const closing = feature == Feature.closing || feature == Feature.closingProfile ||
            feature == Feature.bottomHat;
        const profile = feature == Feature.openingProfile || feature == Feature.closingProfile;
        auto result = Value([0, 0, 0], true, false);
        foreach (radius; 1 .. (profile ? 4 : 2))
        {
            double outer = closing ? double.infinity : -double.infinity;
            foreach (oy; -radius .. radius + 1)
                foreach (ox; -radius .. radius + 1)
                {
                    double inner = closing ? -double.infinity : double.infinity;
                    foreach (iy; -radius .. radius + 1)
                        foreach (ix; -radius .. radius + 1)
                        {
                            const input = reference(x + ox + ix, y + oy + iy);
                            if (!input.valid)
                                return Value.init;
                            inner = closing ? max(inner, input.scalar) : min(inner, input.scalar);
                        }
                    outer = closing ? min(outer, inner) : max(outer, inner);
                }
            if (feature == Feature.topHat)
                outer = reference(x, y).scalar - outer;
            else if (feature == Feature.bottomHat)
                outer -= reference(x, y).scalar;
            result.channels[radius - 1] = outer;
        }
        return result;
    }

    Engine engine;
    foreach (feature; [Feature.opening, Feature.closing, Feature.topHat, Feature.bottomHat,
        Feature.openingProfile, Feature.closingProfile])
        foreach (edge; [1, 4, 256])
            engine.run(image, Region2D(1, 0, width - 1, height), feature, edge,
                (Region2D tile, scope const(Value)[] results, Provenance origin) {
                    foreach (i, sample; results)
                    {
                        const x = cast(int)(tile.x + i % tile.width);
                        const y = cast(int)(tile.y + i / tile.width);
                        expect(sample == oracle(x, y, feature), "Direct square morphology oracle");
                    }
                });
    expect(engine.metrics.peakTileBytes <= 8 * 1024 * 1024, "Morphology work budget");
}

private void checkComponents()
{
    enum width = 12, height = 7;
    const extent = Region2D(0, 0, width, height);
    ComponentReader mask = (Region2D row, scope ComponentSample[] result) {
        foreach (i, ref pixel; result)
        {
            const x = row.x + i;
            pixel = ComponentSample.init;
            if (row.y == 2)
                pixel.state = x == 0 ? ComponentSample.State.seed : ComponentSample.State.candidate;
            if (row.y == 5 && x < 3)
                pixel.state = ComponentSample.State.candidate;
            pixel.valid = row.y != 0 || x != 0;
            pixel.color = [cast(double)x - 3.5, 1, 0];
            pixel.texture = 3;
        }
    };
    auto first = new uint[width * height];
    auto second = new uint[width * height];
    auto full = memoryLabels(first, width);
    auto tiled = memoryLabels(second, width);
    ComponentStatistics actual;
    bool[width * height] validPixels;
    labelComponents(extent, mask, full, ComponentPolicy(true, true), 32, 12);
    labelComponents(extent, mask, tiled, ComponentPolicy(true, true), 32, 3,
        (ComponentStatistics stats) { actual = stats; }, null,
        (Region2D row, scope const(bool)[] valid) {
            const start = row.y * width + row.x;
            validPixels[start .. start + row.width] = valid[];
        }, ComponentProvenance("component source", "1", "test grid"));
    expect(!validPixels[0] && validPixels[1] && first[0] == 0 && first[1] == 0,
        "NoData and excluded labels have distinct validity");
    expect(first == second && first[2 * width .. 3 * width] == [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] &&
        first[5 * width] == 0, "Seed connectivity across blocks");
    expect(actual.pixels == width && actual.bounds == Region2D(0, 2, width, 1) &&
        actual.perimeter == 26 && actual.meanColor == [2, 1, 0] &&
        actual.textureSamples == width && actual.meanTexture == 3 &&
        actual.edgeSamples == 0 && abs(actual.colorVariance[0] - 143.0 / 12) < 1e-12 &&
        actual.colorVariance[1] == 0 && actual.fillRatio == 1 &&
        actual.orientationValid && actual.orientation == 0 &&
        actual.provenance.analysisExtent == extent &&
        actual.provenance.identity == "component source" &&
        actual.provenance.policy.requireSeed, "Component statistics");
    const evidence = regionEvidence(actual);
    expect(evidence.valid && evidence.textureCoverage == 1 && evidence.edgeCoverage == 0 &&
        evidence.compactness > 0 && evidence.compactness < 1, "Region evidence");
    uint segments;
    traceLabelLines(extent, tiled.read, 8, (LineSegment line) {
        ++segments;
        expect(line.x0 == 0 && line.y0 == 2 && line.x1 == 11 && line.y1 == 2 &&
            line.pixels == width, "Cross-block line");
    });
    expect(segments == 1, "Unique long line");

    auto scalar = Source("components", "1", "grid", "surface", "K", 0, width, height, false);
    scalar.read = (Region2D row, scope Sample[] samples) {
        foreach (i, ref sample; samples)
            sample = Sample(row.x + i % row.width < 6 ? 0 : 1, [0, 0, 0], true);
    };
    size_t contacts;
    labelComponents(extent, imageComponents(scalar), tiled, ComponentPolicy(false, false, 0),
        32, 4, null, (uint a, uint b) { expect(a == 1 && b == 2, "Color contact"); ++contacts; });
    expect(contacts == height && second[5] == 1 && second[6] == 2,
        "Color-region merge and adjacency");
    labelComponents(extent, imageComponents(scalar), tiled, ComponentPolicy(false, false, 0, 3),
        32, 5);
    expect(second[0] != second[3] && second[0] != second[3 * width] &&
        second[2] == second[0], "Source-anchored superpixels");

    auto edges = cannyComponents(scalar, 0.1, 0.4);
    labelComponents(extent, edges, full, ComponentPolicy(true, true), 32, 12);
    labelComponents(extent, edges, tiled, ComponentPolicy(true, true), 32, 4);
    expect(first == second, "Canny region equivalence");
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            expect((first[y * width + x] != 0) == (x == 5), "Canny step reference");

    bool budgetReached;
    try
        labelComponents(extent, imageComponents(scalar), tiled,
            ComponentPolicy(false, false, 0, 1), 1, 4);
    catch (Exception error)
        budgetReached = error.msg == "Connected-component label budget exhausted";
    expect(budgetReached, "Enforced label budget");
}

private void checkSpectral()
{
    Source band(string name, double value)
    {
        auto result = Source(name, "1", "aligned", name, "1", 0, 4, 2, false);
        result.read = (Region2D tile, scope Sample[] samples) {
            foreach (i, ref sample; samples)
            {
                const x = tile.x + i % tile.width;
                sample = Sample(x == 2 ? 0 : value, [0, 0, 0], x != 3);
            }
        };
        return result;
    }
    auto nir = SpectralBand(band("NIR", 0.6), BandRole.nearInfrared, BandDomain.unitReflectance);
    auto red = SpectralBand(band("red", 0.2), BandRole.red, BandDomain.unitReflectance);
    auto green = SpectralBand(band("green", 0.3), BandRole.green, BandDomain.unitReflectance);
    const region = Region2D(0, 0, 4, 2);
    foreach (feature; [SpectralFeature.difference, SpectralFeature.ratio,
        SpectralFeature.vegetationResponse, SpectralFeature.waterResponse])
        foreach (edge; [1, 4])
            spectralRegions(feature == SpectralFeature.waterResponse ? green : nir,
                feature == SpectralFeature.waterResponse ? nir : red, region, feature, edge,
                (Region2D tile, scope const(SpectralValue)[] values, SpectralProvenance provenance) {
                    expect(provenance.grid == "aligned" && provenance.extent == tile &&
                        provenance.feature == feature && provenance.outputUnit == "1", "Band provenance");
                    foreach (i, value; values)
                    {
                        const x = tile.x + i % tile.width;
                        const valid = x < 2 || (x == 2 && feature == SpectralFeature.difference);
                        expect(value.valid == valid, "Spectral missing and zero denominator");
                        const expected = [0.4, 3, 0.5, -1.0/3][cast(size_t)feature];
                        if (valid)
                            expect(abs(value.value - (x == 2 ? 0 : expected)) < 1e-12,
                                "Spectral response reference");
                    }
                });
    bool rejected;
    try
        spectralRegions(red, nir, region, SpectralFeature.vegetationResponse, 2,
            (Region2D tile, scope const(SpectralValue)[] values, SpectralProvenance provenance) {});
    catch (Exception error)
        rejected = true;
    expect(rejected, "Swapped band roles");
    const validRed = red;
    red.source.metadata.role = ImageBandRole.green;
    rejected = false;
    try
        spectralRegions(nir, red, region, SpectralFeature.vegetationResponse, 2,
            (Region2D tile, scope const(SpectralValue)[] values, SpectralProvenance provenance) {});
    catch (Exception error)
        rejected = true;
    expect(rejected, "Requested spectral role must match metadata");

    red = validRed;
    red.source.read = (Region2D tile, scope Sample[] values) {
        foreach (i, ref value; values)
        {
            const x = tile.x + i % tile.width;
            value = Sample(x == 0 ? double.nan : 1.01, [0, 0, 0], true);
        }
    };
    spectralRegions(nir, red, Region2D(0, 0, 2, 1), SpectralFeature.vegetationResponse, 2,
        (Region2D tile, scope const(SpectralValue)[] values, SpectralProvenance provenance) {
            expect(!values[0].valid && !values[1].valid, "Invalid reflectance cannot become evidence");
        });
}

// A numerical screen for candidate storage formats. It does not change
// production cache precision or encode persistent buffers.
private void measurePrecision(Source image, Region2D region)
{
    import std.math : frexp, isFinite, ldexp, nearbyint;
    foreach (feature; [Feature.luminance, Feature.edgeDensity, Feature.visibility, Feature.edgeEvidence,
        Feature.gabor, Feature.openingProfile])
    {
        const descriptor = describeFeature(feature);
        double[4] error = [0, 0, 0, 0];
        size_t integerSamples;
        Engine engine;
        engine.run(image, region, feature, 64,
            (Region2D tile, scope const(Value)[] values, Provenance origin) {
                foreach (value; values)
                    if (value.valid)
                        foreach (channel, definition; descriptor.channels)
                        {
                            if (definition.unit == FeatureUnit.radians && !value.orientationValid)
                                continue;
                            const input = value.channels[channel];
                            int exponent;
                            frexp(input, exponent);
                            const step = ldexp(1.0, max(exponent - 11, -24));
                            const half = nearbyint(input / step) * step;
                            error[0] = max(error[0], abs(input - cast(float)input));
                            error[1] = max(error[1], abs(input - half));
                            if (!isFinite(definition.minimum) || !isFinite(definition.maximum) ||
                                definition.minimum == definition.maximum)
                                continue;
                            ++integerSamples;
                            const span = definition.maximum - definition.minimum;
                            const ratio = clamp((input - definition.minimum) / span, 0.0, 1.0);
                            foreach (i, levels; [255.0, 65_535.0])
                            {
                                const decoded = definition.minimum +
                                    nearbyint(ratio * levels) / levels * span;
                                error[2 + i] = max(error[2 + i], abs(input - decoded));
                            }
                        }
            });
        writeln("Precision ", feature, ": ", error, " max abs error (f32,f16,u8,u16); ",
            integerSamples, " bounded-channel samples");
    }
}

private void benchmarkTileCatalog(Source image)
{
    const region = Region2D(273, 183, 128, 96);
    double checksum;
    writeln("Feature,halo,cold_us,warm_us,working_bytes,scratch_allocations,retained_bytes,cache_hits");
    foreach (feature; EnumMembers!Feature)
    {
        const descriptor = describeFeature(feature);
        if (descriptor.access != FeatureAccess.tile)
            continue;
        Engine engine;
        StopWatch watch;
        void consume(Region2D tile, scope const(Value)[] values, Provenance origin)
        {
            foreach (value; values)
                if (value.valid)
                    checksum += value.channels[0];
        }
        watch.start();
        engine.run(image, region, feature, 64, &consume);
        watch.stop();
        const cold = watch.peek.total!"usecs";
        const first = engine.metrics;
        watch.reset();
        watch.start();
        engine.run(image, region, feature, 64, &consume);
        watch.stop();
        const warm = engine.metrics;
        expect(warm.peakTileBytes <= 8 * 1024 * 1024 &&
            warm.peakCacheBytes <= 16 * 1024 * 1024 &&
            warm.sourceTileReads == first.sourceTileReads &&
            warm.scratchAllocations == first.scratchAllocations &&
            engine.hits == 4, "Catalog memory and warm-cache contract");
        writeln(feature, ",", descriptor.halo, ",", cold, ",", watch.peek.total!"usecs",
            ",", warm.peakTileBytes, ",", warm.scratchAllocations, ",", warm.liveCacheBytes,
            ",", engine.hits);
    }
    writeln("Catalog checksum: ", checksum);
}

private void benchmarkDependencies(Source image)
{
    const region = Region2D(273, 183, 128, 96);
    const requested = [Feature.localNormalization, Feature.relativeDarkness,
        Feature.shadowCandidate, Feature.localStatistics];
    Engine engine;
    StopWatch watch;
    double checksum = 0;
    void consume(Region2D tile, scope const(Value)[] values, Provenance origin)
    {
        foreach (value; values)
            if (value.valid)
                checksum += value.channels[0];
    }
    watch.start();
    runFeatureView(engine, image, region, requested, 64, &consume);
    watch.stop();
    const cold = engine.metrics;
    const coldUs = watch.peek.total!"usecs";
    watch.reset();
    watch.start();
    runFeatureView(engine, image, region, requested, 64, &consume);
    watch.stop();
    expect(cold.sourceTileReads == 4 && cold.scalarTilePreparations == 4 &&
        cold.dependencyEvaluations == 4 && cold.featureEvaluations == 12 &&
        engine.metrics.featureEvaluations == cold.featureEvaluations &&
        engine.metrics.dependencyEvaluations == cold.dependencyEvaluations &&
        engine.hits == 20, "Cold and warm dependency budget");
    writeln("Dependency replay: ", coldUs, " cold us; ", watch.peek.total!"usecs",
        " warm us; ", cold.sourceTileReads, " reads; ", cold.scalarTilePreparations,
        " scalar preparations; ", cold.dependencyEvaluations, " dependency evaluations; ",
        cold.dependencyCacheHits, " dependency hits; ", cold.dependencyCacheMisses,
        " misses; ", cold.featureEvaluations, " output evaluations; ", cold.peakTileBytes,
        " scratch bytes; ", cold.peakDependencyBytes, " pinned bytes; ", cold.peakCacheBytes,
        " accounted cache bytes; checksum ", checksum);
}

void benchmarkAdvanced(Source image)
{
    benchmarkDependencies(image);
    benchmarkTileCatalog(image);
    measurePrecision(image, Region2D(273, 183, 128, 96));
    StopWatch watch;
    double checksum = 0;
    const region = Region2D(273, 183, 128, 96);
    foreach (feature; structuralFeatures)
    {
        Engine engine;
        watch.reset();
        watch.start();
        engine.run(image, region, feature, 64,
            (Region2D tile, scope const(Value)[] values, Provenance origin) {
                foreach (value; values)
                    if (value.valid)
                        checksum += value.channels[0];
            });
        watch.stop();
        writeln(feature, ": ", watch.peek.total!"msecs", " ms, ",
            engine.metrics.peakTileBytes, " peak tile bytes");
    }
    const extent = Region2D(273, 183, 128, 96);
    // This harness uses RAM for the caller-owned label store. A large
    // consumer can supply a windowed or disk-backed store.
    auto labels = new uint[(extent.y + extent.height) * image.width];
    auto store = memoryLabels(labels, image.width);
    size_t components;
    watch.reset();
    watch.start();
    labelComponents(extent, cannyComponents(image, 0.04, 0.1), store,
        ComponentPolicy(true, true), 4096, 64,
        (ComponentStatistics stats) { ++components; });
    traceLabelLines(extent, store.read, 6, (LineSegment line) { checksum += line.pixels; });
    watch.stop();
    writeln("Canny and lines: ", watch.peek.total!"msecs", " ms, ", components,
        " components, component scratch: ", componentScratchBytes(4096), " bytes");
    watch.reset();
    watch.start();
    labelComponents(extent, imageComponents(image, true), store,
        ComponentPolicy(false, false, 0.05, 16), 4096, 64,
        (ComponentStatistics stats) { checksum += regionEvidence(stats).compactness; });
    watch.stop();
    writeln("Color regions and quality: ", watch.peek.total!"msecs", " ms, checksum ", checksum);

    Source channel(string name, size_t index)
    {
        auto band = Source(image.identity, image.revision, image.grid, name, "code",
            image.level, image.width, image.height, false);
        band.read = (Region2D tile, scope Sample[] samples) {
            image.read(tile, samples);
            foreach (ref sample; samples)
                sample.scalar = sample.rgb[index];
        };
        return band;
    }
    const red = SpectralBand(channel("red", 0), BandRole.red, BandDomain.measurement);
    const green = SpectralBand(channel("green", 1), BandRole.green, BandDomain.measurement);
    watch.reset();
    watch.start();
    spectralRegions(red, green, extent, SpectralFeature.difference, 64,
        (Region2D tile, scope const(SpectralValue)[] values, SpectralProvenance origin) {
            foreach (value; values)
                if (value.valid)
                    checksum += value.value;
        });
    watch.stop();
    writeln("Channel difference: ", watch.peek.total!"usecs", " us, checksum ", checksum);
}
