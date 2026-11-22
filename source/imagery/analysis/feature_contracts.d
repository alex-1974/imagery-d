/++ Descriptors for the opt-in M6 analysis interface on develop. +/
module imagery.analysis.feature_contracts;

import imagery.analysis.feature_regions : Feature;

@safe:

enum FeatureAccess : ubyte { tile, globalReduction, fittedProfile, sourceCells }
enum FeatureCost : ubyte { low, neighborhood, intensive }
enum FeatureStorage : ubyte { float64, uint64Histogram }
enum FeatureUnit : ubyte { dimensionless, sourceScalar, sourcePerPixel, radians, pixels, bits, count }

struct FeatureChannel
{
    string name;
    FeatureUnit unit;
    double minimum = -double.infinity;
    double maximum = double.infinity;
}

/// Canonical, named fixed parameters. Fitted parameters live in the profile
/// in addition to this identifier. Value and validity travel separately.
package string fixedParameters(Feature feature)
{
    final switch (feature)
    {
        case Feature.luminance: return "transfer=sRGB;weights=0.2126,0.7152,0.0722";
        case Feature.oklab: return "transfer=sRGB;white=D65";
        case Feature.localStatistics, Feature.localNormalization, Feature.dynamicRange:
            return "window=7x7;minimum-valid=25;variance=population;border=clamp;windows=centered-welford-monotone-v2";
        case Feature.relativeDarkness:
            return "window=7x7;minimum-valid=25;border=clamp;windows=centered-welford-monotone-v2";
        case Feature.shadowCandidate:
            return "window=7x7;minimum-valid=25;luminance-ceiling=0.15;border=clamp;windows=centered-welford-monotone-v2";
        case Feature.gradient: return "stencil=Sobel3x3;scale=1/8;border=clamp";
        case Feature.edgeEvidence: return "stencil=Sobel3x3;scale=1/8;saturation=0.125;border=clamp";
        case Feature.distribution: return "bins=256;interval=[0,1];rank=nearest";
        case Feature.normalizedLuminance, Feature.exposureMatched:
            return "bins=256;rank=nearest;bounds=outer-bin-edges;clip=true";
        case Feature.clahe:
            return "cells=32x32;bins=256;clip-factor=2;grid=source;blend=bilinear";
        case Feature.gaussian:
            return "window=3x3;minimum-valid=5;weights=1,2,1;border=clamp";
        case Feature.box, Feature.median, Feature.noise:
            return "window=3x3;minimum-valid=5;border=clamp";
        case Feature.bilateral:
            return "window=3x3;minimum-valid=5;weights=1,2,1;sigma-range=0.1;border=clamp";
        case Feature.diffusion:
            return "stencil=cross;iterations=1;step=0.2;conductance=0.1;border=clamp";
        case Feature.laplacian, Feature.sharpness: return "stencil=cross;border=clamp";
        case Feature.clipping: return "encoded-channel-ceiling=255";
        case Feature.underexposure: return "linear-luminance-ceiling=0.01";
        case Feature.visibility: return "encoded-channel-ceiling=255;luminance-saturation=0.05";
        case Feature.entropy: return "window=7x7;bins=16;minimum-valid=25;border=clamp";
        case Feature.localBinaryPattern: return "radius=1;neighbors=8;northwest-first;comparison=ge;border=clamp";
        case Feature.cooccurrence:
            return "window=7x7;bins=16;offset=1,0;symmetric=true;minimum-pairs=21;border=clamp";
        case Feature.edgeDensity:
            return "window=5x5;stencil=central;minimum-valid=13;threshold=0.05;border=clamp";
        case Feature.directedEdges:
            return "stencil=central;angles-deg=0,60,120;border=clamp";
        case Feature.orientationHistogram:
            return "window=5x5;stencil=central;minimum-valid=13;angles-deg=0,60,120;border=clamp";
        case Feature.gabor: return "wavelengths=2,4;angles-deg=0,45,90,135;sigma=wavelength/2;aggregate=max;ties=first-wavelength-angle;border=clamp";
        case Feature.gaborFine0: return "wavelength=2;angle-deg=0;sigma=1;border=clamp";
        case Feature.gaborFine45: return "wavelength=2;angle-deg=45;sigma=1;border=clamp";
        case Feature.gaborFine90: return "wavelength=2;angle-deg=90;sigma=1;border=clamp";
        case Feature.gaborFine135: return "wavelength=2;angle-deg=135;sigma=1;border=clamp";
        case Feature.gaborCoarse0: return "wavelength=4;angle-deg=0;sigma=2;border=clamp";
        case Feature.gaborCoarse45: return "wavelength=4;angle-deg=45;sigma=2;border=clamp";
        case Feature.gaborCoarse90: return "wavelength=4;angle-deg=90;sigma=2;border=clamp";
        case Feature.gaborCoarse135: return "wavelength=4;angle-deg=135;sigma=2;border=clamp";
        case Feature.ridge: return "radii=1,2,3;angles-deg=0,45,90,135;along=1;across=opposite-radius;aggregate=max-positive;ties=first-radius-angle;border=clamp";
        case Feature.lineResponse: return "radii=1,2,3;angles-deg=0,45,90,135;along=3;across=opposite-radius;along-reduce=min;aggregate=max-positive;ties=first-radius-angle;border=clamp";
        case Feature.erosion, Feature.dilation, Feature.opening, Feature.closing,
             Feature.topHat, Feature.bottomHat: return "element=square;radius=1;border=clamp";
        case Feature.openingProfile, Feature.closingProfile: return "element=square;radii=1,2,3;border=clamp";
        case Feature.pathOpening, Feature.pathClosing:
            return "element=axis-monotonic-path;length=7;lateral-step=1;border=clamp";
        case Feature.directedOpening, Feature.directedClosing:
            return "element=line;length=3;axes=horizontal,vertical,southeast;border=clamp";
    }
}

