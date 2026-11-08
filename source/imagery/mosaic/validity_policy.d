/++ Explicit validity/NoData policy for two-source mosaic operations. +/
module imagery.mosaic.validity_policy;

enum ValidityPolicyError : ubyte
{
    notAttempted,
    none,
    bothInvalid
}

struct ValidityDecision
{
    /// True when at least one source can provide the output sample.
    bool outputValid;
    /// Effective blend weight: zero selects A, 255 selects B.
    ubyte weight;
}

/**
 Resolve two source-validity states without inferring NoData from pixel bytes.

 If both sources are valid, the caller's blend weight is preserved. If only
 one is valid, that source wins. If neither is valid, outputValid is false
 and the supplied publication value is left unchanged.
 */
ValidityPolicyError tryResolveValidity(
    bool validA, bool validB, ubyte requestedWeight,
    ref ValidityDecision published)
@safe pure nothrow @nogc
{
    if (!validA && !validB)
        return ValidityPolicyError.bothInvalid;
    if (!validA)
    {
        published = ValidityDecision(true, 255);
        return ValidityPolicyError.none;
    }
    if (!validB)
    {
        published = ValidityDecision(true, 0);
        return ValidityPolicyError.none;
    }
    published = ValidityDecision(true, requestedWeight);
    return ValidityPolicyError.none;
}

@safe pure nothrow @nogc unittest
{
    ValidityDecision d = ValidityDecision(false, 17);
    assert(tryResolveValidity(true, true, 91, d) ==
        ValidityPolicyError.none && d == ValidityDecision(true, 91));
    assert(tryResolveValidity(false, true, 91, d) ==
        ValidityPolicyError.none && d == ValidityDecision(true, 255));
    assert(tryResolveValidity(true, false, 91, d) ==
        ValidityPolicyError.none && d == ValidityDecision(true, 0));
    const sentinel = d;
    assert(tryResolveValidity(false, false, 91, d) ==
        ValidityPolicyError.bothInvalid && d == sentinel);
}
