/++
 Explicit source-quality selection for a requested mosaic sample.

 The caller supplies quality metadata. This module does not inspect pixels,
 apply NoData rules or infer quality from source identity.
+/
module imagery.pyramid.source_quality;

struct SourceQuality
{
    /// Higher values are preferred.
    double score;
    /// True when the candidate is eligible for selection.
    bool eligible;
}

enum SourceQualityError : ubyte
{
    notAttempted,
    none,
    emptyCandidates,
    invalidScore,
    noEligibleCandidate
}

/** Select the highest-scoring eligible candidate, retaining the first tie. */
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
