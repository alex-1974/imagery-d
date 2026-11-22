module app;

import imagery.io;
import imagery.materialization;
import imageio : ImageRegion, ImageRegionInfo, ImagePlane, ImagePlaneInfo,
    PlaneGeometryStatus, PlaneSamplingGeometry, Rational, ComponentRole,
    SourceModel, SampleFormat, PixelLayout, MetadataState, ColorMatrix, ColorRange,
    TransferFunction, ColorPrimaries, SampleSignedness, zeroPhaseSampling,
    decodeJpegPlanes, decodeJpegRegion;
import color : Bt601Full, Bt601Video, Bt709Full, Bt709Video;
import std.algorithm : min,max,sort;
import std.exception : enforce;
import std.json : JSONValue;
import std.stdio : writeln;

private ImageRegion fixture() @safe
{
    auto info=ImageRegionInfo(9,7,3,SampleFormat.u8,PixelLayout.planar,0,0,0,SourceModel.yCbCr);
    auto m=info.colorMetadata;
    m.state=m.modelState=m.matrixState=m.rangeState=m.transferState=m.primariesState=m.bitDepthState=MetadataState.known;
    m.model=SourceModel.yCbCr; m.matrix=ColorMatrix.bt601; m.range=ColorRange.video;
    m.transfer=TransferFunction.sRGB; m.primaries=ColorPrimaries.bt709;
    m.bitDepth=8; m.signedness=SampleSignedness.unsigned; info.colorMetadata=m;
    ImagePlane[] planes;
    foreach(c;0..3)
    {
        const w=c?5:9,h=c?4:7,stride=w+3;
        auto bytes=new ubyte[(h-1)*stride+w];
        foreach(y;0..h)foreach(x;0..w)bytes[y*stride+x]=cast(ubyte)((x*37+y*59+c*71)%256);
        auto p=ImagePlane(ImagePlaneInfo(c+1,1,1,zeroPhaseSampling(c?2:1,c?2:1),
            c==0?ComponentRole.luma:c==1?ComponentRole.chromaBlue:ComponentRole.chromaRed),
            w,h,0,0,stride,bytes);
        if(c){p.info.geometry.centerOffsetX=Rational(1,3);p.info.geometry.centerOffsetY=Rational(-1,4);}
        planes~=p;
    }
    return ImageRegion(info,0,0,null,planes);
}

private JSONValue sourceDescription(ImageRegion source) @safe
{
    JSONValue record;
    record["width"]=JSONValue(source.info.width);record["height"]=JSONValue(source.info.height);
    record["x"]=JSONValue(source.originX);record["y"]=JSONValue(source.originY);
    JSONValue[] planes;
    foreach(p;source.planes)
    {
        JSONValue v;
        v["width"]=JSONValue(p.width);v["height"]=JSONValue(p.height);
        v["x"]=JSONValue(p.originX);v["y"]=JSONValue(p.originY);
        v["factor_x"]=JSONValue(p.info.geometry.horizontalFactor);v["factor_y"]=JSONValue(p.info.geometry.verticalFactor);
        double[] offsets=[cast(double)p.info.geometry.centerOffsetX.numerator/p.info.geometry.centerOffsetX.denominator,
            cast(double)p.info.geometry.centerOffsetY.numerator/p.info.geometry.centerOffsetY.denominator,
            cast(double)p.referenceOffsetX.numerator/p.referenceOffsetX.denominator,
            cast(double)p.referenceOffsetY.numerator/p.referenceOffsetY.denominator];
        v["offsets"]=JSONValue(offsets);
        JSONValue[] exact;
        foreach(r;[p.info.geometry.centerOffsetX,p.info.geometry.centerOffsetY,p.referenceOffsetX,p.referenceOffsetY])
            exact~=JSONValue([JSONValue(r.numerator),JSONValue(r.denominator)]);
        v["offset_rationals"]=JSONValue(exact);
        ubyte[] bytes;
        foreach(y;0..p.height)bytes~=p.data[y*p.rowStrideBytes..y*p.rowStrideBytes+p.width];
        v["bytes"]=JSONValue(bytes);planes~=v;
    }
    record["planes"]=JSONValue(planes);return record;
}

