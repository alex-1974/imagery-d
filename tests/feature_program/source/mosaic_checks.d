module mosaic_checks;

import imagery.mosaic.multiresolution;
import imagery.mosaic.decoded_tile_mosaic : RgbaAlphaAssociation;
import imagery.mosaic.validity_policy : QualityContributor;
import imagery.pyramid.overview_selection : OverviewLevel;
import raster : RasterLease, OwnedByteResource, PlaneByteLayout, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import core.stdc.stdlib : malloc;
import std.algorithm : min, max, sort;
import std.exception : enforce;
import std.json : JSONValue;

// Test-only allocation/layout boundary. Production consumes only raster-d views.
private RasterLease!ubyte owner(scope const(ubyte)[] bytes, size_t w, size_t h,
    size_t bands, bool reversed) @trusted
{
    const row = w+3, plane = row*h+5;
    auto p = cast(ubyte*)malloc(plane*bands);
    enforce(p !is null);
    p[0 .. plane*bands] = 173;
    foreach (y; 0 .. h) foreach (x; 0 .. w) foreach (c; 0 .. bands)
        p[c*plane+(reversed?h-1-y:y)*row+(reversed?w-1-x:x)] = bytes[(y*w+x)*bands+c];
    OwnedByteResource resource;
    enforce(tryAdoptMallocResource(p, plane*bands, resource));
    PlaneByteLayout[4] layouts;
    foreach (c; 0 .. bands) layouts[c] = PlaneByteLayout(
        c*plane+(reversed?(h-1)*row+w-1:0),
        reversed?-cast(ptrdiff_t)row:cast(ptrdiff_t)row, reversed?-1:1);
    RasterLease!ubyte result;
    enforce(tryImportOwnedRaster!ubyte(resource, layouts[0 .. bands], Region2D(0,0,w,h), result).ok);
    return result;
}

private ubyte[4] pixel(size_t source, size_t level, size_t x, size_t y) @safe
{
    return [cast(ubyte)((x*37+y*19+source*71+level*11)%256),
        cast(ubyte)((x*13+y*43+source*17+level*29)%256),
        cast(ubyte)((x*53+y*7+source*47+level*31)%256),
        cast(ubyte)((x+y+source)%7==0?0:(x*23+y*11+source*41)%256)];
}

private bool selected(size_t source, size_t x, size_t y) @safe
{ return (x*3+y*5+source)%17 != 0; }

private QualityContributor quality(size_t source, size_t x, size_t y) @safe
{
    return QualityContributor((x+y+source)%11 != 0, .25+.25*((x+source)%4),
        .2+.2*((y+source)%5), 1+source);
}