package FeatureChannel[] describeChannels(Feature feature) pure
{
    alias U = FeatureUnit;
    switch (feature)
    {
        case Feature.luminance: return [FeatureChannel("sample", U.sourceScalar)];
        case Feature.oklab:
            return [FeatureChannel("lightness", U.dimensionless, 0, 1.000001),
                FeatureChannel("a", U.dimensionless), FeatureChannel("b", U.dimensionless)];
        case Feature.gradient:
            return [FeatureChannel("strength", U.sourcePerPixel, 0),
                FeatureChannel("orientation", U.radians, -3.141592653589793, 3.141592653589793)];
        case Feature.gabor, Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90,
             Feature.gaborFine135, Feature.gaborCoarse0, Feature.gaborCoarse45,
             Feature.gaborCoarse90, Feature.gaborCoarse135, Feature.ridge, Feature.lineResponse:
            return [FeatureChannel("strength", U.sourceScalar, 0),
                FeatureChannel("axial orientation", U.radians, 0, 3.141592653589793),
                FeatureChannel("scale", U.pixels, 0, 4)];
        case Feature.localStatistics:
            return [FeatureChannel("mean", U.sourceScalar),
                FeatureChannel("population standard deviation", U.sourceScalar, 0)];
        case Feature.entropy:
            return [FeatureChannel("entropy", U.bits, 0, 4)];
        case Feature.localBinaryPattern:
            return [FeatureChannel("code", U.dimensionless, 0, 255)];
        case Feature.cooccurrence:
            return [FeatureChannel("contrast", U.dimensionless, 0, 225),
                FeatureChannel("energy", U.dimensionless, 0, 1),
                FeatureChannel("homogeneity", U.dimensionless, 0, 1)];
        case Feature.directedEdges:
            return [FeatureChannel("0 degrees", U.sourcePerPixel),
                FeatureChannel("60 degrees", U.sourcePerPixel),
                FeatureChannel("120 degrees", U.sourcePerPixel)];
        case Feature.orientationHistogram:
            return [FeatureChannel("0 degrees", U.dimensionless, 0, 1),
                FeatureChannel("60 degrees", U.dimensionless, 0, 1),
                FeatureChannel("120 degrees", U.dimensionless, 0, 1)];
        case Feature.openingProfile, Feature.closingProfile:
            return [FeatureChannel("radius 1", U.sourceScalar),
                FeatureChannel("radius 2", U.sourceScalar),
                FeatureChannel("radius 3", U.sourceScalar)];
        case Feature.directedOpening, Feature.directedClosing:
            return [FeatureChannel("horizontal", U.sourceScalar),
                FeatureChannel("vertical", U.sourceScalar),
                FeatureChannel("southeast", U.sourceScalar)];
        case Feature.distribution:
            return [FeatureChannel("bin count", U.count, 0)];
        case Feature.normalizedLuminance, Feature.exposureMatched, Feature.clahe,
             Feature.clipping, Feature.underexposure, Feature.edgeDensity, Feature.relativeDarkness,
             Feature.shadowCandidate, Feature.visibility, Feature.edgeEvidence:
            return [FeatureChannel("response", U.dimensionless, 0, 1)];
        case Feature.localNormalization:
            return [FeatureChannel("standardized response", U.dimensionless)];
        case Feature.sharpness, Feature.noise, Feature.dynamicRange:
            return [FeatureChannel("response", U.sourceScalar, 0)];
        default:
            return [FeatureChannel("response", U.sourceScalar)];
    }
}

package string featureValidity(Feature feature)
{
    switch (feature)
    {
        case Feature.distribution:
            return "valid RGB samples only; an empty extent has no percentiles or moments";
        case Feature.normalizedLuminance, Feature.exposureMatched:
            return "usable fitted profiles required; preserve center validity";
        case Feature.clahe:
            return "valid center and at least one nonempty contributing cell";
        case Feature.localStatistics, Feature.localNormalization, Feature.dynamicRange,
             Feature.relativeDarkness, Feature.shadowCandidate, Feature.entropy:
            return "valid center and at least 25 valid positions";
        case Feature.gaussian, Feature.box, Feature.median, Feature.bilateral, Feature.noise:
            return "valid center and at least five valid positions";
        case Feature.cooccurrence:
            return "valid center and at least 21 valid horizontal pairs";
        case Feature.edgeDensity, Feature.orientationHistogram:
            return "valid center and at least 13 complete central-difference stencils";
        case Feature.luminance, Feature.oklab, Feature.underexposure, Feature.clipping, Feature.visibility:
            return "valid center";
        case Feature.pathOpening, Feature.pathClosing:
            return "valid center and at least one complete path";
        case Feature.gradient, Feature.gabor, Feature.gaborFine0, Feature.gaborFine45,
             Feature.gaborFine90, Feature.gaborFine135, Feature.gaborCoarse0, Feature.gaborCoarse45,
             Feature.gaborCoarse90, Feature.gaborCoarse135, Feature.ridge, Feature.lineResponse:
            return "complete support; zero strength leaves orientation undefined";
        default:
            return "complete valid stencil or structuring-element support";
    }
}