private void compare(T)(ref OwnedRgbMaterialization!T a,ref OwnedRgbMaterialization!T b,size_t x,size_t y) @safe
{
    scope auto va=a.raster.view(),vb=b.raster.view();
    foreach(yy;0..vb.height)foreach(xx;0..vb.width)foreach(c;0..3)
    {
        T first,second;
        enforce(va.trySample(c,x+xx,y+yy,first) && vb.trySample(c,xx,yy,second));
        enforce(first==second,"materialization global ROI equality");
    }
}

private JSONValue run(Policy,Geometry,T,size_t Y=0,size_t Cb=1,size_t Cr=2)(ImageRegion image) @safe
{
    alias Model=YCbCrModel!(Policy,Y,Cb,Cr);
    static if(is(T==ubyte))alias Output=ClippedUbyteOutput;
    else alias Output=LinearFloatOutput!T;
    alias Spec=ValidatedMaterializationSpec!(Model,Geometry,Output);
    image.info.colorMetadata.matrix=Policy.matrix==0?ColorMatrix.bt601:ColorMatrix.bt709;
    image.info.colorMetadata.range=Policy.range==0?ColorRange.full:ColorRange.video;
    OwnedRgbMaterialization!T result;
    const budget=image.info.width*image.info.height*3*T.sizeof;
    enforce(tryMaterializeRgbOwned!Spec(image,budget,result)==ImageMaterializationError.none);
    enforce(result.recipe=="imageio-sampleCenter-plus-geometry-v1" && result.components[1].index==Cb);
    auto retained=result;
    enforce(tryMaterializeRgbOwned!Spec(image,budget-1,result)==ImageMaterializationError.resultExceedsBudget);
    compare(retained,result,0,0);
    auto values=materializeRgb!Spec(image,budget);
    enforce(values.ok);
    scope auto view=result.raster.view();
    double[] output;
    foreach(y;0..image.info.height)foreach(x;0..image.info.width)foreach(c;0..3)
    {
        T value; enforce(view.trySample(c,x,y,value)); output~=cast(double)value;
        const pixel=values.pixels[y*image.info.width+x];
        const expected=c==0?pixel.r:c==1?pixel.g:pixel.b;
        enforce(value==expected,"array and direct owned results differ");
    }
    if(image.info.width>4 && image.info.height>3)
    {
        auto roi=image;roi.originX+=3;roi.originY+=1;roi.info.width=4;roi.info.height=3;
        OwnedRgbMaterialization!T partial;
        enforce(tryMaterializeRgbOwned!Spec(roi,4*3*3*T.sizeof,partial)==ImageMaterializationError.none);
        compare(result,partial,3,1);
    }
    JSONValue record=sourceDescription(image);
    record["matrix"]=JSONValue(cast(int)Policy.matrix);record["range"]=JSONValue(cast(int)Policy.range);
    record["filter"]=JSONValue(Geometry.kind);record["sample"]=JSONValue(T.stringof);
    record["indices"]=JSONValue([Y,Cb,Cr]);
    record["rgb"]=JSONValue(output);
    return record;
}

