module imagery.analysis.feature_structure;

import imagery.analysis.feature_regions : Feature, Point, Value;
import std.algorithm : min, max;
import std.math : abs, atan2, cos, exp, isFinite, log2, PI, sin, sqrt;

@safe:

private alias ReadPoint = Point delegate(int, int) @safe;
private immutable int[2][4] directions = [[1, 0], [1, 1], [0, 1], [-1, 1]];

package bool structureRequiresRgb(Feature feature)
{
    return feature == Feature.entropy || feature == Feature.cooccurrence ||
        feature == Feature.edgeDensity;
}

package size_t structureHalo(Feature feature)
{
    switch (feature)
    {
        case Feature.localBinaryPattern, Feature.erosion, Feature.dilation:
            return 1;
        case Feature.entropy, Feature.cooccurrence, Feature.edgeDensity,
             Feature.orientationHistogram, Feature.ridge:
            return 3;
        case Feature.directedEdges:
            return 1;
        case Feature.opening, Feature.closing, Feature.topHat, Feature.bottomHat:
            return 2;
        case Feature.pathOpening, Feature.pathClosing, Feature.openingProfile,
             Feature.closingProfile:
            return 6;
        case Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90, Feature.gaborFine135,
             Feature.directedOpening, Feature.directedClosing:
            return 2;
        case Feature.gabor, Feature.lineResponse, Feature.gaborCoarse0, Feature.gaborCoarse45,
             Feature.gaborCoarse90, Feature.gaborCoarse135:
            return 4;
        default:
            assert(0, "Not a structural feature");
    }
}

private Value values(double a, double b = 0, double c = 0, bool oriented = false)
{
    if (!isFinite(a) || !isFinite(b) || !isFinite(c))
        return Value.init;
    return Value([a, b, c], true, oriented);
}

package Value evaluateStructure(Feature feature, scope ReadPoint read)
{
    const center = read(0, 0);
    if (!center.valid)
        return Value.init;
    switch (feature)
    {
        case Feature.entropy, Feature.cooccurrence:
            return texture(feature, read);
        case Feature.localBinaryPattern:
            uint code;
            immutable int[2][8] offsets =
                [[-1, -1], [0, -1], [1, -1], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0]];
            foreach (i, offset; offsets)
            {
                const point = read(offset[0], offset[1]);
                if (!point.valid)
                    return Value.init;
                if (point.value >= center.value)
                    code |= 1u << i;
            }
            return values(code);
        case Feature.edgeDensity, Feature.directedEdges, Feature.orientationHistogram:
            return edges(feature, read);
        case Feature.gabor, Feature.ridge, Feature.lineResponse,
             Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90, Feature.gaborFine135,
             Feature.gaborCoarse0, Feature.gaborCoarse45, Feature.gaborCoarse90, Feature.gaborCoarse135:
            return lines(feature, read);
        default:
            return morphology(feature, read);
    }
}

private size_t bin(double value)
{
    return min(15, cast(size_t)(16 * value));
}

private Value texture(Feature feature, scope ReadPoint read)
{
    uint[256] counts;
    uint total;
    foreach (y; -3 .. 4)
        foreach (x; -3 .. 4)
        {
            const a = read(x, y);
            if (!a.valid)
                continue;
            const first = bin(a.value);
            if (feature == Feature.entropy)
            {
                ++counts[first];
                ++total;
            }
            else if (x < 3)
            {
                const b = read(x + 1, y);
                if (b.valid)
                {
                    const second = bin(b.value);
                    ++counts[first * 16 + second];
                    ++counts[second * 16 + first];
                    total += 2;
                }
            }
        }
    const minimum = feature == Feature.entropy ? 25 : 42;
    if (total < minimum)
        return Value.init;
    double a = 0, b = 0, c = 0;
    foreach (i, count; counts)
    {
        if (!count)
            continue;
        const p = count / cast(double)total;
        if (feature == Feature.entropy)
            a -= p * log2(p);
        else
        {
            const delta = abs(cast(int)(i / 16) - cast(int)(i % 16));
            a += p * delta * delta;
            b += p * p;
            c += p / (1 + delta);
        }
    }
    return values(a, b, c);
}

