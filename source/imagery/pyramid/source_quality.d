/++
 Explicit source-quality selection for a requested mosaic sample.

 The caller supplies quality metadata. This module does not inspect pixels,
 apply NoData rules or infer quality from source identity.
+/
module imagery.pyramid.source_quality;

/++
 Supply an explicit quality score and eligibility flag. `.init` is ineligible with a NaN score; quality is not inferred from pixels.
+/
struct SourceQuality
{
    /// Higher values are preferred.
    double score;
    /// True when the candidate is eligible for selection.
    bool eligible;
}

/// Select the first highest-scoring eligible source and preserve the previous result on failure.
@safe unittest
{
    SourceQuality[3] choices=[SourceQuality(0.5,true),SourceQuality(1,true),SourceQuality(1,true)];
    size_t selected=99;
    assert(trySelectSourceQuality(choices[],selected)==SourceQualityError.none && selected==1);
    choices[]=SourceQuality(0,false);
    assert(trySelectSourceQuality(choices[],selected)==SourceQualityError.noEligibleCandidate && selected==1);
}


/++
 Report quality-selection status. `.init` is notAttempted, not success.
+/
enum SourceQualityError : ubyte
{
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The operation completed successfully. +/
    none,
    /++ No candidates were supplied. +/
    emptyCandidates,
    /++ An eligible candidate has a nonfinite quality score. +/
    invalidScore,
    /++ No supplied candidate is eligible. +/
    noEligibleCandidate
}

/++
 Select the highest-scoring eligible candidate, retaining the first tie.

 Params:
  candidates = Ordered quality candidates; only eligible scores participate.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
SourceQualityError trySelectSourceQuality(
    scope const SourceQuality[] candidates,
    ref size_t published)
@safe pure nothrow @nogc
{
    if (candidates.length == 0)
        return SourceQualityError.emptyCandidates;

    bool found;
    size_t selected;
    double best;
    foreach (index, candidate; candidates)
    {
        if (candidate.eligible)
        {
            if (candidate.score != candidate.score ||
                candidate.score == double.infinity ||
                candidate.score == -double.infinity)
                return SourceQualityError.invalidScore;
            if (!found || candidate.score > best)
            {
                found = true;
                selected = index;
                best = candidate.score;
            }
        }
    }
    if (!found)
        return SourceQualityError.noEligibleCandidate;
    published = selected;
    return SourceQualityError.none;
}

@safe pure nothrow @nogc unittest
{
    SourceQuality[3] values = [
        SourceQuality(0.8, true), SourceQuality(1.0, true),
        SourceQuality(1.0, true)
    ];
    size_t selected = 99;
    assert(trySelectSourceQuality(values[], selected) ==
        SourceQualityError.none && selected == 1);
}

@safe pure nothrow @nogc unittest
{
    SourceQuality[2] values = [
        SourceQuality(10, false), SourceQuality(20, false)
    ];
    size_t selected = 77;
    assert(trySelectSourceQuality(values[], selected) ==
        SourceQualityError.noEligibleCandidate && selected == 77);
    SourceQuality[1] invalid = [SourceQuality(double.nan, true)];
    assert(trySelectSourceQuality(invalid[], selected) ==
        SourceQualityError.invalidScore && selected == 77);
}
