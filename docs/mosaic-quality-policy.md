# Explicit mosaic quality policy

This #147 candidate defines contributor weights independently of registration,
resampling and color blending. `imagery.mosaic.validity_policy` normalizes any
number of caller-supplied `QualityContributor` records. The integrated mosaic
consumer in #148 now has an opt-in [registered RGBA8 candidate](multiresolution-mosaic.md),
which applies this policy after overview selection and premultiplied resampling.

## Constructing a contributor

Supply independent validity, relative covered support, quality and preference:

```d
import imagery.mosaic.validity_policy;

auto contributor = QualityContributor(
    sampleValid, coveredFraction, qualityScore, sourcePreference);
```

Coverage and quality are finite in [0,1]; preference is finite and nonnegative.
NoData/missing input uses `valid=false`. Default records are excluded with
finite neutral factors, which are placeholders rather than observed quality.
Every factor is checked, including on excluded records. Unknown NaN factors
must not be hidden behind a false validity flag.

The consumer owns the recipe that maps cloud/haze/acquisition evidence to
quality. One possible versioned policy is:

```d
qualityScore = clearFraction * hazeTransmission * acquisitionConfidence;
```

All three scores are supplied by named, calibrated providers with the declared
range. A cloud probability can map to `clearFraction=1-cloudProbability` when
that is the selected consumer policy. Hard exclusions, nonlinear score maps
and source preferences are equally explicit alternatives. Multiplicative
policy scores do not assert statistical independence or physical source truth.
imagery-d assigns no sensor/provider ranking and derives no cloud score from
pixel brightness.

The effective mass is `coverage * quality * preference` for eligible records,
normalized across positive masses. Zero factors exclude influence. Common
positive preference scaling preserves the policy when inputs remain
representable. The implementation scales ordinary products and compensates
their sum; lost/subnormal intermediate products use logarithmic reduction.
The caller supplies output storage; evaluation is `@safe pure nothrow @nogc`.

If no positive mass exists, input factors are malformed, or storage is invalid,
the function returns false and preserves the destination. Do not consume old
weights as a successful result. The boolean does not distinguish these causes;
adapters validate provider data and record whether support is missing or
deliberately withheld by quality policy. Entries beyond contributor count are
untouched. Tiny normalized weights may round to zero in float64.

## Alpha and output validity

Alpha is a separate color/association contract. A valid transparent pixel and
a valid black pixel remain valid observations; neither is implicitly NoData.
Quality normalization does not multiply alpha into source eligibility.
Any opacity-dependent ranking must be a separately named consumer policy.

A qualified test consumer demonstrates a normalized linear premultiplied
mixture using color-d's `premultiply`/`unpremultiply`:

1. Obtain normalized quality weights.
2. Skip excluded/zero-weight records before reading their pixel data.
3. Validate contributing alpha. A zero-alpha sample contributes zero
   premultiplied color without reading undefined hidden RGB.
4. Accumulate weighted premultiplied channels and alpha, then unpremultiply.
5. Publish only after complete success, with validity separate from alpha.

Four sources illustrate the policy: opaque white, valid transparent color,
missing data with poisoned pixel fields, and half-transparent blue with half
quality. Factors yield weights .4/.4/0/.2 and straight linear RGBA
(.8,.8,1,.5). All-transparent valid inputs produce valid transparent black;
all excluded inputs produce no new result. The test also preserves opaque
black as valid data.

This is a conditional normalized mixture. Coverage controls relative support;
it does not determine the geometric union of partially covered footprints.
Target coverage comes from the geometry/resampling adapter. Ordered layer
compositing retains its source-over contract. The existing owned overlap API
still accepts two RGB8 sources and u8 weights; quantization/association and
an owned multi-source RGBA result are not silently added by this policy.

For the two-source validity helper, `bothInvalid` preserves the previous
`ValidityDecision`, which may still be valid. Use the returned status before
reading the decision; `.init` status is `notAttempted`.

## Provenance to retain with a weight field

Normalization is stateless and creates no cache/provenance owner. The consumer
records the complete inputs alongside any cached or persisted weight field:

| Evidence | Record |
|---|---|
| Source | Ordered identity/revision, band/encoding, grid/level and extent |
| Eligibility | Validity/NoData provider and mask revision, missing/withheld reason |
| Coverage | Sampling/geometry policy and coverage-plane revision |
| Quality | Cloud/haze/acquisition providers, model/recipe versions and plane revisions |
| Preference | Explicit source coefficients and policy version |
| Color | Transfer domain, alpha association and normalized-mixture/source-over policy |
| Reproduction | imagery/color library revisions, scalar representation and build identity when bit reproducibility matters |

The test recipe identifier is `normalized-premultiplied-mixture-v1`. A change
to provider, coefficient, grid, recipe or association invalidates cached
results even if source image bytes are unchanged. A source ID alone cannot
identify the weight field. No OSM class or application interpretation enters
the normalization kernel.

## Qualification

The feature-program consumer checks 100 cases against 2000-digit Decimal
products/normalization, with 1..257 contributors, random eligibility, ordinary
and extreme factors, recoverable intermediate underflow and maximum preference.
It retains permutation and common-scale laws, failure rollback, output tails,
zero GC allocation and the alpha/NoData recipe above. See the dated
[feature-program receipt](benchmarks/feature-program-2026-11-21.md) for observed
errors and native before/after measurements.
