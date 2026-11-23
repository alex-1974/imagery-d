module imagery.analysis.prepared_measure;

import imagery.analysis.canny_worker;
import imagery.analysis.primitives : canny;
import imagery.analysis.cost_path;
import raster.region : Region2D;
import core.memory : GC;
import core.time : MonoTime;
import std.algorithm : sort;
import std.stdio : writeln,writefln;
import std.exception : enforce;

void runCannyWorkspaceBench(size_t size,size_t repeats)
{
    auto input=new float[size*size];
    foreach(y;0..size)foreach(x;0..size)input[y*size+x]=cast(float)((x*37+y*17+x*y%97)&255)/255;
    auto expected=new ubyte[input.length],edges=new ubyte[input.length];
    canny(input,size,size,.15f,.3f,expected);
    CannyWorkspace workspace;
    const begin=MonoTime.currTime;workspace.prepare(size,size);
    const setup=(MonoTime.currTime-begin).total!"nsecs";
    writeln("operator,mode,size,ns_per_pixel,gc_bytes,computed_tiles,checksum,setup_ns,payload_bytes");
    foreach(prepared;[false,true]) {
        long[] timings;ulong allocated,checksum;
        foreach(run;0..repeats+1) {
            const before=GC.stats().allocatedInCurrentThread,start=MonoTime.currTime;
            if(prepared)enforce(workspace.tryRun(input,size,size,.15f,.3f,edges)==CannyWorkerError.none);
            else canny(input,size,size,.15f,.3f,edges);
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            enforce(edges==expected,"Prepared Canny differs from finite scalar reference");
            if(run){timings~=elapsed;allocated+=bytes;}
            foreach(edge;edges)checksum+=edge;
        }
        timings.sort;
        writefln("canny,%s,%s,%.3f,%s,%s,%s,%s,%s",prepared?"prepared-global":"legacy-global",size,
            cast(double)timings[$/2]/input.length,allocated/repeats,repeats,checksum,prepared?setup:0,
            prepared?workspace.storageBytes:input.length*(4*float.sizeof+size_t.sizeof));
        if(prepared)enforce(allocated==0,"Prepared Canny allocated");
    }
}

private struct FormulaCosts {
    double opCall(size_t x,size_t y) @safe nothrow @nogc {return 1+cast(double)((x*3+y*5)%17)/16;}
}

void runEpochBench(size_t size,size_t repeats)
{
    const edge=size<256?size:256,windowPixels=edge*edge;
    writeln("mode,global_pixels,reserved_pixels,payload_bytes,setup_ns,normal_reset_ns,wrap_reset_ns,query_ns,gc_bytes,cost_evaluations,checksum");
    foreach(full;[false,true]) {
        LazyCostPath!FormulaCosts search;
        const capacity=full?size*size:windowPixels,start=MonoTime.currTime;
        search.prepare(FormulaCosts.init,size,size,capacity);
        const setup=(MonoTime.currTime-start).total!"nsecs";
        size_t[1] seed=[0];const window=Region2D(0,0,edge,edge);
        long normalTotal,wrapTotal;size_t ordinary,wraps;double checksum=0;ulong calls;
        const before=GC.stats().allocatedInCurrentThread;
        // More than one ushort epoch exercises its exceptional full clear.
        foreach(i;0..65537) {
            const resetStart=MonoTime.currTime;
            const error=search.reset(seed[],window);
            const elapsed=(MonoTime.currTime-resetStart).total!"nsecs";
            enforce(error==PathSearchError.none);
            if(search.epochCleared){wrapTotal+=elapsed;++wraps;}else {normalTotal+=elapsed;++ordinary;}
        }
        const queryStart=MonoTime.currTime;
        const queries=repeats*32;
        foreach(i;0..queries) {
            // The graph and seed move, so every request is actual new work.
            const shift=(size-edge)?i%(size-edge+1):0;
            seed[0]=shift*size+shift;
            enforce(search.reset(seed[],Region2D(shift,shift,edge,edge))==PathSearchError.none);
            const target=(shift+edge/4)*size+shift+edge/4;
            enforce(search.advance(target));checksum+=search.distanceTo(target);calls+=search.costEvaluations;
        }
        const queryTime=(MonoTime.currTime-queryStart).total!"nsecs";
        const bytes=GC.stats().allocatedInCurrentThread-before;
        enforce(bytes==0&&wraps==1&&calls>0,"Epoch allocation/clear/lazy evaluation probe");
        writefln("%s,%s,%s,%s,%s,%.3f,%s,%.3f,%s,%s,%.12g",full?"full-reservation":"window-reservation",
            size*size,capacity,search.storageBytes,setup,cast(double)normalTotal/ordinary,wrapTotal/wraps,
            cast(double)queryTime/queries,bytes,calls,checksum);
    }
}
