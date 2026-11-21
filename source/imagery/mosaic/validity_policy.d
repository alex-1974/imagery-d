/++ Explicit validity/NoData policy for two-source mosaic operations. +/
module imagery.mosaic.validity_policy;

import std.math : isFinite, log, exp;

/// Caller-supplied quality factors. imagery-d assigns no cloud/sensor ranking.
/// Coverage, quality and preference are independent nonnegative factors.
struct QualityContributor
{
    bool valid;
    double coverage=1;
    double quality=1;
    double preference=1;
}

private double logWeight(QualityContributor c) @safe pure nothrow @nogc
{
    if(!c.valid || c.coverage==0 || c.quality==0 || c.preference==0)
        return -double.infinity;
    return log(c.coverage)+log(c.quality)+log(c.preference);
}

/// Normalize an arbitrary contributor set. coverage/quality are in [0,1],
/// preference is finite and nonnegative. Invalid contributors get zero weight.
/// No usable positive contributor returns false and preserves destination.
/// All factors are checked before writes, including excluded contributors.
/// Destination needs at least contributors.length elements and must be
/// disjoint from the contributor records. No allocation occurs.
bool tryQualityWeights(scope const(QualityContributor)[] contributors,
    scope double[] destination) @safe pure nothrow @nogc
{
    if (!contributors.length || destination.length<contributors.length) return false;
    double largest=-double.infinity;
    foreach(c;contributors)
    {
        if (!isFinite(c.coverage) || c.coverage<0 || c.coverage>1 ||
            !isFinite(c.quality) || c.quality<0 || c.quality>1 ||
            !isFinite(c.preference) || c.preference<0) return false;
        if(c.valid) {
            const weight=logWeight(c);
            if(weight>largest)largest=weight;
        }
    }
    if(largest == -double.infinity)return false;
    double total=0;
    foreach(c;contributors) if(c.valid)total+=exp(logWeight(c)-largest);
    foreach(i,c;contributors)
        destination[i]=c.valid?exp(logWeight(c)-largest)/total:0;
    return true;
}

/// Missing sources get zero influence; relative qualities remain proportional.
unittest
{
    QualityContributor[3] sources=[QualityContributor(true,1,1,1),
        QualityContributor(true,1,0.5,1),QualityContributor(false,1,1,1)];
    double[3] weights;
    assert(tryQualityWeights(sources[],weights[]));
    assert(weights[0]==2.0/3 && weights[1]==1.0/3 && weights[2]==0);
    const before=weights;
    sources[1].coverage=double.nan;
    assert(!tryQualityWeights(sources[],weights[]) && weights==before);
    sources[] = QualityContributor(true,1e-300,1e-300,1);
    assert(tryQualityWeights(sources[],weights[]));
    assert(weights[0]==1.0/3 && weights[1]==1.0/3 && weights[2]==1.0/3);
}

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
