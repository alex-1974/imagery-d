module app;
import imagery.analysis.feature_overviews;
import imagery.analysis.feature_regions : Source, Sample;
import imagery.analysis.colour_indices;
import imagery.analysis.cost_path;
import imagery.analysis.quality;
import imagery.analysis.structure_tensor;
import raster.region : Region2D;
import core.memory : GC;
import std.json : JSONValue;
import std.stdio : writeln;
import std.exception : enforce;
import parameter_checks : checkParameters;
import tunable_checks : checkTunables, defaultParameterDigests;
import window_checks : checkWindows;
import hessian_checks : checkHessian;
import tensor_checks : checkTensor;
import cost_path_checks : checkCostPaths;
import path_morphology_checks : checkPathMorphology;
import worker32_checks : checkWorker32;
import quality_checks : checkQuality;
import primitive_checks : checkPrimitives;

void scene(string path, size_t width, size_t height)
{
    import std.file : read;
    import imagery.analysis.feature_regions : Engine, Feature, Value, Provenance, runFeatureView;
    import core.time : MonoTime;
    const bytes=cast(const(ubyte)[])read(path);
    enforce(width>=32 && height>=32 && width<=4096 && height<=4096 && bytes.length==width*height*3);
    Source source;
    source.identity="real-scene";source.revision="1";source.grid="pixel";
    source.band="RGB";source.unit="1";source.width=width;source.height=height;source.rgb=true;
    source.read=(Region2D r,scope Sample[] samples) {
        foreach(i,ref v;samples) {
            const p=3*((r.y+i/r.width)*width+r.x+i%r.width);
            v=Sample(0,[bytes[p],bytes[p+1],bytes[p+2]],true);
        }
    };
    Engine sceneEngine;
    auto gradient=new Value[width*height];
    auto region=Region2D(5,7,width-10,height-14);
    const started=MonoTime.currTime;
    runFeatureView(sceneEngine,source,region,[Feature.gradient,Feature.localStatistics],64,
        (Region2D r,scope const(Value)[] values,Provenance origin) {
            if(origin.feature==Feature.gradient) foreach(i,v;values)
                gradient[(r.y+i/r.width)*width+r.x+i%r.width]=v;
        });
    const before=sceneEngine.hits;
    runFeatureView(sceneEngine,source,region,[Feature.oklab,Feature.gradient],64,
        (Region2D r,scope const(Value)[] values,Provenance origin) {
            if(origin.feature==Feature.gradient) foreach(i,v;values)
                enforce(v==gradient[(r.y+i/r.width)*width+r.x+i%r.width]);
        });
    enforce(sceneEngine.hits>before);
    enforce(sceneEngine.metrics.peakCacheBytes<=16*1024*1024);
    JSONValue result;
    result["elapsed_ms"]=JSONValue((MonoTime.currTime-started).total!"msecs");
    result["cache_hits"]=JSONValue(sceneEngine.hits-before);
    result["peak_tile_bytes"]=JSONValue(sceneEngine.metrics.peakTileBytes);
    result["peak_cache_bytes"]=JSONValue(sceneEngine.metrics.peakCacheBytes);
    writeln(result.toString);
}

