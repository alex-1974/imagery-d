module tunable_checks;

import imagery.analysis.feature_regions;
import raster.region : Region2D;
import std.exception : enforce;
import std.math : abs, PI, cos, sin, exp, sqrt, ceil;
import std.algorithm : max;

private struct ParameterMetrics
{
    double shadowError=0;
    size_t peakBytes;
}

private Source fixture(ref size_t reads)
{
    Source source;
    source.identity="tunable-parameters"; source.revision="1"; source.grid="pixels";
    source.band="RGB"; source.unit="1"; source.rgb=true;
    source.width=73; source.height=69;
    source.read=(Region2D r, scope Sample[] samples) {
        ++reads;
        foreach(i,ref s;samples) {
            const x=r.x+i%r.width, y=r.y+i/r.width;
            const v=cast(ubyte)((x*7+y*19+x*y)%256);
            s=Sample(0,[v,v,v],x!=39 || y!=38);
        }
    };
    return source;
}

private void compare(Value actual, Value expected, double tolerance=0) @safe
{
    enforce(actual.valid==expected.valid && actual.orientationValid==expected.orientationValid);
    if(actual.valid) foreach(c;0..3)
        enforce(abs(actual.channels[c]-expected.channels[c])<=tolerance);
}

private void checkRequest(P)(const Source source, ref size_t reads, Feature feature, P parameters,
    ref ParameterMetrics metrics)
{
    const full=Region2D(0,0,source.width,source.height);
    auto whole=new Value[source.width*source.height];
    Engine a;
    a.run(source,full,feature,256,parameters,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            foreach(i,v;values) whole[(r.y+i/r.width)*source.width+r.x+i%r.width]=v;
        });
    const before=reads;
    const allocations=a.metrics.scratchAllocations;
    a.run(source,full,feature,256,parameters,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            foreach(i,v;values) compare(v,whole[(r.y+i/r.width)*source.width+r.x+i%r.width]);
        });
    enforce(reads==before && a.hits==1 && a.metrics.scratchAllocations==allocations);
    foreach(region;[full,Region2D(11,7,41,43),Region2D(71,0,2,3)]) {
        Engine b;
        b.run(source,region,feature,7,parameters,
            (Region2D r,scope const(Value)[] values,Provenance p) {
                foreach(i,v;values) {
                    const prior=whole[(r.y+i/r.width)*source.width+r.x+i%r.width];
                    compare(v,prior,feature==Feature.shadowCandidate?1e-14:0);
                    if(feature==Feature.shadowCandidate && v.valid)
                        metrics.shadowError=max(metrics.shadowError,abs(v.channels[0]-prior.channels[0]));
                }
            });
        enforce(b.metrics.peakTileBytes<=8*1024*1024);
        metrics.peakBytes=max(metrics.peakBytes,b.metrics.peakTileBytes);
    }
    Engine c;
    auto defaults=new Value[whole.length];
    c.run(source,full,feature,256,
        (Region2D r,scope const(Value)[] values,Provenance p) { defaults[]=values; });
    const fixedReads=reads;
    c.run(source,full,feature,256,P.init,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            foreach(i,v;values) compare(v,defaults[i]);
            enforce(p.parameters==describeFeature(feature).parameters);
        });
    enforce(reads==fixedReads && c.hits==1);
    c.run(source,full,feature,256,parameters,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            enforce(p.parameters!=describeFeature(feature).parameters);
        });
    enforce(reads>fixedReads); // nondefault output must not alias a default cache tile
}

// Raw result digests allow comparison with the parent commit using exactly
// the same fixture, compiler and libc (including invalid result payloads).
string defaultParameterDigests()
{
    import std.digest.sha : SHA256;
    import std.digest : toHexString;
    import std.bitmanip : nativeToBigEndian;
    import std.conv : to;
    size_t reads;
    auto source=fixture(reads);
    Engine engine;
    string text;
    foreach(feature;[Feature.ridge,Feature.lineResponse,Feature.gabor,
        Feature.gaborFine0,Feature.gaborFine45,Feature.gaborFine90,Feature.gaborFine135,
        Feature.gaborCoarse0,Feature.gaborCoarse45,Feature.gaborCoarse90,Feature.gaborCoarse135,
        Feature.shadowCandidate,Feature.clahe]) {
        SHA256 digest;
        void consume(Region2D r,scope const(Value)[] values,Provenance p) {
            foreach(v;values) {
                foreach(c;v.channels) digest.put(nativeToBigEndian(c)[]);
                ubyte[2] flags=[cast(ubyte)v.valid,cast(ubyte)v.orientationValid];
                digest.put(flags[]);
            }
        }
        const region=Region2D(0,0,source.width,source.height);
        if(feature==Feature.clahe) equalizeLuminanceLocally(engine,source,region,256,&consume);
        else engine.run(source,region,feature,256,&consume);
        text~=feature.to!string~" "~toHexString(digest.finish())~"\n";
    }
    return text;
}

