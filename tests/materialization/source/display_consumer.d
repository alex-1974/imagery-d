module display_consumer;

import imagery.mosaic.multiresolution;
import imagery.mosaic.validity_policy : QualityContributor;
import imagery.mosaic.decoded_tile_mosaic : RgbaAlphaAssociation;
import imagery.pyramid.overview_selection : OverviewLevel;
import imageio : readPng;
import compression.deflate : InflateWorkspace;
import raster : RasterLease,RasterView,OwnedByteResource,PlaneByteLayout,Region2D,
    tryAdoptMallocResource,tryImportOwnedRaster,RasterPlaneWindow,withPlane;
import core.stdc.stdlib : malloc,free;
import core.time : MonoTime;
import core.memory : GC;
import std.algorithm : min,sort;
import std.conv : to;
import std.exception : enforce;
import std.file : read,readText,write;
import std.json : JSONValue,parseJSON;
import std.stdio : writeln;

// Test-only validated copy/import; ownership transfers exactly once to raster-d.
private RasterLease!ubyte own(scope const(ubyte)[] data,size_t w,size_t h,size_t bands) @trusted
{
    enforce(w&&h&&(bands==1||bands==4)&&w<=4096&&h<=4096&&data.length==w*h*bands);
    auto p=cast(ubyte*)malloc(data.length);enforce(p !is null);p[0..data.length]=data[];
    OwnedByteResource resource;
    if(!tryAdoptMallocResource(p,data.length,resource)){free(p);throw new Exception("adopt failed");}
    PlaneByteLayout[4] layouts;
    foreach(c;0..bands)layouts[c]=PlaneByteLayout(c,cast(ptrdiff_t)(w*bands),cast(ptrdiff_t)bands);
    RasterLease!ubyte result;
    enforce(tryImportOwnedRaster!ubyte(resource,layouts[0..bands],Region2D(0,0,w,h),result).ok);
    return result;
}
private ubyte[] bytes(ref MosaicFrame frame) @safe
{
    scope auto rgba=frame.rgba.view(),mask=frame.validity.view();
    return bytes(rgba,mask);
}
private ubyte[] bytes(scope RasterView!ubyte rgba,scope RasterView!ubyte mask) @safe
{
    auto result=new ubyte[rgba.width*rgba.height*5];
    foreach(c;0..4)enforce(withPlane(rgba,c,(scope ref const RasterPlaneWindow!ubyte plane) @safe {
        foreach(y;0..rgba.height){scope const row=plane.row(y);
            foreach(x;0..rgba.width)result[5*(y*rgba.width+x)+c]=row.load(x);}}));
    enforce(withPlane(mask,0,(scope ref const RasterPlaneWindow!ubyte plane) @safe {
        foreach(y;0..rgba.height){scope const row=plane.row(y);
            foreach(x;0..rgba.width)result[5*(y*rgba.width+x)+4]=row.load(x);}}));
    return result;
}

