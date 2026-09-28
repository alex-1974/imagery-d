module app;

import core.stdc.stdlib :
    malloc;

import std.math :
    pow;

import std.stdio :
    writeln,
    writefln;

import color :
    SRgbd,
    SRgbf,
    toLinear;

import m3_color_d_srgb_transfer.contract :
    RgbBinding,
    RgbEncoding,
    decodeSrgbRegion,
    encodeSrgbRegion;

import raster :
    OwnedByteResource,
    PlaneByteLayout,
    RasterLease,
    RasterView,
    Region2D,
    tryAdoptMallocResource,
    tryImportOwnedRaster;


private enum LayoutKind : ubyte
{
    planar,
    interleaved
}


private RgbBinding encodedBinding()
@safe
pure
nothrow
@nogc
{
    return RgbBinding(
        0,
        1,
        2,
        RgbEncoding.encodedSRgb
    );
}


private RgbBinding linearBinding()
@safe
pure
nothrow
@nogc
{
    return RgbBinding(
        0,
        1,
        2,
        RgbEncoding.linearSRgb
    );
}


private T corpusValue(T)(
    size_t pixel,
    size_t component
)
@safe
pure
nothrow
@nogc
{
    const index =
        (pixel * 3 + component) % 13;

    switch (index)
    {
        case 0:
            return cast(T)-1.0;

        case 1:
            return cast(T)-0.5;

        case 2:
            return cast(T)-0.04045;

        case 3:
            return cast(T)-0.01;

        case 4:
            return cast(T)-0.0;

        case 5:
            return cast(T)0.0;

        case 6:
            return cast(T)0.003;

        case 7:
            return cast(T)0.04045;

        case 8:
            return cast(T)0.18;

        case 9:
            return cast(T)0.5;

        case 10:
            return cast(T)1.0;

        case 11:
            return cast(T)1.2;

        case 12:
            return cast(T)2.0;

        default:
            assert(false);
    }

    return T.init;
}


private RasterLease!T makeRgbRaster(T)(
    size_t width,
    size_t height,
    LayoutKind layout
)
{
    enum size_t components = 3;

    const sampleCount =
        width * height * components;

    const byteLength =
        sampleCount * T.sizeof;

    auto memory =
        cast(T*) malloc(byteLength);

    assert(memory !is null);

    foreach (index; 0 .. sampleCount)
    {
        memory[index] = T.init;
    }


    OwnedByteResource resource;

    assert(
        tryAdoptMallocResource(
            memory,
            byteLength,
            resource
        )
    );


    PlaneByteLayout[components] planes;

    final switch (layout)
    {
        case LayoutKind.planar:
        {
            const planeBytes =
                width * height * T.sizeof;

            foreach (component; 0 .. components)
            {
                planes[component] =
                    PlaneByteLayout(
                        component * planeBytes,
                        cast(ptrdiff_t)(
                            width * T.sizeof
                        ),
                        cast(ptrdiff_t) T.sizeof
                    );
            }

            break;
        }

        case LayoutKind.interleaved:
        {
            foreach (component; 0 .. components)
            {
                planes[component] =
                    PlaneByteLayout(
                        component * T.sizeof,
                        cast(ptrdiff_t)(
                            width * components * T.sizeof
                        ),
                        cast(ptrdiff_t)(
                            components * T.sizeof
                        )
                    );
            }

            break;
        }
    }


    RasterLease!T lease;

    const imported =
        tryImportOwnedRaster!T(
            resource,
            planes[],
            Region2D(
                0,
                0,
                width,
                height
            ),
            lease
        );

    assert(imported.ok);

    return lease;
}


private void fillEncodedCorpus(T)(
    ref RasterLease!T lease
)
{
    bool writableOk;

    scope auto writable =
        lease.tryWritableView(
            writableOk
        );

    assert(writableOk);

    foreach (y; 0 .. writable.height)
    {
        foreach (x; 0 .. writable.width)
        {
            const pixel =
                y * writable.width + x;

            foreach (component; 0 .. 3)
            {
                assert(
                    writable.trySetSample(
                        component,
                        x,
                        y,
                        corpusValue!T(
                            pixel,
                            component
                        )
                    )
                );
            }
        }
    }
}


private real magnitude(real value)
@safe
pure
nothrow
@nogc
{
    return value < 0.0L
        ? -value
        : value;
}


private real maxReal(
    real a,
    real b
)
@safe
pure
nothrow
@nogc
{
    return a > b ? a : b;
}


private real oracleDecode(
    real encoded
)
{
    const absolute =
        magnitude(encoded);

    if (absolute <= 0.04045L)
    {
        return encoded / 12.92L;
    }

    const base =
        (absolute + 0.055L) / 1.055L;

    const decoded =
        pow(base, 2.4L);

    return encoded < 0.0L
        ? -decoded
        : decoded;
}


