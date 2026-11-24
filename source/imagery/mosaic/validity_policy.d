/++ Explicit mosaic quality weights and validity/NoData decisions. +/
module imagery.mosaic.validity_policy;

import std.math : isFinite, log, exp;

/// Caller-supplied quality factors. imagery-d assigns no cloud/sensor ranking.
/// Coverage/quality are in [0,1]; preference is finite and nonnegative.
/// `.init` is an excluded contributor with neutral factors. Alpha is separate:
/// a valid transparent sample is not NoData and may retain policy weight.
struct QualityContributor
{
    /// False excludes a missing/NoData sample without inspecting pixel bytes.
    bool valid;
    /// Relative covered support; not an inferred union opacity/coverage.
    double coverage=1;
    /// Caller-defined quality, including any cloud/haze/acquisition recipe.
    double quality=1;
    /// Relative source preference; common rescaling preserves the policy.
    double preference=1;
}

/// Default records are excluded; finite neutral factors still validate.
@safe unittest
{
    const contributor=QualityContributor.init;
    assert(!contributor.valid && contributor.coverage==1 && contributor.quality==1 && contributor.preference==1);
}

private double productWeight(QualityContributor c) @safe pure nothrow @nogc
{
    return !c.valid || c.coverage==0 || c.quality==0 || c.preference==0 ? 0 :
        (c.coverage*c.quality)*c.preference;
}

// Shared schema check; validity never exempts malformed metadata.
package(imagery) bool validQualityContributor(QualityContributor c) @safe pure nothrow @nogc
{
    return isFinite(c.coverage) && c.coverage>=0 && c.coverage<=1 &&
        isFinite(c.quality) && c.quality>=0 && c.quality<=1 &&
        isFinite(c.preference) && c.preference>=0;
}

private void addWeight(double value,ref double total,ref double correction) @safe pure nothrow @nogc
{
    const adjusted=value-correction;
    const next=total+adjusted;
    correction=(next-total)-adjusted;
    total=next;
}

private double logWeight(QualityContributor c) @safe pure nothrow @nogc
{
    if(!c.valid || c.coverage==0 || c.quality==0 || c.preference==0)
        return -double.infinity;
    return log(c.coverage)+log(c.quality)+log(c.preference);
}

/++
 Normalize an arbitrary contributor set. coverage/quality are in [0,1],
   preference is finite and nonnegative. Records with valid=false get zero
   weight; malformed factors reject the complete call, even on such records.
   No usable positive contributor returns false and preserves destination.
   All factors are checked before writes, including excluded contributors.
   Destination needs at least contributors.length elements and must be
   disjoint from the contributor records. No allocation occurs.
   Normal products use scaled compensated normalization. Subnormal or lost
   intermediate products use logarithmic range reduction with the same sum.
   A normalized weight below float64 range can round to zero. Only the first
   contributors.length destination entries are written. Factors and pixel
   alpha/association have separate contracts; this function blends no colors.

  Params:
   contributors = Quality and validity records in contributor order.
   destination = Caller-owned output storage, or the destination pixel/raster for compositing.

 Returns: True when weights were produced, or false before writes for invalid contributors or insufficient destination capacity.
+/
bool tryQualityWeights(scope const(QualityContributor)[] contributors,
    scope double[] destination) @safe pure nothrow @nogc
{
    if (!contributors.length || destination.length<contributors.length) return false;
    double largest=0;
    bool logarithmic;
    foreach(c;contributors)
    {
        if (!validQualityContributor(c)) return false;
        if(!logarithmic && c.valid && c.coverage!=0 && c.quality!=0 && c.preference!=0) {
            const base=c.coverage*c.quality;
            const weight=base*c.preference;
            // A later preference can recover a tiny coverage*quality product.
            // Do not accept already rounded subnormal intermediates as exact.
            logarithmic|=base<double.min_normal || weight<double.min_normal || !isFinite(weight);
            if(weight>largest)largest=weight;
        }
    }
    if(logarithmic)return logarithmicWeights(contributors,destination);
    if(largest==0)return false;
    double total=0,correction=0;
    foreach(c;contributors)addWeight(productWeight(c)/largest,total,correction);
    foreach(i,c;contributors)destination[i]=(productWeight(c)/largest)/total;
    return true;
}

// The caller has validated every factor before entering the complete fallback.
private bool logarithmicWeights(scope const(QualityContributor)[] contributors,
    scope double[] destination) @safe pure nothrow @nogc
{
    double largest=-double.infinity;
    foreach(c;contributors)if(c.valid) {
        const weight=logWeight(c);
        if(weight>largest)largest=weight;
    }
    if(largest == -double.infinity)return false;
    double total=0,correction=0;
    foreach(c;contributors)if(c.valid)addWeight(exp(logWeight(c)-largest),total,correction);
    foreach(i,c;contributors)
        destination[i]=c.valid?exp(logWeight(c)-largest)/total:0;
    return true;
}

/// Products that lose intermediate range retain their relative influence.
@safe unittest
{
    QualityContributor[2] contributors=[QualityContributor(true,1e-160,1e-160,1e308),
        QualityContributor(true,1e-12,1,1)];
    double[2] weights;
    assert(tryQualityWeights(contributors[],weights[]));
    assert(weights[0]>.499999999999 && weights[0]<.500000000001);
    auto many=new QualityContributor[257];many[]=QualityContributor(true,1,1,1e-16);
    many[0].preference=1;auto result=new double[many.length];
    assert(tryQualityWeights(many,result));
    assert(result[0]<1 && (1-result[0])>2.5e-14 && (1-result[0])<2.6e-14);
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

/// `.init` means notAttempted, never success. bothInvalid publishes no decision.
enum ValidityPolicyError : ubyte
{
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The operation completed successfully. +/
    none,
    /++ Neither contributor is valid. +/
    bothInvalid
}

/// `.init` has outputValid=false; use the returned status before consuming it.
struct ValidityDecision
{
    /// True when at least one source can provide the output sample.
    bool outputValid;
    /// Effective blend weight: zero selects A, 255 selects B.
    ubyte weight;
}

/++
 Resolve two source-validity states without inferring NoData from pixel bytes.

    If both sources are valid, the caller's blend weight is preserved. If only
    one is valid, that source wins. If neither is valid, bothInvalid is returned
    without replacing published, which may still contain a previous valid decision.

 Params:
  validA = Validity of the first contributor, independently of alpha.
  validB = Validity of the second contributor, independently of alpha.
  requestedWeight = Requested weight of the first contributor in [0,1].
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
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