void runDisplay(string path)
{
    auto manifest=parseJSON(readText(path));auto levels=manifest["levels"].array;
    const prepared="workspace" in manifest.object && manifest["workspace"].boolean;
    enforce(levels.length==2);
    RasterLease!ubyte[2] pixels,masks;OverviewLevel[] grids;
    size_t cacheBytes;const prepare=MonoTime.currTime;
    foreach(i,level;levels)
    {
        const w=level["width"].integer.to!size_t,h=level["height"].integer.to!size_t;
        enforce(w<=4096&&h<=4096);auto decoded=new ubyte[w*h*4];
        const file=cast(const(ubyte)[])read(level["path"].str);
        InflateWorkspace workspace;const status=readPng(file,decoded,w*4,workspace);
        enforce(status.complete&&status.bytesProduced==decoded.length,"actual imageio RGBA PNG decode");
        pixels[i]=own(decoded,w,h,4);decoded[]=0; // decoder lifetime must not leak into cache
        cacheBytes+=w*h*4;
        if("mask" in level.object)
        {auto mask=cast(const(ubyte)[])read(level["mask"].str);masks[i]=own(mask,w,h,1);cacheBytes+=mask.length;}
        grids~=OverviewLevel(w,h);
    }
    const prepareNs=(MonoTime.currTime-prepare).total!"nsecs";
    MosaicSource source;
    source.identity=manifest["identity"].str;source.revision=manifest["revision"].str;
    source.grid="display-common-extent";source.qualityPolicy="explicit-neutral";source.qualityRevision="1";
    source.association=RgbaAlphaAssociation.straight;source.quality=QualityContributor(true);
    source.tileWidth=source.tileHeight=256;source.levels=grids;
    source.read=(size_t level,size_t tx,size_t ty,scope MosaicTileConsumer consume) @safe {
        const w=grids[level].width,h=grids[level].height;
        const r=Region2D(tx*256,ty*256,min(256,w-tx*256),min(256,h-ty*256));
        scope auto full=pixels[level].view();bool ok;
        scope auto tile=full.tryRoi(r,ok);if(!ok)return MosaicTileStatus.failed;
        if(masks[level].view().planeCount)
        {scope auto allMask=masks[level].view();scope auto mask=allMask.tryRoi(r,ok);
            return ok&&consume(tile,mask)?MosaicTileStatus.ready:MosaicTileStatus.failed;}
        return consume(tile,RasterView!ubyte.init)?MosaicTileStatus.ready:MosaicTileStatus.failed;
    };
    auto sources=[source];
    JSONValue result;result["prepare_ns"]=JSONValue(prepareNs);result["provider_cache_bytes"]=JSONValue(cacheBytes);
    JSONValue[] modes;
    foreach(mode;0..4)
    {
        const filter=mode<2?MosaicFilter.nearest:mode==2?MosaicFilter.bilinear:MosaicFilter.area;
        MosaicRequest q;q.targetWidth=grids[1].width;q.targetHeight=grids[1].height;
        if(mode==1){q.targetWidth-=13;q.targetHeight-=9;}
        q.filter=filter;q.region=Region2D(7,7,512,512);q.maxResultBytes=512*512*5;
        q.maxWorkBytes=8*1024*1024;q.maxSourceSamples=100_000_000;q.maxTileReads=10000;
        MosaicFrame frame;MosaicMetrics metrics;
        enforce(tryAssembleMosaicOwned(sources,q,frame,metrics)==MosaicError.none);
        auto retained=frame;const beforePixels=bytes(retained);
        MosaicDisplayWorkspace workspace;
        long assemblyNs;size_t assemblyGc;MonoTime start;size_t gcBefore;
        bool capture;ubyte[] captured;
        MosaicDisplayConsumer visitor=(scope RasterView!ubyte rgba,scope RasterView!ubyte mask,MosaicDisplayInfo info) @safe {
            assemblyNs=(MonoTime.currTime-start).total!"nsecs";
            assemblyGc=GC.stats.allocatedInCurrentThread-gcBefore;
            enforce(info.region==q.region&&info.sources[0].selection.index==1);
            if(capture)captured=bytes(rgba,mask);
            return true;
        };
        if(prepared)
        {
            capture=true;start=MonoTime.currTime;gcBefore=GC.stats.allocatedInCurrentThread;
            enforce(workspace.tryVisit(sources,q,visitor,metrics)==MosaicError.none);
            enforce(captured==beforePixels);capture=false;
        }
        long[] timings;size_t[] allocated;Region2D last;
        foreach(round;0..106)
        {
            q.region=Region2D(7+(round*11)%(q.targetWidth-512-7),7+(round*13)%(q.targetHeight-512-7),512,512);
            const gc=GC.stats.allocatedInCurrentThread;start=MonoTime.currTime;
            if(prepared)
            {gcBefore=gc;capture=round==105;enforce(workspace.tryVisit(sources,q,visitor,metrics)==MosaicError.none);}
            else enforce(tryAssembleMosaicOwned(sources,q,frame,metrics)==MosaicError.none);
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const allocatedBytes=GC.stats.allocatedInCurrentThread-gc;
            if(round>=5){timings~=prepared?assemblyNs:elapsed;allocated~=prepared?assemblyGc:allocatedBytes;}
            enforce(metrics.copiedPixels==0);
            if(prepared)enforce(metrics.reusedOutput&&metrics.allocatedOutputBytes==0);
            last=q.region;
        }
        enforce(bytes(retained)==beforePixels,"display owner/alias survives moving viewport publication");
        const output=manifest["output_directory"].str~"/mode-"~mode.to!string~".raw";
        write(output,prepared?captured:bytes(frame));
        auto ordered=timings.dup;sort(ordered);
        JSONValue item;item["mode"]=JSONValue(mode);item["filter"]=JSONValue(filter.to!string);
        item["target"]=JSONValue([q.targetWidth,q.targetHeight]);
        item["region"]=JSONValue([last.x,last.y,last.width,last.height]);
        item["round_ns"]=JSONValue(timings);item["gc_bytes"]=JSONValue(allocated);
        item["median_ns"]=JSONValue(ordered[ordered.length/2]);item["p95_ns"]=JSONValue(ordered[ordered.length*95/100]);
        item["max_ns"]=JSONValue(ordered[$-1]);item["work_bytes"]=JSONValue(metrics.workBytes);
        item["workspace"]=JSONValue(prepared);item["reused_output"]=JSONValue(metrics.reusedOutput);
        item["allocated_output_bytes"]=JSONValue(metrics.allocatedOutputBytes);
        item["provider_reads"]=JSONValue(metrics.tileReads);item["output"]=JSONValue(output);
        modes~=item;
    }
    result["modes"]=JSONValue(modes);writeln(result.toString);
}