private size_t errors() @safe
{
    alias Spec=ValidatedMaterializationSpec!(YCbCrModel!(Bt601Video,0,1,2),BilinearUpsampling,LinearFloatOutput!double);
    auto image=fixture();OwnedRgbMaterialization!double published;
    enforce(tryMaterializeRgbOwned!Spec(image,9*7*24,published)==ImageMaterializationError.none);
    auto retained=published;
    size_t checks;
    void check(ImageMaterializationError expected) @safe
    {
        enforce(tryMaterializeRgbOwned!Spec(image,size_t.max,published)==expected,"materialization error code");
        compare(retained,published,0,0);++checks;
    }
    image.info.componentCount=4;check(ImageMaterializationError.componentCountMismatch);image=fixture();
    image.info.width=0;check(ImageMaterializationError.invalidRegion);image=fixture();
    image.originX=size_t.max;check(ImageMaterializationError.invalidRegion);image=fixture();
    image.info.sampleFormat=SampleFormat.u16;check(ImageMaterializationError.unsupportedSampleFormat);image=fixture();
    image.planes[1].rowStrideBytes=1;check(ImageMaterializationError.invalidPlane);image=fixture();
    image.planes[1].info.geometry.status=PlaneGeometryStatus.unavailable;check(ImageMaterializationError.missingGeometry);
    enforce(materialize(image).ok,"native fallback unavailable geometry");image=fixture();
    image.planes[1].info.geometry.status=PlaneGeometryStatus.unsupported;check(ImageMaterializationError.unsupportedGeometry);image=fixture();
    image.planes[1].info.geometry.status=PlaneGeometryStatus.conflicting;check(ImageMaterializationError.conflictingGeometry);image=fixture();
    image.planes[1].info.geometry.status=PlaneGeometryStatus.invalid;check(ImageMaterializationError.invalidGeometry);image=fixture();
    image.planes[1].info.geometry.horizontalFactor=0;check(ImageMaterializationError.invalidGeometry);image=fixture();
    image.planes[1].referenceOffsetX.denominator=0;check(ImageMaterializationError.invalidGeometry);
    enforce(materialize(image).ok,"native fallback invalid geometry");image=fixture();
    image.planes[1].info.geometry.centerOffsetY.denominator=0;check(ImageMaterializationError.invalidGeometry);image=fixture();
    image.planes[1].info.role=ComponentRole.generic;check(ImageMaterializationError.missingComponentRole);image=fixture();
    image.planes[1].info.role=ComponentRole.luma;check(ImageMaterializationError.invalidComponentRole);image=fixture();
    image.info.sourceModel=SourceModel.rgb;check(ImageMaterializationError.conflictingMetadata);image=fixture();
    image.info.colorMetadata.modelState=MetadataState.absent;check(ImageMaterializationError.missingColorModel);image=fixture();
    image.info.sourceModel=image.info.colorMetadata.model=SourceModel.rgb;check(ImageMaterializationError.unsupportedColorModel);image=fixture();
    image.info.colorMetadata.matrixState=MetadataState.absent;check(ImageMaterializationError.missingMatrix);image=fixture();
    image.info.colorMetadata.matrixState=MetadataState.unsupported;check(ImageMaterializationError.unsupportedMatrix);image=fixture();
    image.info.colorMetadata.matrix=ColorMatrix.bt709;check(ImageMaterializationError.policyMismatch);image=fixture();
    image.info.colorMetadata.rangeState=MetadataState.absent;check(ImageMaterializationError.missingRange);image=fixture();
    image.info.colorMetadata.range=ColorRange.unknown;check(ImageMaterializationError.unsupportedRange);image=fixture();
    image.info.colorMetadata.range=ColorRange.full;check(ImageMaterializationError.policyMismatch);image=fixture();
    image.info.colorMetadata.transferState=MetadataState.absent;check(ImageMaterializationError.missingTransfer);image=fixture();
    image.info.colorMetadata.transfer=TransferFunction.linear;check(ImageMaterializationError.unsupportedTransfer);image=fixture();
    image.info.colorMetadata.primariesState=MetadataState.absent;check(ImageMaterializationError.missingPrimaries);image=fixture();
    image.info.colorMetadata.primaries=ColorPrimaries.bt601;check(ImageMaterializationError.unsupportedPrimaries);image=fixture();
    image.info.colorMetadata.bitDepthState=MetadataState.absent;check(ImageMaterializationError.missingBitDepth);image=fixture();
    image.info.colorMetadata.bitDepth=10;check(ImageMaterializationError.unsupportedBitDepth);image=fixture();
    image.info.colorMetadata.signedness=SampleSignedness.signed;check(ImageMaterializationError.unsupportedSampleFormat);image=fixture();
    image.info.colorMetadata.state=MetadataState.conflicting;check(ImageMaterializationError.conflictingMetadata);image=fixture();
    enforce(!ImageMaterializationResult.init.ok && !RgbMaterializationResult!double.init.ok &&
        !RgbFloatRasterResult.init.ok && !RasterMaterializationResult.init.ok);
    image=fixture();image.planes[1].info.geometry.centerOffsetX=Rational(long.min,1);
    check(ImageMaterializationError.unsupportedGeometry);
    image=fixture();image.planes[1].referenceOffsetY=Rational(long.max,1);
    check(ImageMaterializationError.unsupportedGeometry);
    image=fixture();image.info.colorMetadata.state=MetadataState.unsupported;
    check(ImageMaterializationError.unsupportedColorModel);
    return checks;
}

