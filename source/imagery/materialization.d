/**
 * Compile-time materialization policies.
 *
 * This module contains only descriptors and validation. It deliberately does
 * not depend on imageio-d, raster-d or color-d, so policies can be used by
 * direct-data consumers as well as by the I/O adapter.
 */
module imagery.materialization;

import std.meta : AliasSeq;

/// Plane interpolation policy.
struct NativePlanesGeometry
{
    enum kind = "native";
}

/// Plane interpolation policy.
struct NearestUpsampling
{
    enum kind = "nearest";
}

/// Bilinear interpolation policy descriptor. Execution is admitted separately.
struct BilinearUpsampling
{
    enum kind = "bilinear";
}

/// Preserve floating-point output without clipping.
struct LinearFloatOutput(T = float)
if (is(T == float) || is(T == double))
{
    alias Sample = T;
    enum clip = false;
}

/// Explicit bounded integer output policy.
struct ClippedUbyteOutput
{
    alias Sample = ubyte;
    enum clip = true;
}

/// A generic component-model descriptor.
struct ComponentModel(size_t ComponentCount, alias Roles = AliasSeq!())
{
    enum componentCount = ComponentCount;
    alias roles = Roles;
}

/// A YCbCr model whose colour mathematics is supplied by color-d.
struct YCbCrModel(alias ColorPolicy, size_t Y, size_t Cb, size_t Cr)
{
    alias colorPolicy = ColorPolicy;
    enum yPlane = Y;
    enum cbPlane = Cb;
    enum crPlane = Cr;
    enum componentCount = 3;
}

/// A generic compile-time materialization specification.
struct MaterializationSpec(alias Model, alias Geometry, alias Output)
{
    alias model = Model;
    alias geometry = Geometry;
    alias output = Output;
}

/// Structural validation for a component model.
enum bool isImageModel(T) = __traits(compiles, {
    enum count = T.componentCount;
}) && T.componentCount != 0;

/// Structural validation for a geometry policy.
enum bool isGeometryPolicy(T) = __traits(compiles, {
    enum value = T.kind;
});

/// Structural validation for an output policy.
enum bool isOutputPolicy(T) = __traits(compiles, {
    alias SampleType = T.Sample;
    enum clipping = T.clip;
});

/// Validated compile-time materialization configuration.
struct ValidatedMaterializationSpec(alias Model, alias Geometry, alias Output)
if (isImageModel!Model && isGeometryPolicy!Geometry && isOutputPolicy!Output)
{
    alias model = Model;
    alias geometry = Geometry;
    alias output = Output;
}

alias Bt601VideoModel(alias Policy) = YCbCrModel!(Policy, 0, 1, 2);

unittest
{
    alias Model = ComponentModel!3;
    alias Spec = ValidatedMaterializationSpec!(
        Model, NearestUpsampling, LinearFloatOutput!double);
    static assert(isImageModel!Model);
    static assert(isGeometryPolicy!NearestUpsampling);
    static assert(isOutputPolicy!(LinearFloatOutput!double));
    static assert(is(Spec.output.Sample == double));
    static assert(!__traits(compiles, ValidatedMaterializationSpec!(
        Model, NearestUpsampling, int)));
}

unittest
{
    alias Model = Bt601VideoModel!int;
    static assert(Model.componentCount == 3);
    static assert(Model.yPlane == 0);
    static assert(Model.cbPlane == 1);
    static assert(Model.crPlane == 2);
}
