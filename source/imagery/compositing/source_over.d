/++ Explicit alpha source-over compositing contract. +/
module imagery.compositing.source_over;

import std.math : isFinite;

enum AlphaAssociation : ubyte { straight, premultiplied }
enum SourceOverError : ubyte { none, invalidParameters, nonFiniteSample }

struct RgbaNormalized
{
    double r, g, b, a;
}

private bool inUnit(double value) @safe pure nothrow @nogc
{
    return isFinite(value) && value >= 0.0 && value <= 1.0;
}

/++ Composite `source` over `destination` without implicit association changes. +/
SourceOverError trySourceOver(
    RgbaNormalized source,
    RgbaNormalized destination,
    AlphaAssociation association,
    out RgbaNormalized result)
@safe pure nothrow @nogc
{
    if (!inUnit(source.a) || !inUnit(destination.a))
        return SourceOverError.invalidParameters;
    if (!inUnit(source.r) || !inUnit(source.g) || !inUnit(source.b) ||
        !inUnit(destination.r) || !inUnit(destination.g) || !inUnit(destination.b))
        return SourceOverError.nonFiniteSample;
    const inverse = 1.0 - source.a;
    const outA = source.a + destination.a * inverse;
    if (association == AlphaAssociation.premultiplied)
    {
        result = RgbaNormalized(
            source.r + destination.r * inverse,
            source.g + destination.g * inverse,
            source.b + destination.b * inverse, outA);
    }
    else
    {
        if (outA == 0.0) { result = RgbaNormalized(0, 0, 0, 0); return SourceOverError.none; }
        result = RgbaNormalized(
            (source.r * source.a + destination.r * destination.a * inverse) / outA,
            (source.g * source.a + destination.g * destination.a * inverse) / outA,
            (source.b * source.a + destination.b * destination.a * inverse) / outA, outA);
    }
    return SourceOverError.none;
}

unittest
{
    RgbaNormalized result;
    assert(trySourceOver(RgbaNormalized(1, 0, 0, 1),
        RgbaNormalized(0, 0, 1, 1), AlphaAssociation.straight, result) == SourceOverError.none);
    assert(result.r == 1 && result.b == 0 && result.a == 1);
    assert(trySourceOver(RgbaNormalized(1, 1, 1, 0),
        RgbaNormalized(0.2, 0.3, 0.4, 0), AlphaAssociation.straight, result) == SourceOverError.none);
    assert(result.a == 0);
}
