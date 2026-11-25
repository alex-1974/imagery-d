/++
Choose how decoded image components become processing inputs. Combine a
component model, an upsampling policy and an output policy with
`ValidatedMaterializationSpec`. These descriptors can also be used by callers
that supply decoded pixels directly.
+/
module imagery.materialization;

import std.meta : AliasSeq;

/// Plane interpolation policy.
struct NativePlanesGeometry
{
    /++
     Compile-time geometry policy identifier used by materialization dispatch.
    +/
    enum kind = "native";
}

/// Plane interpolation policy.
struct NearestUpsampling
{
    /++
     Compile-time geometry policy identifier used by materialization dispatch.
    +/
    enum kind = "nearest";
}

/// Explicit bilinear interpolation using declared source sample centers.
struct BilinearUpsampling
{
    /++
     Compile-time geometry policy identifier used by materialization dispatch.
    +/
    enum kind = "bilinear";
}

/++
 Choose float or double materialized RGB samples without output clipping.

 T is the output scalar type and defaults to float. The name describes numeric
 storage, not transfer encoding: materializeRgb returns encoded sRGB. This
 compile-time policy has no runtime pixel storage.
+/
struct LinearFloatOutput(T = float)
if (is(T == float) || is(T == double))
{
    /++
     Output scalar type selected by this policy.
    +/
    alias Sample = T;
    /++
     Whether the output policy requests clipping to its bounded sample range.
    +/
    enum clip = false;
}

/++
 Choose clipped ubyte output samples for materialization.

 The policy selects bounded integer storage; it does not define input color
 metadata or a geometry transformation. It carries no runtime pixel storage.
+/
struct ClippedUbyteOutput
{
    /++
     Output scalar type selected by this policy.
    +/
    alias Sample = ubyte;
    /++
     Whether the output policy requests clipping to its bounded sample range.
    +/
    enum clip = true;
}

/++
 Describe a compile-time component count and optional roles.

 ComponentCount is the number of components. Roles is an AliasSeq in plane
 order. A zero count can be represented but does not satisfy isImageModel.
 This policy type carries no runtime storage.
+/
struct ComponentModel(size_t ComponentCount, alias Roles = AliasSeq!())
{
    /++
     Number of declared components; must be nonzero for a valid model.
    +/
    enum componentCount = ComponentCount;
    /++
     Compile-time component roles in plane order.
    +/
    alias roles = Roles;
}

/++
 Choose explicit YCbCr component indices and a color-d conversion policy.

 ColorPolicy supplies matrix/range/primaries/transfer facts. Y, Cb and Cr are
 zero-based component-plane indices; the I/O adapter validates them against the
 decoded image. This descriptor does not infer metadata or own pixel storage.
+/
struct YCbCrModel(alias ColorPolicy, size_t Y, size_t Cb, size_t Cr)
{
    /++
     Explicit color-d policy for matrix, range, primaries and transfer.
    +/
    alias colorPolicy = ColorPolicy;
    /++
     Zero-based luminance-component plane index.
    +/
    enum yPlane = Y;
    /++
     Zero-based blue-difference component plane index.
    +/
    enum cbPlane = Cb;
    /++
     Zero-based red-difference component plane index.
    +/
    enum crPlane = Cr;
    /++
     Three YCbCr components.
    +/
    enum componentCount = 3;
}

/// A generic compile-time materialization specification.
struct MaterializationSpec(alias Model, alias Geometry, alias Output)
{
    /++
     Compile-time component/color model.
    +/
    alias model = Model;
    /++
     Compile-time native/upsampling geometry policy.
    +/
    alias geometry = Geometry;
    /++
     Compile-time output sample/clipping policy.
    +/
    alias output = Output;
}

/++
 Test whether T supplies a nonzero componentCount at compile time.

 This is a structural capability check, not proof that an arbitrary model is
 supported by every materialization operation.
+/
enum bool isImageModel(T) = __traits(compiles, {
    enum count = T.componentCount;
}) && T.componentCount != 0;

/++
 Test whether T supplies a kind member at compile time.

 The receiving materialization operation still validates supported kind values.
+/
enum bool isGeometryPolicy(T) = __traits(compiles, {
    enum value = T.kind;
});

/++
 Test whether T supplies a Sample type and clip member at compile time.

 The receiving operation still validates supported output sample types.
+/
enum bool isOutputPolicy(T) = __traits(compiles, {
    alias SampleType = T.Sample;
    enum clipping = T.clip;
});

/// Validated compile-time materialization configuration.
struct ValidatedMaterializationSpec(alias Model, alias Geometry, alias Output)
if (isImageModel!Model && isGeometryPolicy!Geometry && isOutputPolicy!Output)
{
    /++
     Compile-time component/color model.
    +/
    alias model = Model;
    /++
     Compile-time native/upsampling geometry policy.
    +/
    alias geometry = Geometry;
    /++
     Compile-time output sample/clipping policy.
    +/
    alias output = Output;
}

/// Choose explicit component, geometry and output policies at compile time.
@safe unittest
{
    alias Model=ComponentModel!3;
    alias Spec=ValidatedMaterializationSpec!(Model,NearestUpsampling,LinearFloatOutput!double);
    static assert(is(Spec.output.Sample==double));
    static assert(!Spec.output.clip && Spec.model.componentCount==3);
}


/++
 Name the YCbCr component order Y=0, Cb=1, Cr=2 with an explicit color policy. The policy supplies matrix/range/transfer facts; the alias does not infer them.
+/
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
