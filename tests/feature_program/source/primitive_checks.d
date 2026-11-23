module primitive_checks;

import imagery.analysis.primitives;
import imagery.analysis.canny_worker;
import core.memory : GC;
import imagery.analysis.feature_regions : Source,Sample,Engine,Feature,Value,Provenance;
import raster.region : Region2D;
import raster.parallel_rows : ParallelRowsResult;
import std.exception : enforce;
import std.math : isFinite,abs;
import std.json : JSONValue;

void checkPrimitives(ref JSONValue root)
{
    enum w=19,h=17;
    auto input=new float[w*h];
    foreach(y;0..h)foreach(x;0..w)input[y*w+x]=cast(float)((x*37+y*17+x*y)%256);
    auto gx=new float[input.length],gy=new float[input.length],magnitude=new float[input.length];
    cannyGradient(input,w,h,gx,gy,magnitude);
    foreach(value;gx)enforce(isFinite(value),"Sobel must produce finite gradients from finite pixels");
    auto tx=new float[input.length],ty=new float[input.length];
    enforce(sobelParallel(input,w,h,tx,ty,2,4)==ParallelRowsResult.completed);
    enforce(tx==gx && ty==gy);
    auto tile=new float[7*7],tgx=new float[7*7],tgy=new float[7*7];
    foreach(y;0..7)foreach(x;0..7)tile[y*7+x]=input[(y+4)*w+x+5];
    sobel(tile,7,7,tgx,tgy);
    foreach(y;1..6)foreach(x;1..6)enforce(tgx[y*7+x]==gx[(y+4)*w+x+5] && tgy[y*7+x]==gy[(y+4)*w+x+5]);
    JSONValue[] edges;
    CannyWorkspace workspace;workspace.prepare(w,h);
    foreach(pair;[[50.0f,100.0f],[150.0f,300.0f],[300.0f,600.0f]]) {
        auto direct=new ubyte[input.length],staged=new ubyte[input.length],frontier=new ubyte[input.length];
        canny(input,w,h,pair[0],pair[1],direct);
        cannyFromGradient(gx,gy,magnitude,w,h,pair[0],pair[1],staged);
        cannyFromGradientFrontier(gx,gy,magnitude,w,h,pair[0],pair[1],frontier);
        enforce(direct==staged && direct==frontier,"Canny connectivity paths must agree");
        enforce(cannyParallel(input,w,h,pair[0],pair[1],frontier,2,4)==ParallelRowsResult.completed);
        enforce(direct==frontier);
        const before=GC.stats().allocatedInCurrentThread;
        enforce(workspace.tryRun(input,w,h,pair[0],pair[1],frontier)==CannyWorkerError.none);
        enforce(GC.stats().allocatedInCurrentThread==before&&direct==frontier,"Prepared Canny exact/zero-GC");
        JSONValue item;
        item["low"]=JSONValue(pair[0]);item["high"]=JSONValue(pair[1]);
        int[] values;foreach(value;direct)values~=value;
        item["edges"]=JSONValue(values);edges~=item;
    }
    root["primitive_edges"]=JSONValue(edges);
    size_t cannyCases;
    JSONValue[] cannyReferenceCases;
    foreach(shape;[[1UL,1UL],[1UL,19UL],[23UL,1UL],[3UL,3UL],[13UL,11UL],[37UL,31UL]]) {
        const width=shape[0],height=shape[1];
        CannyWorkspace worker;worker.prepare(width,height);
        auto image=new float[width*height];auto baseline=new ubyte[image.length],actual=new ubyte[image.length];
        foreach(fixture;0..5) {
            foreach(i,ref v;image)v=fixture==0?0:fixture==1?1:
                fixture==2?cast(float)((i*37+i/width*11)%257)/256:
                fixture==3?cast(float)(cast(int)(i*19%67)-33)/7:
                cast(float)(cast(int)(i*19%67)-33)*1e37f;
            foreach(pair;[[0.0f,0.0f],[0.0f,.3f],[.1f,.3f],[50.0f,100.0f]]) {
                import std.format : format;
                canny(image,width,height,pair[0],pair[1],baseline);
                enforce(worker.tryRun(image,width,height,pair[0],pair[1],actual)==CannyWorkerError.none&&actual==baseline,
                    format("Canny prepared reference: %sx%s fixture=%s low=%s high=%s",width,height,fixture,pair[0],pair[1]));++cannyCases;
                JSONValue referenceCase;
                double[] pixels;int[] expected;
                foreach(v;image)pixels~=v;
                foreach(v;baseline)expected~=v;
                referenceCase["width"]=JSONValue(width);referenceCase["height"]=JSONValue(height);
                referenceCase["input"]=JSONValue(pixels);referenceCase["edges"]=JSONValue(expected);
                referenceCase["low"]=JSONValue(pair[0]);referenceCase["high"]=JSONValue(pair[1]);
                cannyReferenceCases~=referenceCase;
            }
        }
    }
    root["prepared_canny_cases"]=JSONValue(cannyCases);
    root["canny_reference_cases"]=JSONValue(cannyReferenceCases);
    double[] numbers,xs,ys;
    foreach(i,value;input) {numbers~=value;xs~=gx[i];ys~=gy[i];}
    root["primitive_input"]=JSONValue(numbers);root["primitive_gx"]=JSONValue(xs);root["primitive_gy"]=JSONValue(ys);
    auto blurred=new float[input.length],parallel=new float[input.length];
    gaussianBlur(input,w,h,1.2f,blurred);
    enforce(gaussianBlurParallel(input,w,h,1.2f,parallel,2,4)==ParallelRowsResult.completed);
    enforce(blurred==parallel);
    numbers.length=0;foreach(value;blurred) {enforce(isFinite(value));numbers~=value;}
    root["primitive_gaussian"]=JSONValue(numbers);
    // Eight isolated rays exceed the old frontier's 2*seedCount+1 capacity.
    ubyte[25] state;state[12]=2;
    foreach(dy;-1..2)foreach(dx;-1..2)if(dx || dy)foreach(distance;1..3)
        state[(2+dy*distance)*5+2+dx*distance]=1;
    auto result=new ubyte[25];cannyFrontierFromState(state[],5,5,result);
    size_t reached;foreach(value;result)reached+=value;
    enforce(reached==17,"Hysteresis must propagate every branch");
    root["primitive_frontier_reached"]=JSONValue(reached);
    Source featureSource;
    featureSource.identity="timing-reference-preflight";featureSource.revision="1";
    featureSource.grid="pixels";featureSource.band="scalar";featureSource.unit="1";
    featureSource.width=w;featureSource.height=h;
    featureSource.read=(Region2D r,scope Sample[] values) {
        foreach(i,ref value;values)value=Sample(cast(float)input[(r.y+i/r.width)*w+r.x+i%r.width]/255,[0,0,0],true);
    };
    JSONValue[] features;
    foreach(feature;[Feature.gaussian,Feature.gradient,Feature.localNormalization,Feature.ridge,Feature.gabor,Feature.median]) {
        Engine engine;auto strengths=new double[input.length];
        engine.run(featureSource,Region2D(0,0,w,h),feature,8,
            (Region2D r,scope const(Value)[] values,Provenance p) {
                foreach(i,value;values) {enforce(value.valid);strengths[(r.y+i/r.width)*w+r.x+i%r.width]=value.channels[0];}
            });
        import std.conv : to;
        JSONValue item;item["feature"]=JSONValue(feature.to!string);
        item["strength"]=JSONValue(strengths);features~=item;
    }
    root["timing_reference_features"]=JSONValue(features);
    foreach(ref value;input)value/=255;
    bilateralFilter(input,w,h,1.2f,.2f,blurred);
    numbers.length=0;foreach(value;blurred)numbers~=value;
    root["primitive_bilateral"]=JSONValue(numbers);
    guidedFilter(input,input,w,h,2,.01f,blurred);
    numbers.length=0;foreach(value;blurred)numbers~=value;
    root["primitive_guided"]=JSONValue(numbers);
    // Constant invariance catches NaN accumulators in bilateral/guided paths.
    input[]=7;
    bilateralFilter(input,w,h,1.2f,2,blurred);
    foreach(value;blurred)enforce(abs(value-7)<2e-6f);
    guidedFilter(input,input,w,h,2,.01f,blurred);
    foreach(value;blurred)enforce(abs(value-7)<2e-6f);
    JSONValue[] superpixels;
    foreach(kind;0..3) {
        auto field=new float[w*h];
        foreach(y;0..h)foreach(x;0..w) {
            field[y*w+x]=kind==0?.5f:kind==1?(x+2*y>20?1.0f:0.0f):
                cast(float)((x*37+y*17+x*y)%256)/255;
        }
        auto labels=new uint[field.length];slic(field,w,h,5,labels);
        JSONValue entry;double[] samples;int[] ids;
        foreach(i,value;field){samples~=value;ids~=labels[i];}
        entry["input"]=JSONValue(samples);entry["labels"]=JSONValue(ids);
        entry["spacing"]=JSONValue(5);superpixels~=entry;
    }
    root["slic_cases"]=JSONValue(superpixels);
}