private ImageRegion declaredFixture(ImageRegion raw) @safe
{
    // Explicit TEST-PROVIDER interpretation, never metadata inferred from pixels
    // or silently attributed to the JPEG decoder. Raw unknown facts are tested first.
    auto result=raw;result.planes=raw.planes.dup;
    result.info.colorMetadata=fixture().info.colorMetadata;
    result.info.sourceModel=SourceModel.yCbCr;
    foreach(ref p;result.planes)
    {
        p.info.geometry.status=PlaneGeometryStatus.known;
        p.info.geometry.centerOffsetX=Rational(0,1);
        p.info.geometry.centerOffsetY=Rational(0,1);
    }
    return result;
}

void main(string[] args)
{
    import std.meta : AliasSeq;
    import std.file : read;
    if(args.length==2 && args[1]=="--bench"){benchmark();return;}
    enforce(args.length==5,"Supply independent 420/422 JPEG, scalar and RGB GeoTIFF fixtures");
    JSONValue root;JSONValue[] cases;
    foreach(kind;0..4)
    {
        auto image=fixture();
        if(kind==1)
        {
            image.originX=3;image.originY=1;
            image.planes[1].referenceOffsetX=Rational(1,2);
            image.planes[2].referenceOffsetY=Rational(-1,3);
        }
        if(kind==2)
        {
            image.originX=(1UL<<63)+3;image.originY=(1UL<<63)+5;
            foreach(ref p;image.planes)
            {
                p.originX=image.originX/p.info.geometry.horizontalFactor-1;
                p.originY=image.originY/p.info.geometry.verticalFactor-1;
            }
        }
        if(kind==3)
        {
            foreach(c;1..3)
            {
                image.planes[c]=image.planes[0];
                image.planes[c].info.role=c==1?ComponentRole.chromaBlue:ComponentRole.chromaRed;
                image.planes[c].info.geometry.centerOffsetX=Rational(1,2);
            }
        }
        foreach(Policy;AliasSeq!(Bt601Full,Bt601Video,Bt709Full,Bt709Video))
        foreach(Geometry;AliasSeq!(NearestUpsampling,BilinearUpsampling))
        foreach(T;AliasSeq!(float,double,ubyte))cases~=run!(Policy,Geometry,T)(image);
    }
    auto ordered=fixture();auto saved=ordered.planes;
    ordered.planes=[saved[2],saved[0],saved[1]];
    cases~=run!(Bt601Video,BilinearUpsampling,double,1,2,0)(ordered);
    size_t decoderCases;
    foreach(path;args[1..3])
    {
        const encoded=cast(const(ubyte)[])read(path);
        auto whole=decodeJpegPlanes(encoded);enforce(whole.ok,"real JPEG plane decode");
        auto roi=decodeJpegRegion(encoded,3,1,9,7);enforce(roi.ok,"real JPEG odd ROI decode");
        foreach(raw;[whole.region,roi.region])
        {
            enforce(raw.info.width && raw.info.height && raw.planes.length==3);
            auto copied=materialize(raw);enforce(copied.ok);
            foreach(i,p;raw.planes)
            {
                enforce(copied.native.planes[i].referenceOffsetX==p.referenceOffsetX &&
                    copied.native.planes[i].referenceOffsetY==p.referenceOffsetY &&
                    copied.native.planes[i].info==p.info,"native metadata must survive");
            }
            enforce(visitNativePlanes(raw,(scope const ImageRegion source) @safe {
                return source.planes[1].data is raw.planes[1].data;
            })==ImageMaterializationError.none,"zero-copy native borrow");
            alias Spec=ValidatedMaterializationSpec!(YCbCrModel!(Bt601Video,0,1,2),NearestUpsampling,LinearFloatOutput!float);
            OwnedRgbMaterialization!float outValue;
            enforce(tryMaterializeRgbOwned!Spec(raw,size_t.max,outValue)==ImageMaterializationError.missingGeometry);
            auto known=declaredFixture(raw);
            // Restoring only geometry cannot authorize missing color facts.
            auto geometryOnly=known;geometryOnly.info=raw.info;
            enforce(tryMaterializeRgbOwned!Spec(geometryOnly,size_t.max,outValue)!=ImageMaterializationError.none);
            foreach(Policy;AliasSeq!(Bt601Full,Bt601Video,Bt709Full,Bt709Video))
            foreach(Geometry;AliasSeq!(NearestUpsampling,BilinearUpsampling))
            foreach(T;AliasSeq!(float,double,ubyte))cases~=run!(Policy,Geometry,T)(known);
            ++decoderCases;
        }
    }
    root["cases"]=JSONValue(cases);root["decoder_regions"]=JSONValue(decoderCases);
    root["error_checks"]=JSONValue(errors());
    import region_handoff : checkRegionHandoff;
    root["region_handoff"]=checkRegionHandoff(args[3]);
    // Released imageio checks scalar BitsPerSample before loading the RGB array.
    // Keep the real failure visible; do not patch its parser inside imagery-d.
    import imageio : decodeRegion;
    import transport : FileSource;
    import std.conv : to;
    const rgbTiff=decodeRegion(new FileSource(args[4]),3,1,9,7);
    root["rgb_tiff_decoder_status"]=JSONValue(to!string(rgbTiff.error));
    if(rgbTiff.ok)root["rgb_region_handoff"]=checkRegionHandoff(args[4],3);
    writeln(root.toString);
}

