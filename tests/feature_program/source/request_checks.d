module request_checks;

@safe:

import imagery.analysis.feature_regions;
import imagery.analysis.feature_requests;
import raster.region : Region2D;
import std.exception : enforce,assertThrown;
import std.json : JSONValue;

private class Counter {size_t reads;}

private Source fixture(Counter counter,bool rgb,size_t side)
{
    Source result;
    result.identity="configured-queue";result.revision="1";result.grid="pixels";
    result.band=rgb?"RGB":"scalar";result.unit=rgb?"1":"K";
    result.rgb=rgb;result.width=result.height=side;
    result.read=(Region2D r,scope Sample[] values) {
        ++counter.reads;
        foreach(i,ref value;values) {
            const x=r.x+i%r.width,y=r.y+i/r.width;
            const v=cast(ubyte)(20+(17*x+13*y+x*y)%210);
            value=Sample(273+cast(double)v/16,[v,cast(ubyte)(255-v),v],true);
        }
    };
    return result;
}

private void equal(scope const(Value)[] actual,scope const(Value)[] expected)
{
    enforce(actual.length==expected.length);
    foreach(i,value;actual) {
        enforce(value.valid==expected[i].valid && value.orientationValid==expected[i].orientationValid);
        if(value.valid)enforce(value.channels==expected[i].channels);
    }
}

private size_t family(P)(Feature feature,P parameters,bool rgb=false,size_t edge=11)
{
    auto counter=new Counter;
    auto source=fixture(counter,rgb,edge+18);
    const region=Region2D(5,7,edge,edge);
    const original=parameters;
    Engine reference;
    auto expected=new Value[edge*edge],defaults=new Value[edge*edge];
    string identity;
    reference.run(source,region,feature,edge,parameters,
        (Region2D r,scope const(Value)[] values,Provenance origin) {
            identity=origin.parameters;
            foreach(i,value;values)expected[(r.y-region.y+i/r.width)*edge+r.x-region.x+i%r.width]=value;
        });
    Engine baseline;
    baseline.run(source,region,feature,edge,
        (Region2D r,scope const(Value)[] values,Provenance origin) {
            foreach(i,value;values)defaults[(r.y-region.y+i/r.width)*edge+r.x-region.x+i%r.width]=value;
        });
    auto queue=new FeatureRequests;
    size_t received;
    Sink configured=(Region2D r,scope const(Value)[] values,Provenance origin) {
        enforce(r==region && origin.extent==region && origin.parameters==identity);
        equal(values,expected);++received;
    };
    RequestFailure failed=(Exception error) {throw error;};
    const first=queue.submit(source,region,feature,parameters,RequestPriority.background,configured,failed);
    enforce(first!=0);
    enforce(queue.submit(source,region,feature,parameters,RequestPriority.visible,configured,failed)!=0);
    // Captured parameters are values, including Gabor's fixed-size arrays.
    parameters=P.init;
    enforce(queue.cancel(first));
    enforce(queue.pump() && !queue.pump() && queue.executed==1 && received==1);
    const reads=counter.reads;
    enforce(queue.submit(source,region,feature,original,RequestPriority.visible,configured,failed)!=0);
    enforce(queue.pump() && !queue.pump() && queue.executed==2 && received==2);
    enforce(counter.reads==reads,"Warm configured requests must reuse Engine output tiles");
    Sink fixed=(Region2D r,scope const(Value)[] values,Provenance origin) {
        enforce(r==region && origin.extent==region);equal(values,defaults);++received;
    };
    enforce(queue.submit(source,region,feature,RequestPriority.visible,fixed,failed)!=0);
    enforce(queue.submit(source,region,feature,P.init,RequestPriority.visible,fixed,failed)!=0);
    enforce(queue.pump() && !queue.pump() && queue.executed==3 && received==4,
        "Explicit defaults and legacy submission must share one job");
    enforce(queue.metrics.peakCacheBytes<=16*1024*1024 && queue.metrics.peakTileBytes<=8*1024*1024);
    Engine batch;
    runFeatureView(batch,source,region,[Feature.gradient,feature],edge,original,
        (Region2D r,scope const(Value)[] values,Provenance origin) {
            if(origin.feature==feature)foreach(i,value;values) {
                const index=(r.y-region.y+i/r.width)*edge+r.x-region.x+i%r.width;
                equal(values[i..i+1],expected[index..index+1]);
            }
        });
    return expected.length;
}