private Value edges(Feature feature, scope ReadPoint read)
{
    double[3] sums = [0, 0, 0];
    uint count, detected;
    const radius = feature == Feature.directedEdges ? 0 : 2;
    foreach (y; -radius .. radius + 1)
        foreach (x; -radius .. radius + 1)
        {
            const l = read(x - 1, y), r = read(x + 1, y);
            const t = read(x, y - 1), b = read(x, y + 1);
            if (!l.valid || !r.valid || !t.valid || !b.valid || !read(x, y).valid)
                continue;
            const dx = (r.value - l.value) * 0.5;
            const dy = (b.value - t.value) * 0.5;
            const magnitude = sqrt(dx * dx + dy * dy);
            if (!isFinite(magnitude))
                continue;
            ++count;
            detected += magnitude >= 0.05;
            if (feature == Feature.directedEdges)
                return values(dx, 0.5*dx + sqrt(0.75)*dy, -0.5*dx + sqrt(0.75)*dy);
            const angle = (atan2(dy, dx) + PI) % PI;
            const sector = cast(size_t)(angle * 3 / PI + 0.5) % 3;
            sums[sector] += magnitude;
        }
    if (count < 13)
        return Value.init;
    if (feature == Feature.edgeDensity)
        return values(detected / cast(double)count);
    const sum = sums[0] + sums[1] + sums[2];
    return sum == 0 ? values(0) : values(sums[0] / sum, sums[1] / sum, sums[2] / sum);
}

private struct GaborKernel
{
    int radius;
    double angle, scale;
    double[81] realWeights, imaginaryWeights;
}

private immutable GaborKernel[8] kernels;

shared static this()
{
    GaborKernel[8] prepared;
    foreach (i, ref kernel; prepared)
    {
        const int wavelength = i < 4 ? 2 : 4;
        const double theta = (i % 4) * PI / 4;
        kernel.radius = wavelength;
        kernel.angle = theta;
        kernel.scale = wavelength;
        const dx = cos(theta), dy = sin(theta);
        size_t index;
        double sum = 0;
        foreach (y; -wavelength .. wavelength + 1)
            foreach (x; -wavelength .. wavelength + 1)
            {
                const weight = exp(-(x*x + y*y) / (0.5 * wavelength * wavelength));
                const phase = 2 * PI * (x*dx + y*dy) / wavelength;
                kernel.realWeights[index] = weight * cos(phase);
                kernel.imaginaryWeights[index++] = weight * sin(phase);
                sum += weight;
            }
        foreach (j; 0 .. index)
        {
            kernel.realWeights[j] /= sum;
            kernel.imaginaryWeights[j] /= sum;
        }
    }
    kernels = prepared;
}