void main(string[] args)
{
    if(args.length==2 && args[1]=="--primitives") {
        JSONValue result;checkPrimitives(result);writeln(result.toString);return;
    }
    if(args.length==2 && args[1]=="--parameter-defaults") {
        import std.stdio : write;
        write(defaultParameterDigests());
        return;
    }
    if(args.length==5 && args[1]=="--rgb") {
        import std.conv : to;
        scene(args[2],args[3].to!size_t,args[4].to!size_t);
        return;
    }
    checkParameters();
    checkTunables();
    const windows=checkWindows();
    JSONValue root;
    root["window_max_mean_error"]=JSONValue(windows.maxMeanError);
    root["window_max_deviation_error"]=JSONValue(windows.maxDeviationError);
    root["window_samples"]=JSONValue(windows.samples);
    checkHessian(root);
    checkTensor(root);
    checkCostPaths(root);
    checkPathMorphology(root);
    checkWorker32(root);
    checkQuality(root);
    checkPrimitives(root);
    Source source;
    source.width=7; source.height=5; source.grid="oracle";
    source.band="scalar"; source.unit="1";
    source.read=(Region2D r, scope Sample[] outValues) {
        foreach(i,ref s;outValues) {
            const x=r.x+i%r.width, y=r.y+i/r.width;
            s=Sample(cast(double)((x*17+y*31+x*y)%97),[0,0,0],true);
        }
    };
    double[] original;
    foreach(y;0..5)foreach(x;0..7) original~=cast(double)((x*17+y*31+x*y)%97);
    root["area_input"]=JSONValue(original);
    JSONValue[] areas;
    foreach(w;1..8)foreach(h;1..6) {
        auto resized=resampleFeatureSource(source,w,h,1,FeatureResampling.areaScalar);
        auto values=new Sample[w*h]; resized.read(Region2D(0,0,w,h),values);
        double[] numbers; foreach(v;values) numbers~=v.scalar;
        JSONValue entry;
        entry["w"]=JSONValue(w);entry["h"]=JSONValue(h);entry["values"]=JSONValue(numbers);
        areas~=entry;
    }
    root["areas"]=JSONValue(areas);
    double[] costs; foreach(i;0..72) costs~=1.0+((i*37+i*i*11)%29)/7.0;
    size_t[2] seeds=[0,71];
    CostPath search; search.prepare(costs,9,8,seeds[]);
    double[] distances=new double[costs.length];
    size_t[72] path;
    const before=GC.stats().allocatedInCurrentThread;
    foreach(i;0..72) { enforce(search.advance(i)); distances[i]=search.distanceTo(i); enforce(search.pathTo(i,path[])>0); }
    enforce(GC.stats().allocatedInCurrentThread==before);
    root["costs"]=JSONValue(costs); root["distances"]=JSONValue(distances);
    JSONValue[] indices;
    foreach(domain;[RgbIndexDomain.encoded,RgbIndexDomain.linear]) {
        const v=rgbIndices([64,128,32],domain);
        indices~=JSONValue([v.excessGreen,v.r,v.g]);
    }
    root["indices"]=JSONValue(indices);
    float[] noise=new float[256*256];
    uint state=12345;
    foreach(ref v;noise) {
        double sample=0;
        foreach(k;0..12) { state=1664525*state+1013904223; sample+=cast(double)state/uint.max; }
        v=cast(float)((sample-6)*0.03+0.5);
    }
    auto scratch=new double[noise.length];
    RegionQuality quality;
    enforce(tryRegionQuality(noise,256,256,scratch,quality));
    enforce(quality.noiseSigma>0.027 && quality.noiseSigma<0.033);
    root["noise_sigma"]=JSONValue(quality.noiseSigma);
    float[] tensorInput=new float[17*19];
    foreach(i,ref v;tensorInput)v=cast(float)(((i%17)*7+(i/17)*13+i*i%19)/53.0);
    TensorWorkspace tensorScratch;tensorScratch.reserve(tensorInput.length);
    auto angles=new float[tensorInput.length], coherences=new float[tensorInput.length], energies=new float[tensorInput.length];
    auto valid=new ubyte[tensorInput.length];
    const tensorBefore=GC.stats().allocatedInCurrentThread;
    structureTensor(tensorInput,17,19,StructureTensorParams(1,2),tensorScratch,angles,coherences,energies,valid);
    enforce(GC.stats().allocatedInCurrentThread==tensorBefore);
    root["tensor_input"]=JSONValue(tensorInput);
    root["tensor_angles"]=JSONValue(angles);
    root["tensor_coherences"]=JSONValue(coherences);
    root["tensor_energies"]=JSONValue(energies);
    writeln(root.toString);
}