void checkRequests(ref JSONValue root)
{
    size_t samples;
    samples+=family(Feature.localNormalization,LocalStatisticsParams(31,100),false,256);
    samples+=family(Feature.pathOpening,PathMorphologyParams(5,2));
    samples+=family(Feature.ridge,RidgeParams(2,7));
    samples+=family(Feature.lineResponse,LineResponseParams(RidgeParams(2,5),3));
    GaborParams bank;bank.wavelengths=[1.5,3.5];bank.sigmaRatio=.6;bank.supportRatio=1.25;
    samples+=family(Feature.gabor,bank);
    samples+=family(Feature.shadowCandidate,ShadowParams(LocalStatisticsParams(5,40),.4),true);
    auto counter=new Counter;auto source=fixture(counter,false,32);
    auto queue=new FeatureRequests;
    Sink success=(Region2D r,scope const(Value)[] v,Provenance p){};
    RequestFailure failed=(Exception error){throw error;};
    assertThrown!Exception(queue.submit(source,Region2D(0,0,8,8),Feature.localStatistics,
        LocalStatisticsParams(0,1),RequestPriority.visible,success,failed));
    assertThrown!Exception(queue.submit(source,Region2D(0,0,8,8),Feature.gaussian,
        RidgeParams.init,RequestPriority.visible,success,failed));
    enforce(counter.reads==0 && !queue.pump());
    enforce(queue.submit(source,Region2D(0,0,8,8),Feature.localStatistics,
        LocalStatisticsParams.init,RequestPriority.visible,success,failed)==1);
    enforce(queue.pump());
    // Batched windows customize dependent moments, with unrelated fixed outputs.
    Engine batch,single;
    const region=Region2D(3,2,19,17);
    auto expected=new Value[region.width*region.height];
    const parameters=LocalStatisticsParams(5,40);
    single.run(source,region,Feature.localNormalization,8,parameters,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            foreach(i,value;values)expected[(r.y-region.y+i/r.width)*region.width+r.x-region.x+i%r.width]=value;
        });
    runFeatureView(batch,source,region,[Feature.gradient,Feature.localStatistics,Feature.localNormalization],8,parameters,
        (Region2D r,scope const(Value)[] values,Provenance p) {
            if(p.feature==Feature.localNormalization)foreach(i,value;values) {
                const index=(r.y-region.y+i/r.width)*region.width+r.x-region.x+i%r.width;
                equal(values[i..i+1],expected[index..index+1]);
            }
        });
    const before=counter.reads;
    assertThrown!Exception(runFeatureView(batch,source,region,[Feature.gradient],8,parameters,success));
    enforce(counter.reads==before);
    auto broken=fixture(counter,false,280);broken.identity="broken-subtile";
    const reader=broken.read;size_t reads,failures,successes;
    broken.read=(Region2D r,scope Sample[] values) {
        if(++reads==2)throw new Exception("injected second-subtile read failure");
        reader(r,values);
    };
    auto failingQueue=new FeatureRequests;
    enforce(failingQueue.submit(broken,Region2D(5,7,256,256),Feature.localNormalization,
        LocalStatisticsParams(31,100),RequestPriority.visible,
        (Region2D r,scope const(Value)[] values,Provenance p){++successes;},
        (Exception e){++failures;})!=0);
    enforce(failingQueue.pump() && !failingQueue.pump() && failures==1 && successes==0 && reads==2);
    root["configured_request_samples"]=JSONValue(samples);
    root["configured_request_families"]=JSONValue(6);
}
