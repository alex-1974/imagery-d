module app;
import imagery;
import std.stdio : writeln;
void main()
{
    size_t checks;
    foreach (mode; [BlendMode.multiply, BlendMode.screen, BlendMode.darken, BlendMode.lighten])
    foreach (s; 0 .. 256)
    foreach (d; 0 .. 256)
    {
        const source = cast(double)s / 255.0;
        const destination = cast(double)d / 255.0;
        const value = blendChannel(source, destination, mode);
        assert(value >= 0.0 && value <= 1.0);
        ++checks;
    }
    RgbaNormalized result; bool valid;
    assert(tryValidityAwareSourceOver(RgbaNormalized(1, 0, 0, 1), false,
        RgbaNormalized(0, 1, 0, 1), true, AlphaAssociation.straight, result, valid) == SourceOverError.none && valid && result.g == 1);
    assert(tryValidityAwareSourceOver(RgbaNormalized.init, false, RgbaNormalized.init, false,
        AlphaAssociation.straight, result, valid) == SourceOverError.none && !valid);
    writeln("M3_BLEND_VALIDITY_QUALIFICATION=PASS;channel_checks:", checks,
        ";validity_cases:2");
}