private MosaicSource fixture(size_t id, bool reverse) @safe
{
    MosaicSource source;
    source.identity = "mosaic-fixture"; source.revision = "1"; source.grid = "registered-extent-1";
    source.qualityPolicy = "fixture-global-target"; source.qualityRevision = "1";
    const(OverviewLevel)[][] pyramids = [
        [OverviewLevel(37,29), OverviewLevel(19,15), OverviewLevel(11,9)],
        [OverviewLevel(31,23), OverviewLevel(17,13), OverviewLevel(9,7)],
        [OverviewLevel(23,19), OverviewLevel(13,11), OverviewLevel(7,5)]];
    source.levels = pyramids[id];
    source.tileWidth = 4+id; source.tileHeight = 3+id;
    source.association = RgbaAlphaAssociation.straight;
    source.quality = QualityContributor(true);
    const levels = source.levels, tw = source.tileWidth, th = source.tileHeight;
    source.read = (size_t level, size_t tx, size_t ty, scope MosaicTileConsumer consume) @safe {
        if ((tx+2*ty+id)%13 == 6) return MosaicTileStatus.missing;
        const w = min(tw, levels[level].width-tx*tw), h = min(th, levels[level].height-ty*th);
        auto pixels = new ubyte[w*h*4], mask = new ubyte[w*h];
        foreach (y; 0 .. h) foreach (x; 0 .. w)
        {
            pixels[(y*w+x)*4 .. (y*w+x+1)*4] = pixel(id, level, tx*tw+x, ty*th+y)[];
            mask[y*w+x] = cast(ubyte)selected(id, tx*tw+x, ty*th+y);
        }
        auto p = owner(pixels, w, h, 4, reverse), m = owner(mask, w, h, 1, !reverse);
        return consume(p.view(), m.view())?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    source.qualityRead = (size_t level, Region2D r, scope QualityContributor[] factors) @safe {
        foreach (x, ref factor; factors) factor = quality(id, r.x+x, r.y);
        return true;
    };
    return source;
}

private MosaicRequest request(size_t w, size_t h, MosaicFilter filter) @safe
{
    MosaicRequest r;
    r.targetWidth=w; r.targetHeight=h; r.region=Region2D(0,0,w,h); r.filter=filter;
    r.maxResultBytes=w*h*5; r.maxWorkBytes=8*1024*1024;
    r.maxSourceSamples=100_000_000; r.maxTileReads=10_000_000;
    return r;
}

private ubyte[] bytes(scope ref MosaicFrame frame) @safe
{
    auto result = new ubyte[frame.region.width*frame.region.height*5];
    scope auto rgba = frame.rgba.view(), mask = frame.validity.view();
    foreach (y; 0 .. frame.region.height) foreach (x; 0 .. frame.region.width)
    {
        foreach (c; 0 .. 4) enforce(rgba.trySample(c,x,y,result[(y*frame.region.width+x)*5+c]));
        enforce(mask.trySample(0,x,y,result[(y*frame.region.width+x)*5+4]));
    }
    return result;
}

private size_t integration(ref JSONValue root) @safe
{
    JSONValue[] cases;
    size_t checked;
    foreach (shape; [[11,9],[16,10],[47,33],[7,5],[1,1],[19,17],[263,19]])
    foreach (filter; [MosaicFilter.nearest,MosaicFilter.bilinear,MosaicFilter.area])
    {
        if (filter==MosaicFilter.area && (shape[0]>23 || shape[1]>19)) continue;
        MosaicSource[] sources;
        foreach (i; 0 .. 3) sources ~= fixture(i, true);
        auto r = request(shape[0],shape[1],filter);
        MosaicFrame whole;
        MosaicMetrics metrics;
        enforce(tryAssembleMosaicOwned(sources,r,whole,metrics)==MosaicError.none, "mosaic integration");
        const expected=bytes(whole);
        enforce(whole.sources.length==3 && whole.recipe.length);
        enforce(metrics.resultBytes==r.maxResultBytes && metrics.workBytes<r.maxWorkBytes);
        // Every output byte must match independently requested partitions.
        for(size_t y=0; y<r.targetHeight; y+=3) for(size_t x=0; x<r.targetWidth; x+=4)
        {
            auto part=r; part.region=Region2D(x,y,min(4,r.targetWidth-x),min(3,r.targetHeight-y));
            MosaicFrame piece;
            enforce(tryAssembleMosaicOwned(sources,part,piece,metrics)==MosaicError.none);
            const actual=bytes(piece);
            foreach (yy; 0 .. part.region.height) foreach (xx; 0 .. part.region.width)
            {
                const a=5*(yy*part.region.width+xx), b=5*((y+yy)*r.targetWidth+x+xx);
                enforce(actual[a .. a+5]==expected[b .. b+5], "mosaic partition seam");
                ++checked;
            }
        }
        foreach (i; 0 .. 3) sources[i]=fixture(i,false);
        MosaicFrame other;
        enforce(tryAssembleMosaicOwned(sources,r,other,metrics)==MosaicError.none && bytes(other)==expected,
            "mosaic signed-stride layout equivalence");
        JSONValue record;
        record["width"]=JSONValue(r.targetWidth); record["height"]=JSONValue(r.targetHeight);
        record["filter"]=JSONValue(cast(int)filter);
        size_t[] indices,widths,heights;
        foreach (s;whole.sources) {indices~=s.selection.index; widths~=s.level.width; heights~=s.level.height;}
        record["levels"]=JSONValue(indices); record["source_widths"]=JSONValue(widths); record["source_heights"]=JSONValue(heights);
        record["bytes"]=JSONValue(expected);
        cases~=record;
    }
    root["mosaic_cases"]=JSONValue(cases);
    return checked;
}

// Small analytic laws exercise the public API, independently of the oracle.
private void laws() @safe
{
    auto source=fixture(0,false);
    source.levels=[OverviewLevel(2,1)]; source.tileWidth=2; source.tileHeight=1;
    source.qualityRead=null;
    auto p=owner([0,0,0,255,255,255,255,255],2,1,4,false);
    source.read=(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        return consume(p.view(), typeof(p.view()).init)?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    auto r=request(1,1,MosaicFilter.area); MosaicFrame frame; MosaicMetrics metrics;
    enforce(tryAssembleMosaicOwned([source],r,frame,metrics)==MosaicError.none);
    enforce(bytes(frame)==[188,188,188,255,1],"linear-light midpoint");
    // Hidden red cannot contaminate an adjacent opaque blue pixel.
    p=owner([255,0,0,0,0,0,255,255],2,1,4,true);
    r.filter=MosaicFilter.bilinear;
    enforce(tryAssembleMosaicOwned([source],r,frame,metrics)==MosaicError.none);
    enforce(bytes(frame)==[0,0,255,128,1],"premultiplied filtering halo");
    // NoData on a zero bilinear tap must not exclude an exact center sample.
    p=owner([0,0,0,255,255,0,0,255],2,1,4,false);
    auto mask=owner([1,0],2,1,1,true);
    source.read=(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        return consume(p.view(),mask.view())?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    r=request(2,1,MosaicFilter.bilinear);
    enforce(tryAssembleMosaicOwned([source],r,frame,metrics)==MosaicError.none);
    enforce(bytes(frame)==[0,0,0,255,1,0,0,0,0,0],"zero-tap validity and valid black");
    r=request(1,1,MosaicFilter.area);
    enforce(tryAssembleMosaicOwned([source],r,frame,metrics)==MosaicError.none && bytes(frame)==[0,0,0,0,0]);
    source.read=(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        auto transparent=owner([255,1,93,0,17,255,1,0],2,1,4,false);
        return consume(transparent.view(),typeof(mask.view()).init)?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    enforce(tryAssembleMosaicOwned([source],r,frame,metrics)==MosaicError.none && bytes(frame)==[0,0,0,0,1]);
}

private size_t failures() @safe
{
    MosaicSource[] sources=[fixture(0,false)];
    auto r=request(11,9,MosaicFilter.bilinear);
    MosaicFrame frame; MosaicMetrics metrics;
    enforce(tryAssembleMosaicOwned(sources,r,frame,metrics)==MosaicError.none);
    auto retained=frame;
    const before=bytes(frame), work=metrics.workBytes, reads=metrics.tileReads, taps=metrics.sourceSamples;
    size_t checks;
    void check(MosaicError expected) @safe
    {
        enforce(tryAssembleMosaicOwned(sources,r,frame,metrics)==expected,"mosaic error classification");
        enforce(bytes(frame)==before && bytes(retained)==before && frame.region==retained.region,
            "mosaic atomic failure");
        ++checks;
    }
    --r.maxResultBytes; check(MosaicError.resultExceedsBudget); ++r.maxResultBytes;
    r.maxWorkBytes=work-1; check(MosaicError.workExceedsBudget); r.maxWorkBytes=work;
    enforce(tryAssembleMosaicOwned(sources,r,frame,metrics)==MosaicError.none && bytes(frame)==before);
    r.maxSourceSamples=taps-1; check(MosaicError.sampleBudgetExceeded); r.maxSourceSamples=100_000_000;
    r.maxTileReads=reads-1; check(MosaicError.tileBudgetExceeded); r.maxTileReads=100_000;
    r.region=Region2D(10,0,2,1); check(MosaicError.invalidRequest); r.region=retained.region;
    r.filter=MosaicFilter.unspecified; check(MosaicError.invalidFilter); r.filter=MosaicFilter.bilinear;
    sources[0].association=RgbaAlphaAssociation.premultiplied; check(MosaicError.invalidSource);
    sources[0].association=RgbaAlphaAssociation.straight;
    sources[0].quality=QualityContributor(false,double.nan); check(MosaicError.invalidQuality);
    sources[0].quality=QualityContributor(true);
    sources[0].qualityRead=(size_t l,Region2D b,scope QualityContributor[] q) @safe {
        q[$-1]=QualityContributor(false,1,double.infinity); return true;
    };
    check(MosaicError.invalidQuality); sources[0]=fixture(0,false);
    r.cancelled=() @safe {return true;}; check(MosaicError.cancelled); r.cancelled=null;
    auto original=sources[0].read;
    bool cancel;
    r.cancelled=() @safe {return cancel;};
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        const result=original(l,x,y,consume); cancel=true; return result;
    };
    check(MosaicError.cancelled); cancel=false; r.cancelled=null;
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        throw new Exception("provider failed");
    };
    check(MosaicError.callbackException);
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {return MosaicTileStatus.ready;};
    check(MosaicError.readFailure);
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        original(l,x,y,consume); return MosaicTileStatus.missing;
    };
    check(MosaicError.readFailure);
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        original(l,x,y,consume); return original(l,x,y,consume);
    };
    check(MosaicError.readFailure);
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        auto wrong=owner([1,2,3,4],1,1,4,false);
        return consume(wrong.view(),typeof(wrong.view()).init)?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    check(MosaicError.readFailure);
    sources[0]=fixture(0,false);
    r=request(47,33,MosaicFilter.area); check(MosaicError.invalidFilter);
    // One missing tap: block poll, provider poll, then final publication poll.
    sources[0].qualityRead=null;
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {return MosaicTileStatus.missing;};
    r=request(1,1,MosaicFilter.nearest);
    size_t polls;
    r.cancelled=() @safe {return ++polls==3;};
    check(MosaicError.cancelled); enforce(polls==3); r.cancelled=null;
    // Huge metadata-only image: a tiny viewport needs one provider tile.
    sources[0].levels=[OverviewLevel(1UL<<30,1UL<<30)]; sources[0].tileWidth=4; sources[0].tileHeight=4;
    sources[0].qualityRead=null;
    size_t active,peak,loaded;
    sources[0].read=(size_t l,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        ++active; peak=max(peak,active); ++loaded;
        scope(exit)--active;
        auto data=new ubyte[4*4*4]; data[]=255;
        auto pixels=owner(data,4,4,4,false);
        return consume(pixels.view(),typeof(pixels.view()).init)?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    r=request(1UL<<30,1UL<<30,MosaicFilter.nearest);
    r.region=Region2D((1UL<<30)-4,(1UL<<30)-4,2,2); r.maxResultBytes=20;
    enforce(tryAssembleMosaicOwned(sources,r,frame,metrics)==MosaicError.none);
    enforce(metrics.resultBytes==20 && metrics.tileReads==1 && loaded==1 && active==0 && peak==1);
    enforce(bytes(retained)==before,"retained output survives successful replacement");
    // An enormous area footprint is rejected before a single provider call.
    r=request(1,1,MosaicFilter.area); r.maxSourceSamples=1_000_000;
    loaded=0;
    const preserved=bytes(frame);
    enforce(tryAssembleMosaicOwned(sources,r,frame,metrics)==MosaicError.sampleBudgetExceeded &&
        loaded==0 && bytes(frame)==preserved);
    return checks+2;
}

void checkMosaic(ref JSONValue root) @safe
{
    root["mosaic_partition_pixels"]=JSONValue(integration(root));
    laws();
    root["mosaic_failure_checks"]=JSONValue(failures());
    auto source=fixture(0,false);
    source.levels=[OverviewLevel(256,16)]; source.tileWidth=source.tileHeight=256;
    source.qualityRead=null; source.quality=QualityContributor(false);
    auto many=new MosaicSource[16]; many[]=source;
    auto r=request(256,16,MosaicFilter.nearest);
    MosaicFrame frame; MosaicMetrics metrics;
    enforce(tryAssembleMosaicOwned(many,r,frame,metrics)==MosaicError.none && metrics.tileReads==0);
    enforce(metrics.workBytes==6_029_952 && metrics.workBytes<=8*1024*1024);
    root["mosaic_peak_work_bytes"]=JSONValue(metrics.workBytes);
}

void benchmarkMosaic()
{
    import core.time : MonoTime;
    import std.stdio : writeln, stdout;
    foreach (resident; [true,false])
    {
    MosaicSource[] sources;
    // Keep RAII owners alive until all synchronous provider calls finish.
    // Capturing a loop-local lease does not extend its destruction scope.
    RasterLease!ubyte[3] residentTiles;
    foreach (s; 0 .. 3)
    {
        auto source=fixture(s,false);
        source.levels=[OverviewLevel(1536,1536)]; source.tileWidth=256; source.tileHeight=256;
        source.qualityRead=null;
        auto tileData=new ubyte[256*256*4]; tileData[]=173;
        residentTiles[s]=owner(tileData,256,256,4,false);
        const index=s;
        source.read=(size_t l,size_t tx,size_t ty,scope MosaicTileConsumer consume) @safe {
            if (resident) return consume(residentTiles[index].view(),typeof(residentTiles[index].view()).init)?
                MosaicTileStatus.ready:MosaicTileStatus.failed;
            auto data=new ubyte[256*256*4]; data[]=173;
            auto pixels=owner(data,256,256,4,false);
            return consume(pixels.view(),typeof(pixels.view()).init)?MosaicTileStatus.ready:MosaicTileStatus.failed;
        };
        sources~=source;
    }
    foreach(n;[1,3]) foreach(filter;[MosaicFilter.nearest,MosaicFilter.bilinear,MosaicFilter.area])
    {
        auto r=request(512,512,filter);
        MosaicFrame frame; MosaicMetrics metrics;
        enforce(tryAssembleMosaicOwned(sources[0..n],r,frame,metrics)==MosaicError.none);
        double[] times; ulong checksum;
        foreach(repeat;0..5)
        {
            const start=MonoTime.currTime;
            enforce(tryAssembleMosaicOwned(sources[0..n],r,frame,metrics)==MosaicError.none);
            times~=(MonoTime.currTime-start).total!"nsecs"/1e6;
            const data=bytes(frame); foreach(value;data)checksum+=value;
        }
        sort(times);
        writeln("MOSAIC provider=",resident?"resident":"generated"," n=",n," filter=",filter," median_ms=",times[2]," min=",times[0]," max=",times[$-1],
            " work_bytes=",metrics.workBytes," loads=",metrics.tileReads," taps=",metrics.sourceSamples," checksum=",checksum);
        stdout.flush();
    }
    }
}