private Value lines(Feature feature, scope ReadPoint read)
{
    // Use complete support so strengths from different directions and scales
    // are comparable. The declared halo includes the largest support.
    const radius = cast(int)structureHalo(feature);
    foreach (y; -radius .. radius + 1)
        foreach (x; -radius .. radius + 1)
            if (!read(x, y).valid)
                return Value.init;

    double best = 0, angle = 0, scale = 0;
    const center = read(0, 0).value;
    if (feature == Feature.gabor ||
        (feature >= Feature.gaborFine0 && feature <= Feature.gaborCoarse135))
    {
        const first = feature == Feature.gabor ? 0 : feature - Feature.gaborFine0;
        const end = feature == Feature.gabor ? kernels.length : first + 1;
        foreach (ref kernel; kernels[first .. end])
        {
            double realPart = 0, imaginaryPart = 0;
            size_t index;
            foreach (y; -kernel.radius .. kernel.radius + 1)
                foreach (x; -kernel.radius .. kernel.radius + 1)
                {
                    const delta = read(x, y).value - center;
                    realPart += delta * kernel.realWeights[index];
                    imaginaryPart += delta * kernel.imaginaryWeights[index++];
                }
            const response = sqrt(realPart*realPart + imaginaryPart*imaginaryPart);
            if (response > best || end == first + 1)
            {
                best = response;
                angle = kernel.angle;
                scale = kernel.scale;
            }
        }
    }
    else
    {
        foreach (distance; 1 .. 4)
            foreach (i, direction; directions)
            {
                const dx = direction[0], dy = direction[1];
                const nx = -dy * distance, ny = dx * distance;
                double response = double.infinity;
                const extent = feature == Feature.lineResponse ? 1 : 0;
                foreach (along; -extent .. extent + 1)
                {
                    const x = dx * along, y = dy * along;
                    const ridge = read(x, y).value -
                        (0.5 * read(x + nx, y + ny).value + 0.5 * read(x - nx, y - ny).value);
                    response = min(response, ridge);
                }
                if (response > best)
                {
                    best = response;
                    angle = i * PI / 4;
                    scale = distance;
                }
            }
    }
    return values(best, angle, scale, best > 0);
}

private Point extremum(bool maximum, int x, int y, int radius,
    scope ReadPoint read)
{
    double result = maximum ? -double.infinity : double.infinity;
    foreach (j; -radius .. radius + 1)
        foreach (i; -radius .. radius + 1)
        {
            const point = read(x + i, y + j);
            if (!point.valid)
                return Point.init;
            result = maximum ? max(result, point.value) : min(result, point.value);
        }
    return Point(result, true);
}

// Best bottleneck for paths starting at the center, by number of steps.
// Each step progresses on the primary axis and may move one pixel laterally.
private double[7] pathHalf(bool closing, bool vertical, int direction, scope ReadPoint read)
{
    const missing = closing ? double.infinity : -double.infinity;
    double[13] current, next;
    current[] = missing;
    current[6] = read(0, 0).value;
    double[7] best;
    best[0] = current[6];
    foreach (distance; 1 .. 7)
    {
        next[] = missing;
        best[distance] = missing;
        foreach (lateral; -distance .. distance + 1)
        {
            const point = vertical ? read(lateral, direction * distance) :
                read(direction * distance, lateral);
            if (!point.valid)
                continue;
            double predecessor = missing;
            foreach (step; -1 .. 2)
            {
                const previous = lateral + step;
                if (previous > -distance && previous < distance)
                    predecessor = closing ? min(predecessor, current[6 + previous]) :
                        max(predecessor, current[6 + previous]);
            }
            const value = closing ? max(point.value, predecessor) : min(point.value, predecessor);
            next[6 + lateral] = value;
            best[distance] = closing ? min(best[distance], value) : max(best[distance], value);
        }
        current[] = next[];
    }
    return best;
}

private Value pathMorphology(bool closing, scope ReadPoint read)
{
    double best = closing ? double.infinity : -double.infinity;
    foreach (vertical; [false, true])
    {
        const before = pathHalf(closing, vertical, -1, read);
        const after = pathHalf(closing, vertical, 1, read);
        foreach (steps; 0 .. 7)
        {
            const value = closing ? max(before[steps], after[6 - steps]) :
                min(before[steps], after[6 - steps]);
            best = closing ? min(best, value) : max(best, value);
        }
    }
    return values(best);
}

private Point lineExtremum(bool maximum, int x, int y, int[2] direction, scope ReadPoint read)
{
    double result = maximum ? -double.infinity : double.infinity;
    foreach (i; -1 .. 2)
    {
        const point = read(x + i * direction[0], y + i * direction[1]);
        if (!point.valid)
            return Point.init;
        result = maximum ? max(result, point.value) : min(result, point.value);
    }
    return Point(result, true);
}

