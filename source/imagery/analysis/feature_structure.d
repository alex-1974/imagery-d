module imagery.analysis.feature_structure;

import imagery.analysis.feature_regions : Feature, Point, Value;
import imagery.analysis.feature_parameters : PathMorphologyParams, RidgeParams,
    LineResponseParams, GaborParams;
import std.algorithm : min, max;
import std.math : abs, atan2, cos, exp, isFinite, log2, PI, sin, sqrt;

@safe:

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

package struct StructuralOptions
{
    RidgeParams ridge;
    LineResponseParams line;
    GaborMember[] gabor;
}

package Value evaluateStructure(Read)(Feature feature, scope Read read,
    PathMorphologyParams paths = PathMorphologyParams.init,
    scope const StructuralOptions options = StructuralOptions.init)
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
            return lines(feature, read, options);
        default:
            return morphology(feature, read, paths);
    }
}

private size_t bin(double value)
{
    return min(15, cast(size_t)(16 * value));
}

private Value texture(Read)(Feature feature, scope Read read)
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

private Value edges(Read)(Feature feature, scope Read read)
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

package struct GaborMember
{
    int radius;
    double angle, scale;
    double[] realWeights, imaginaryWeights;
}

// Two allocations per nondefault request, reused for every pixel and tile.
package GaborMember[] prepareGabor(GaborParams parameters)
{
    import std.math : ceil;
    auto bank = new GaborMember[8];
    size_t count;
    foreach (w; parameters.wavelengths)
        count += 8 * (2 * cast(size_t)ceil(w * parameters.supportRatio) + 1)^^2;
    auto weights = new double[count];
    size_t offset;
    foreach (i, ref member; bank)
    {
        const wavelength = parameters.wavelengths[i/4];
        member.radius = cast(int)ceil(wavelength * parameters.supportRatio);
        member.angle = parameters.angles[i%4];
        member.scale = wavelength;
        const length = (2*member.radius+1)^^2;
        member.realWeights = weights[offset .. offset+length]; offset += length;
        member.imaginaryWeights = weights[offset .. offset+length]; offset += length;
        const dx = cos(member.angle), dy = sin(member.angle);
        const denominator = 2 * parameters.sigmaRatio * parameters.sigmaRatio * wavelength * wavelength;
        size_t index;
        double sum = 0;
        foreach (y; -member.radius .. member.radius+1)
            foreach (x; -member.radius .. member.radius+1)
            {
                const weight = exp(-(x*x+y*y)/denominator);
                const phase = 2*PI*(x*dx+y*dy)/wavelength;
                member.realWeights[index] = weight*cos(phase);
                member.imaginaryWeights[index++] = weight*sin(phase);
                sum += weight;
            }
        foreach (j; 0 .. index)
        {
            member.realWeights[j] /= sum;
            member.imaginaryWeights[j] /= sum;
        }
    }
    return bank;
}

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

private Value lines(Read)(Feature feature, scope Read read, scope const StructuralOptions options)
{
    // Use complete support so strengths from different directions and scales
    // are comparable. The declared halo includes the largest support.
    int radius = cast(int)structureHalo(feature);
    if (feature == Feature.ridge) radius = cast(int)options.ridge.lastRadius;
    else if (feature == Feature.lineResponse)
        radius = cast(int)(options.line.across.lastRadius + options.line.alongRadius);
    else if (options.gabor.length)
        radius = options.gabor[feature == Feature.gabor ? 7 : feature-Feature.gaborFine0].radius;
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
        void accumulate(Kernel)(scope const ref Kernel kernel)
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
        if (options.gabor.length)
            foreach (ref kernel; options.gabor[first .. end]) accumulate(kernel);
        else
            foreach (ref kernel; kernels[first .. end]) accumulate(kernel);
    }
    else
    {
        const across = feature == Feature.ridge ? options.ridge : options.line.across;
        foreach (distance; cast(int)across.firstRadius .. cast(int)across.lastRadius+1)
            foreach (i, direction; directions)
            {
                const dx = direction[0], dy = direction[1];
                const nx = -dy * distance, ny = dx * distance;
                double response = double.infinity;
                const extent = feature == Feature.lineResponse ? cast(int)options.line.alongRadius : 0;
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

private Point extremum(Read)(bool maximum, int x, int y, int radius,
    scope Read read)
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
private double[maxLength] pathHalf(Read, uint maxLength, uint maxStep)(bool closing, bool vertical, int direction, scope Read read,
    PathMorphologyParams parameters)
{
    const missing = closing ? double.infinity : -double.infinity;
    enum center=(maxLength-1)*maxStep;
    double[2*center+1] current, next;
    current[] = missing;
    current[center] = read(0, 0).value;
    double[maxLength] best;
    best[0] = current[center];
    const stepLimit=cast(int)parameters.lateralStep;
    const extent=cast(int)(parameters.length-1)*stepLimit;
    const first=center-extent, last=center+1+extent;
    foreach (distance; 1 .. cast(int)parameters.length)
    {
        next[first..last] = missing;
        best[distance] = missing;
        foreach (lateral; -distance*stepLimit .. distance*stepLimit + 1)
        {
            const point = vertical ? read(lateral, direction * distance) :
                read(direction * distance, lateral);
            if (!point.valid)
                continue;
            double predecessor = missing;
            foreach (step; -stepLimit .. stepLimit+1)
            {
                const previous = lateral + step;
                if (previous >= -(distance-1)*stepLimit && previous <= (distance-1)*stepLimit)
                    predecessor = closing ? min(predecessor, current[center + previous]) :
                        max(predecessor, current[center + previous]);
            }
            const value = closing ? max(point.value, predecessor) : min(point.value, predecessor);
            next[center + lateral] = value;
            best[distance] = closing ? min(best[distance], value) : max(best[distance], value);
        }
        current[first..last] = next[first..last];
    }
    return best;
}

private Value pathMorphology(Read)(bool closing, scope Read read, PathMorphologyParams parameters)
{
    if(parameters.length<=7 && parameters.lateralStep<=1)
        return pathMorphologyImpl!(Read,7,1)(closing,read,parameters);
    return pathMorphologyImpl!(Read,31,2)(closing,read,parameters);
}

private Value pathMorphologyImpl(Read, uint maxLength, uint maxStep)(bool closing, scope Read read, PathMorphologyParams parameters)
{
    double best = closing ? double.infinity : -double.infinity;
    foreach (vertical; [false, true])
    {
        const before = pathHalf!(Read,maxLength,maxStep)(closing, vertical, -1, read, parameters);
        const after = pathHalf!(Read,maxLength,maxStep)(closing, vertical, 1, read, parameters);
        foreach (steps; 0 .. parameters.length)
        {
            const value = closing ? max(before[steps], after[parameters.length-1 - steps]) :
                min(before[steps], after[parameters.length-1 - steps]);
            best = closing ? min(best, value) : max(best, value);
        }
    }
    return values(best);
}

private Point lineExtremum(Read)(bool maximum, int x, int y, int[2] direction, scope Read read)
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

private Value morphology(Read)(Feature feature, scope Read read, PathMorphologyParams parameters)
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
        return pathMorphology(feature == Feature.pathClosing, read, parameters);
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

package void evaluateSquareMorphology(Read)(Feature feature, int width, int height,
    scope Read read, scope Point[] rows, scope Point[] intermediate,
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
