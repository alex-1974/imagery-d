module path_morphology_checks;

import imagery.analysis.feature_regions;
import raster.region : Region2D;
import std.algorithm : min, max;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : isFinite, signbit;

private struct OraclePoint { double value; bool valid; }

void checkPathMorphology(ref JSONValue root)
{
    enum w=13,h=11;
    size_t comparisons;
    foreach(kind;0..5) {
        OraclePoint point(int x,int y) @safe {
            x=max(0,min(w-1,x));y=max(0,min(h-1,y));
            double value;
            switch(kind) {
                case 0:value=y==5 && x>=3 && x<=9?1:0;break;
                case 1:value=x>=5 && x<=7 && y>=4 && y<=6?1:0;break;
                case 2:value=((x*17+y*31+x*y)%49)/8.0;break;
                case 3:value=7;break;
                default:value=x>=2 && x<=6 && y==2*x-3?1:0;break;
            }
            return OraclePoint(value,kind!=2 || x!=6 || y!=5);
        }
        Source source;
        source.identity="path-enumeration";source.revision="1";source.grid="pixel";
        source.band="scalar";source.unit="1";source.width=w;source.height=h;
        source.read=(Region2D r,scope Sample[] samples) {
            foreach(i,ref sample;samples) {
                const p=point(cast(int)(r.x+i%r.width),cast(int)(r.y+i/r.width));
                sample=Sample(p.value,[0,0,0],p.valid);
            }
        };
        foreach(length;[1u,3u,5u])foreach(step;[0u,1u,2u])foreach(closing;[false,true]) {
            const missing=closing?double.infinity:-double.infinity;
            // Enumerate all lateral choices recursively, with no shared DP.
            double walk(int x,int y,bool vertical,int direction,uint left,double bottleneck) {
                if(!left)return bottleneck;
                double best=missing;
                foreach(lateral;-cast(int)step..cast(int)step+1) {
                    const nx=vertical?x+lateral:x+direction,ny=vertical?y+direction:y+lateral;
                    const p=point(nx,ny);
                    if(!p.valid)continue;
                    const value=walk(nx,ny,vertical,direction,left-1,
                        closing?max(bottleneck,p.value):min(bottleneck,p.value));
                    best=closing?min(best,value):max(best,value);
                }
                return best;
            }
            auto expected=new Value[w*h];
            foreach(y;0..h)foreach(x;0..w) {
                const center=point(x,y);
                if(!center.valid)continue;
                double best=missing;
                foreach(vertical;[false,true])foreach(split;0..length) {
                    const a=walk(x,y,vertical,-1,split,center.value);
                    const b=walk(x,y,vertical,1,length-1-split,center.value);
                    const value=closing?max(a,b):min(a,b);
                    best=closing?min(best,value):max(best,value);
                }
                if(isFinite(best))expected[y*w+x]=Value([best,0,0],true,false);
            }
            foreach(edge;[5UL,17UL]) {
                Engine engine;
                engine.run(source,Region2D(0,0,w,h),closing?Feature.pathClosing:Feature.pathOpening,
                    edge,PathMorphologyParams(length,step),
                    (Region2D r,scope const(Value)[] values,Provenance p) {
                        foreach(i,value;values) {
                            const index=(r.y+i/r.width)*w+r.x+i%r.width;
                            enforce(value.valid==expected[index].valid,"Enumerated path validity");
                            if(value.valid)enforce(value.channels==expected[index].channels,"Enumerated path value");
                            ++comparisons;
                        }
                    });
                enforce(engine.metrics.peakTileBytes<=8*1024*1024);
            }
            if(kind==1 && length==5 && !closing)
                enforce(expected[5*w+6].channels[0]==0,"Path removes a short blob");
            if(kind==4 && length==5 && !closing)
                enforce(expected[5*w+4].channels[0]==(step==2?1:0),"Lateral step selects a steep line");
        }
    }
    root["path_enumeration_comparisons"]=JSONValue(comparisons);
    // Signed-zero tie behavior remains on the original kernel fallback.
    Source negativeZero;
    negativeZero.identity="negative-zero";negativeZero.revision="1";negativeZero.grid="pixel";
    negativeZero.band="scalar";negativeZero.unit="1";negativeZero.width=negativeZero.height=3;
    negativeZero.read=(Region2D r,scope Sample[] samples) { samples[]=Sample(-0.0,[0,0,0],true); };
    foreach(feature;[Feature.pathOpening,Feature.pathClosing]) {
        Engine engine;
        engine.run(negativeZero,Region2D(0,0,3,3),feature,3,
            (Region2D r,scope const(Value)[] values,Provenance p) {
                foreach(value;values)enforce(value.valid && value.channels[0]==0 && signbit(value.channels[0]));
            });
    }
    auto isolated=negativeZero;isolated.identity="isolated-path";
    isolated.width=isolated.height=5;
    isolated.read=(Region2D r,scope Sample[] samples) {
        foreach(i,ref sample;samples)
            sample=Sample(1,[0,0,0],r.x+i%r.width==2 && r.y+i/r.width==2);
    };
    foreach(feature;[Feature.pathOpening,Feature.pathClosing]) {
        Engine engine;
        engine.run(isolated,Region2D(2,2,1,1),feature,3,PathMorphologyParams(3,1),
            (Region2D r,scope const(Value)[] values,Provenance p) { enforce(!values[0].valid); });
    }
    // Maximum-support scratch stays bounded on a dataset-independent request.
    auto large=negativeZero;large.identity="large-path";
    large.width=large.height=1_000_000;
    large.read=(Region2D r,scope Sample[] samples) { samples[]=Sample(1,[42,42,42],true); };
    foreach(feature;[Feature.pathOpening,Feature.pathClosing]) {
        Engine engine;
        engine.run(large,Region2D(100,100,1,1),feature,256,PathMorphologyParams(31,2),
            (Region2D r,scope const(Value)[] values,Provenance p) {
                enforce(values[0].valid && values[0].channels[0]==1);
            });
        enforce(engine.metrics.peakTileBytes<=8*1024*1024);
    }
    large.rgb=true;large.band="RGB";
    Engine mixed;
    runFeatureView(mixed,large,Region2D(100,100,1,1),
        [Feature.localStatistics,Feature.localNormalization,Feature.openingProfile,
         Feature.pathOpening,Feature.pathClosing,Feature.gabor],256,
        (Region2D r,scope const(Value)[] values,Provenance p) { enforce(values[0].valid); });
    enforce(mixed.metrics.peakTileBytes<=8*1024*1024);
}