private void benchmark()
{
    import core.memory : GC;
    import core.time : MonoTime;
    import std.meta : AliasSeq;
    import std.stdio : stdout;
    foreach(size;[256,1024])foreach(Geometry;AliasSeq!(NearestUpsampling,BilinearUpsampling))
    foreach(T;AliasSeq!(float,ubyte))
    {
        auto image=fixture();image.info.width=image.info.height=size;
        foreach(c,ref p;image.planes)
        {
            p.width=p.height=c?size/2:size;p.rowStrideBytes=p.width;
            p.data=new ubyte[p.width*p.height];
            foreach(i,ref value;p.data)value=cast(ubyte)((i*17+c*53)%256);
        }
        static if(is(T==ubyte))alias Output=ClippedUbyteOutput;
        else alias Output=LinearFloatOutput!T;
        alias Spec=ValidatedMaterializationSpec!(YCbCrModel!(Bt601Video,0,1,2),Geometry,Output);
        OwnedRgbMaterialization!T frame;
        const budget=3*size*size*T.sizeof;
        enforce(tryMaterializeRgbOwned!Spec(image,budget,frame)==ImageMaterializationError.none);
        double[] ownedTimes,arrayTimes;size_t ownedGc,arrayGc;double checksum=0;
        foreach(repeat;0..5)
        {
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            enforce(tryMaterializeRgbOwned!Spec(image,budget,frame)==ImageMaterializationError.none);
            const elapsed=(MonoTime.currTime-start).total!"nsecs"/cast(double)(size*size);
            const gcDelta=GC.stats().allocatedInCurrentThread-before;
            ownedTimes~=elapsed;ownedGc=max(ownedGc,gcDelta);
            scope auto view=frame.raster.view();
            foreach(y;0..size)foreach(x;0..size)foreach(c;0..3){T value;enforce(view.trySample(c,x,y,value));checksum+=value;}
            const arrayBefore=GC.stats().allocatedInCurrentThread;
            const arrayStart=MonoTime.currTime;
            const result=materializeRgb!Spec(image,budget);enforce(result.ok);
            const arrayElapsed=(MonoTime.currTime-arrayStart).total!"nsecs"/cast(double)(size*size);
            const arrayDelta=GC.stats().allocatedInCurrentThread-arrayBefore;
            arrayTimes~=arrayElapsed;arrayGc=max(arrayGc,arrayDelta);
            foreach(pixel;result.pixels)checksum+=pixel.r+pixel.g+pixel.b;
        }
        sort(ownedTimes);sort(arrayTimes);
        writeln("MATERIALIZE size=",size," geometry=",Geometry.kind," sample=",T.stringof,
            " owned_ns_per_pixel=",ownedTimes[2]," owned_min=",ownedTimes[0]," owned_max=",ownedTimes[$-1],
            " array_ns_per_pixel=",arrayTimes[2]," array_min=",arrayTimes[0]," array_max=",arrayTimes[$-1],
            " owned_gc_bytes=",ownedGc," array_gc_bytes=",arrayGc," result_bytes=",budget," checksum=",checksum);
        stdout.flush();
    }
}