private Value morphology(Feature feature, scope ReadPoint read)
{
    const center = read(0, 0);
    if (feature == Feature.directedOpening || feature == Feature.directedClosing)
    {
        const close = feature == Feature.directedClosing;
        double[3] response;
        immutable int[2][3] axes = [[1, 0], [0, 1], [1, 1]];
        foreach (i, axis; axes)
        {
            const point = lineExtremum(!close, 0, 0, axis,
                (int x, int y) => lineExtremum(close, x, y, axis, read));
            if (!point.valid)
                return Value.init;
            response[i] = point.value;
        }
        return values(response[0], response[1], response[2]);
    }
    if (feature == Feature.erosion || feature == Feature.dilation)
    {
        const point = extremum(feature == Feature.dilation, 0, 0, 1, read);
        return point.valid ? values(point.value) : Value.init;
    }
    if (feature == Feature.pathOpening || feature == Feature.pathClosing)
        return pathMorphology(feature == Feature.pathClosing, read);
    assert(0, "Square compound morphology uses the tile kernel");
}

package int squareMorphologyRadius(Feature feature)
{
    switch (feature)
    {
        case Feature.openingProfile, Feature.closingProfile:
            return 3;
        case Feature.opening, Feature.closing, Feature.topHat, Feature.bottomHat:
            return 1;
        default:
            return 0;
    }
}

private Point reduceLine(bool maximum, scope const(Point)[] points,
    size_t start, size_t stride, int radius)
{
    double result = maximum ? -double.infinity : double.infinity;
    foreach (i; 0 .. 2 * radius + 1)
    {
        const point = points[start + i * stride];
        if (!point.valid)
            return Point.init;
        result = maximum ? max(result, point.value) : min(result, point.value);
    }
    return Point(result, true);
}

package void evaluateSquareMorphology(Feature feature, int width, int height,
    scope ReadPoint read, scope Point[] rows, scope Point[] intermediate,
    scope Value[] output)
{
    const closing = feature == Feature.closing || feature == Feature.bottomHat ||
        feature == Feature.closingProfile;
    const maxRadius = squareMorphologyRadius(feature);
    output[] = Value([0, 0, 0], true, false);

    foreach (radius; 1 .. maxRadius + 1)
    {
        const wide = width + 2 * radius;
        const tall = height + 2 * radius;
        // First horizontal pass includes the rows needed by both vertical
        // passes. Source-edge extension happens only in the reader.
        foreach (y; 0 .. height + 4 * radius)
            foreach (x; 0 .. wide)
            {
                double extrema = closing ? -double.infinity : double.infinity;
                bool valid = true;
                foreach (dx; 0 .. 2 * radius + 1)
                {
                    const point = read(x + dx - 2 * radius, y - 2 * radius);
                    if (!point.valid)
                    {
                        valid = false;
                        break;
                    }
                    extrema = closing ? max(extrema, point.value) : min(extrema, point.value);
                }
                rows[y * wide + x] = Point(extrema, valid);
            }

        foreach (y; 0 .. tall)
            foreach (x; 0 .. wide)
                intermediate[y * wide + x] = reduceLine(closing, rows, y * wide + x, wide, radius);

        foreach (y; 0 .. tall)
            foreach (x; 0 .. width)
                rows[y * width + x] = reduceLine(!closing, intermediate, y * wide + x, 1, radius);

        foreach (y; 0 .. height)
            foreach (x; 0 .. width)
            {
                auto value = &output[y * width + x];
                if (!value.valid)
                    continue;
                const point = reduceLine(!closing, rows, y * width + x, width, radius);
                if (!point.valid)
                {
                    *value = Value.init;
                    continue;
                }
                double response = point.value;
                if (feature == Feature.topHat)
                    response = read(x, y).value - response;
                else if (feature == Feature.bottomHat)
                    response -= read(x, y).value;
                if (isFinite(response))
                    value.channels[radius - 1] = response;
                else
                    *value = Value.init;
            }
    }
}