void checkTunables()
{
    ParameterMetrics metrics;
    size_t reads;
    auto source=fixture(reads);
    checkRequest(source,reads,Feature.ridge,RidgeParams(2,7),metrics);
    checkRequest(source,reads,Feature.lineResponse,LineResponseParams(RidgeParams(2,5),3),metrics);
    checkRequest(source,reads,Feature.shadowCandidate,ShadowParams(LocalStatisticsParams(2,11),0.27),metrics);
    GaborParams gabor;
    gabor.wavelengths=[1.5,5.25]; gabor.angles=[0.1,0.7,1.4,2.2];
    gabor.sigmaRatio=0.7; gabor.supportRatio=1.5;
    foreach(f;[Feature.gabor,Feature.gaborFine45,Feature.gaborCoarse135])
        checkRequest(source,reads,f,gabor,metrics);

    // Independent scalar bank formula at an interior center: catches ignored
    // wavelength, angle, envelope and support parameters, beyond tiling laws.
    auto luminance=new Value[source.width*source.height];
    Engine oracle;
    oracle.run(source,Region2D(0,0,source.width,source.height),Feature.luminance,256,
        (Region2D r,scope const(Value)[] values,Provenance p) { luminance[]=values; });
    double best=0, angle=0, scale=0;
    const cx=20,cy=18;
    const center=luminance[cy*source.width+cx].channels[0];
    foreach(w;gabor.wavelengths) foreach(theta;gabor.angles) {
        double re=0,im=0,sum=0;
        const radius=cast(int)ceil(w*gabor.supportRatio);
        foreach(y;-radius..radius+1)foreach(x;-radius..radius+1) {
            const weight=exp(-(x*x+y*y)/(2*(w*gabor.sigmaRatio)^^2));
            const phase=2*PI*(x*cos(theta)+y*sin(theta))/w;
            const delta=luminance[(cy+y)*source.width+cx+x].channels[0]-center;
            re+=delta*weight*cos(phase); im+=delta*weight*sin(phase); sum+=weight;
        }
        const response=sqrt(re*re+im*im)/sum;
        if(response>best) { best=response;angle=theta;scale=w; }
    }
    double gaborError=0;
    oracle.run(source,Region2D(cx,cy,1,1),Feature.gabor,1,gabor,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            enforce(values[0].valid && abs(values[0].channels[0]-best)<1e-15);
            gaborError=abs(values[0].channels[0]-best);
            enforce(values[0].channels[1]==angle && values[0].channels[2]==scale);
        });

    // Different adjacent floating values must have distinct cache identities.
    Engine adjacent;
    const tiny=Region2D(12,12,1,1);
    auto s=ShadowParams.init;
    string first;
    adjacent.run(source,tiny,Feature.shadowCandidate,1,s,
        (Region2D,scope const(Value)[],Provenance p) { first=p.parameters; });
    s.luminanceCeiling=0.15000000000000002;
    const beforeAdjacent=reads;
    adjacent.run(source,tiny,Feature.shadowCandidate,1,s,
        (Region2D,scope const(Value)[],Provenance p) { enforce(first!=p.parameters); });
    enforce(reads>beforeAdjacent);

    const full=Region2D(0,0,source.width,source.height);
    auto defaultClahe=new Value[source.width*source.height];
    foreach(params;[ClaheParams.init,ClaheParams(8,0.7),ClaheParams(18,3.5),ClaheParams(128,256)]) {
        Engine a,b;
        auto whole=new Value[source.width*source.height];
        equalizeLuminanceLocally(a,source,full,256,params,
            (Region2D r,scope const(Value)[] values,Provenance p) {
                whole[]=values;
                enforce((p.parameters==describeFeature(Feature.clahe).parameters)==(params==ClaheParams.init));
            });
        if(params==ClaheParams.init) defaultClahe[]=whole;
        else {
            bool changed;
            foreach(i,v;whole) if(v.valid && abs(v.channels[0]-defaultClahe[i].channels[0])>1e-12) changed=true;
            enforce(changed);
        }
        foreach(region;[full,Region2D(11,7,41,43),Region2D(71,0,2,3)])
            equalizeLuminanceLocally(b,source,region,7,params,
                (Region2D r,scope const(Value)[] values,Provenance p) {
                    foreach(i,v;values) compare(v,whole[(r.y+i/r.width)*source.width+r.x+i%r.width]);
                });
        if(params==ClaheParams.init)
            equalizeLuminanceLocally(b,source,full,256,
                (Region2D r,scope const(Value)[] values,Provenance p) { foreach(i,v;values)compare(v,whole[i]); });
        enforce(a.metrics.peakTileBytes<=8*1024*1024 && b.metrics.peakTileBytes<=8*1024*1024);
        metrics.peakBytes=max(metrics.peakBytes,max(a.metrics.peakTileBytes,b.metrics.peakTileBytes));
    }

    // Maximum accepted halos on a large procedural source: source reads grow
    // with support, scratch remains bounded independently of dataset extent.
    auto large=source; large.width=large.height=1_000_000;
    size_t readWidth,readHeight;
    large.read=(Region2D r,scope Sample[] samples) {
        readWidth=r.width; readHeight=r.height;
        samples[]=Sample(0,[42,42,42],true);
    };
    void maximum(P)(Feature feature,P params,size_t halo) {
        Engine e;
        e.run(large,Region2D(100,100,1,1),feature,256,params,
            (Region2D,scope const(Value)[] values,Provenance) {
                enforce(values[0].valid && values[0].channels[0]==0 && !values[0].orientationValid);
            });
        enforce(readWidth==2*halo+1 && readHeight==2*halo+1);
        enforce(e.metrics.peakTileBytes<=8*1024*1024);
        metrics.peakBytes=max(metrics.peakBytes,e.metrics.peakTileBytes);
    }
    maximum(Feature.ridge,RidgeParams(1,31),31);
    maximum(Feature.lineResponse,LineResponseParams(RidgeParams(1,31),31),62);
    gabor=GaborParams.init; gabor.wavelengths=[8.0,16.0]; gabor.supportRatio=2;
    maximum(Feature.gabor,gabor,32);
    Engine boundedClahe;
    equalizeLuminanceLocally(boundedClahe,large,Region2D(100,100,1,1),256,ClaheParams(8,2),
        (Region2D,scope const(Value)[] values,Provenance) { enforce(values[0].valid); });
    enforce(boundedClahe.metrics.peakTileBytes<=8*1024*1024);
    metrics.peakBytes=max(metrics.peakBytes,boundedClahe.metrics.peakTileBytes);

    Engine invalid;
    void reject(P)(Feature f,P parameters) {
        const before=reads;
        bool caught;
        try { invalid.run(source,full,f,256,parameters,(Region2D,scope const(Value)[],Provenance){}); }
        catch(Exception) { caught=true; }
        enforce(caught && reads==before && invalid.metrics.scratchAllocations==0);
    }
    reject(Feature.ridge,RidgeParams(0,3));
    reject(Feature.ridge,RidgeParams(5,4));
    reject(Feature.ridge,RidgeParams(1,32));
    reject(Feature.lineResponse,LineResponseParams(RidgeParams.init,32));
    reject(Feature.shadowCandidate,ShadowParams(LocalStatisticsParams.init,double.nan));
    reject(Feature.shadowCandidate,ShadowParams(LocalStatisticsParams.init,0));
    reject(Feature.ridge,ShadowParams.init);
    gabor.angles[2]=double.infinity; reject(Feature.gabor,gabor);
    gabor=GaborParams.init; gabor.wavelengths[1]=1; reject(Feature.gabor,gabor);
    gabor=GaborParams.init; gabor.supportRatio=100; reject(Feature.gabor,gabor);
    gabor=GaborParams.init; gabor.sigmaRatio=double.nan; reject(Feature.gabor,gabor);
    foreach(params;[ClaheParams(7,2),ClaheParams(9,2),ClaheParams(130,2),ClaheParams(32,0),ClaheParams(32,double.nan)]) {
        const before=reads;
        bool caught;
        try { equalizeLuminanceLocally(invalid,source,full,256,params,(Region2D,scope const(Value)[],Provenance){}); }
        catch(Exception) { caught=true; }
        enforce(caught && reads==before && invalid.metrics.scratchAllocations==0);
    }
    import std.stdio : stderr;
    stderr.writefln("Typed parameters: Gabor oracle error=%.12g; shadow partition error=%.12g; peak scratch=%s",
        gaborError,metrics.shadowError,metrics.peakBytes);
}