private real oracleEncode(
    real linear
)
{
    const absolute =
        magnitude(linear);

    if (absolute <= 0.0031308L)
    {
        return linear * 12.92L;
    }

    const encoded =
        1.055L
        * pow(
            absolute,
            1.0L / 2.4L
        )
        - 0.055L;

    return linear < 0.0L
        ? -encoded
        : encoded;
}


private real validateDecodedAgainstOracle(T)(
    scope RasterView!T encoded,
    scope RasterView!T linear
)
{
    real maximumError;

    foreach (y; 0 .. encoded.height)
    {
        foreach (x; 0 .. encoded.width)
        {
            foreach (component; 0 .. 3)
            {
                T input;
                T actual;

                assert(
                    encoded.trySample(
                        component,
                        x,
                        y,
                        input
                    )
                );

                assert(
                    linear.trySample(
                        component,
                        x,
                        y,
                        actual
                    )
                );

                const expected =
                    oracleDecode(
                        cast(real) input
                    );

                const error =
                    magnitude(
                        cast(real) actual
                        - expected
                    );

                maximumError =
                    maxReal(
                        maximumError,
                        error
                    );

                const scale =
                    maxReal(
                        1.0L,
                        magnitude(expected)
                    );

                const numericalBudget =
                    64.0L
                    * cast(real) T.epsilon
                    * scale;

                assert(
                    error <= numericalBudget
                );
            }
        }
    }

    return maximumError;
}


private real validateEncodedAgainstOracle(T)(
    scope RasterView!T linear,
    scope RasterView!T encoded
)
{
    real maximumError;

    foreach (y; 0 .. linear.height)
    {
        foreach (x; 0 .. linear.width)
        {
            foreach (component; 0 .. 3)
            {
                T input;
                T actual;

                assert(
                    linear.trySample(
                        component,
                        x,
                        y,
                        input
                    )
                );

                assert(
                    encoded.trySample(
                        component,
                        x,
                        y,
                        actual
                    )
                );

                const expected =
                    oracleEncode(
                        cast(real) input
                    );

                const error =
                    magnitude(
                        cast(real) actual
                        - expected
                    );

                maximumError =
                    maxReal(
                        maximumError,
                        error
                    );

                const scale =
                    maxReal(
                        1.0L,
                        magnitude(expected)
                    );

                const numericalBudget =
                    64.0L
                    * cast(real) T.epsilon
                    * scale;

                assert(
                    error <= numericalBudget
                );
            }
        }
    }

    return maximumError;
}


private void assertSemanticEqual(T)(
    scope RasterView!T a,
    scope RasterView!T b
)
{
    assert(a.planeCount == b.planeCount);
    assert(a.width == b.width);
    assert(a.height == b.height);

    foreach (plane; 0 .. a.planeCount)
    {
        foreach (y; 0 .. a.height)
        {
            foreach (x; 0 .. a.width)
            {
                T av;
                T bv;

                assert(
                    a.trySample(
                        plane,
                        x,
                        y,
                        av
                    )
                );

                assert(
                    b.trySample(
                        plane,
                        x,
                        y,
                        bv
                    )
                );

                assert(av == bv);
            }
        }
    }
}


private void runPartitionedDecode(T)(
    ref RasterLease!T sourceLease,
    ref RasterLease!T destinationLease
)
{
    auto source =
        sourceLease.view();

    bool destinationOk;

    scope auto destination =
        destinationLease.tryWritableView(
            destinationOk
        );

    assert(destinationOk);

    const Region2D[4] partitions =
    [
        Region2D(0, 0, 3, 1),
        Region2D(3, 0, 5, 1),
        Region2D(0, 1, 5, 3),
        Region2D(5, 1, 3, 3)
    ];

    foreach (partition; partitions)
    {
        bool sourceRoiOk;

        auto sourceRoi =
            source.tryRoi(
                partition,
                sourceRoiOk
            );

        assert(sourceRoiOk);


        bool destinationRoiOk;

        auto destinationRoi =
            destination.tryRoi(
                partition,
                destinationRoiOk
            );

        assert(destinationRoiOk);


        const result =
            decodeSrgbRegion(
                sourceRoi,
                encodedBinding(),
                destinationRoi,
                linearBinding()
            );

        assert(result.ok);
    }
}


