module imagery.presentation.exposure_curves;

import std.math : isFinite, pow;

struct Exposure
{
    double stops;
}

struct CurvePoint
{
    double x;
    double y;
}

enum ExposureCurvesError : ubyte { none, invalidParameters, nonFiniteSample }

bool tryExposure(double input, Exposure settings, out double output)
@safe pure nothrow @nogc
{
    if (!isFinite(settings.stops) || settings.stops < -32.0 || settings.stops > 32.0)
        return false;
    if (!isFinite(input)) return false;
    output = input * pow(2.0, settings.stops);
    if (output < 0.0) output = 0.0;
    if (output > 1.0) output = 1.0;
    return true;
}

ExposureCurvesError tryCurve(double input, scope const(CurvePoint)[] points,
    out double output)
@safe pure nothrow @nogc
{
    if (!isFinite(input) || points.length < 2) return ExposureCurvesError.invalidParameters;
    foreach (i, point; points)
    {
        if (!isFinite(point.x) || !isFinite(point.y) || point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1 ||
            (i != 0 && point.x <= points[i - 1].x)) return ExposureCurvesError.invalidParameters;
    }
    if (input <= points[0].x) { output = points[0].y; return ExposureCurvesError.none; }
    foreach (i; 1 .. points.length)
        if (input <= points[i].x)
        {
            const span = points[i].x - points[i - 1].x;
            const t = (input - points[i - 1].x) / span;
            output = points[i - 1].y + t * (points[i].y - points[i - 1].y);
            return ExposureCurvesError.none;
        }
    output = points[$ - 1].y;
    return ExposureCurvesError.none;
}

unittest
{
    double value;
    assert(tryExposure(0.25, Exposure(1), value) && value == 0.5);
    auto identity = [CurvePoint(0, 0), CurvePoint(1, 1)];
    assert(tryCurve(0.25, identity, value) == ExposureCurvesError.none && value == 0.25);
    auto lift = [CurvePoint(0, 0.1), CurvePoint(1, 1)];
    assert(tryCurve(0, lift, value) == ExposureCurvesError.none && value == 0.1);
}