private real exerciseLayout(T)(
    LayoutKind layout
)
{
    enum size_t width = 8;
    enum size_t height = 4;

    auto sourceLease =
        makeRgbRaster!T(
            width,
            height,
            layout
        );

    fillEncodedCorpus(sourceLease);


    auto wholeLease =
        makeRgbRaster!T(
            width,
            height,
            layout
        );

    {
        auto source =
            sourceLease.view();

        bool destinationOk;

        scope auto destination =
            wholeLease.tryWritableView(
                destinationOk
            );

        assert(destinationOk);

        const result =
            decodeSrgbRegion(
                source,
                encodedBinding(),
                destination,
                linearBinding()
            );

        assert(result.ok);
    }


    auto partitionedLease =
        makeRgbRaster!T(
            width,
            height,
            layout
        );

    runPartitionedDecode(
        sourceLease,
        partitionedLease
    );


    auto whole =
        wholeLease.view();

    auto partitioned =
        partitionedLease.view();

    assertSemanticEqual(
        whole,
        partitioned
    );


    const maximumDecodeError =
        validateDecodedAgainstOracle(
            sourceLease.view(),
            whole
        );


    auto roundTripLease =
        makeRgbRaster!T(
            width,
            height,
            layout
        );

    {
        bool destinationOk;

        scope auto destination =
            roundTripLease.tryWritableView(
                destinationOk
            );

        assert(destinationOk);

        const result =
            encodeSrgbRegion(
                whole,
                linearBinding(),
                destination,
                encodedBinding()
            );

        assert(result.ok);
    }


    const maximumEncodeError =
        validateEncodedAgainstOracle(
            whole,
            roundTripLease.view()
        );


    writefln(
        "layout=%s scalar=%s max_decode_abs_error=%.9Le max_encode_abs_error=%.9Le",
        layout == LayoutKind.planar
            ? "planar"
            : "interleaved",
        T.stringof,
        maximumDecodeError,
        maximumEncodeError
    );

    return maximumDecodeError;
}


private void exerciseLayoutIndependence()
{
    enum size_t width = 8;
    enum size_t height = 4;

    auto planarSource =
        makeRgbRaster!float(
            width,
            height,
            LayoutKind.planar
        );

    auto interleavedSource =
        makeRgbRaster!float(
            width,
            height,
            LayoutKind.interleaved
        );

    fillEncodedCorpus(planarSource);
    fillEncodedCorpus(interleavedSource);

    assertSemanticEqual(
        planarSource.view(),
        interleavedSource.view()
    );


    auto planarOutput =
        makeRgbRaster!float(
            width,
            height,
            LayoutKind.planar
        );

    auto interleavedOutput =
        makeRgbRaster!float(
            width,
            height,
            LayoutKind.interleaved
        );

    {
        bool planarWritableOk;
        bool interleavedWritableOk;

        scope auto planarWritable =
            planarOutput.tryWritableView(
                planarWritableOk
            );

        scope auto interleavedWritable =
            interleavedOutput.tryWritableView(
                interleavedWritableOk
            );

        assert(planarWritableOk);
        assert(interleavedWritableOk);

        assert(
            decodeSrgbRegion(
                planarSource.view(),
                encodedBinding(),
                planarWritable,
                linearBinding()
            ).ok
        );

        assert(
            decodeSrgbRegion(
                interleavedSource.view(),
                encodedBinding(),
                interleavedWritable,
                linearBinding()
            ).ok
        );
    }

    assertSemanticEqual(
        planarOutput.view(),
        interleavedOutput.view()
    );
}


private void exerciseRejectedSemantics()
{
    auto sourceLease =
        makeRgbRaster!float(
            2,
            2,
            LayoutKind.planar
        );

    auto destinationLease =
        makeRgbRaster!float(
            2,
            2,
            LayoutKind.planar
        );

    bool destinationOk;

    scope auto destination =
        destinationLease.tryWritableView(
            destinationOk
        );

    assert(destinationOk);


    const wrongEncoding =
        decodeSrgbRegion(
            sourceLease.view(),
            linearBinding(),
            destination,
            linearBinding()
        );

    assert(!wrongEncoding.ok);


    const invalidBinding =
        RgbBinding(
            0,
            0,
            2,
            RgbEncoding.encodedSRgb
        );

    const duplicatePlane =
        decodeSrgbRegion(
            sourceLease.view(),
            invalidBinding,
            destination,
            linearBinding()
        );

    assert(!duplicatePlane.ok);
}


private void exerciseSpecialValues()
{
    const special =
        SRgbd(
            double.nan,
            double.infinity,
            -double.infinity
        ).toLinear;

    assert(special.r != special.r);
    assert(special.g == double.infinity);
    assert(special.b == -double.infinity);

    const negativeZero =
        SRgbd(
            -0.0,
            0.0,
            0.0
        ).toLinear;

    assert(negativeZero.r == 0.0);
    assert(
        1.0 / negativeZero.r
        == -double.infinity
    );
}


/*
 * Consumer-side CTFE smoke. The region operation is runtime because it
 * consumes raster views, but the scalar colour primitive remains CTFE-capable.
 */
enum ctfeDecoded =
    SRgbf(
        0.5f,
        0.25f,
        0.0f
    ).toLinear;

static assert(ctfeDecoded.r > 0.0f);
static assert(ctfeDecoded.g > 0.0f);
static assert(ctfeDecoded.b == 0.0f);


void main()
{
    writeln(
        "M3 imagery-d -> color-d sRGB consumer experiment"
    );

    exerciseLayout!float(
        LayoutKind.planar
    );

    exerciseLayout!float(
        LayoutKind.interleaved
    );

    exerciseLayout!double(
        LayoutKind.planar
    );

    exerciseLayoutIndependence();
    exerciseRejectedSemantics();
    exerciseSpecialValues();

    writeln(
        "M3 color-d consumer correctness: PASS"
    );
}
