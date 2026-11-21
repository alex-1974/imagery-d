module quality_checks;

import imagery.analysis.quality;
import core.memory : GC;
import std.json : JSONValue;
import std.math : abs,cos,sin,exp,PI;
import std.exception : enforce;

private float[] blur(scope const(float)[] input,size_t w,size_t h,double sigma)
{
    if(!sigma)return input.dup;
    const radius=cast(int)(4*sigma+.999999);
    auto weights=new double[2*radius+1];double sum=0;
    foreach(i,ref value;weights) {const x=cast(int)i-radius;value=exp(-.5*x*x/(sigma*sigma));sum+=value;}
    weights[]/=sum;
    auto horizontal=new double[input.length];auto output=new float[input.length];
    foreach(y;0..h)foreach(x;0..w) {
        double value=0;
        foreach(k;-radius..radius+1)value+=weights[k+radius]*input[y*w+(cast(long)x+k+w)%w];
        horizontal[y*w+x]=value;
    }
    foreach(y;0..h)foreach(x;0..w) {
        double value=0;
        foreach(k;-radius..radius+1)value+=weights[k+radius]*horizontal[((cast(long)y+k+h)%h)*w+x];
        output[y*w+x]=cast(float)value;
    }
    return output;
}

void checkQuality(ref JSONValue root)
{
    enum w=128,h=96;
    JSONValue[] cases;
    foreach(kind;0..3) {
        auto base=new float[w*h];
        foreach(y;0..h)foreach(x;0..w) {
            const low=sin(2*PI*x/32),high=cos(2*PI*x/8)*cos(2*PI*y/12);
            base[y*w+x]=cast(float)(kind==0?low:kind==1?low+.5*high:3.0);
        }
        double lastEnergy=double.infinity,lastFrequency=double.infinity;
        foreach(sigma;[0.0,.75,2.0,4.0]) {
            auto input=blur(base,w,h,sigma);
            auto scratch=new double[input.length];RegionQuality result;
            const before=GC.stats().allocatedInCurrentThread;
            enforce(tryRegionQuality(input,w,h,scratch,result));
            enforce(GC.stats().allocatedInCurrentThread==before);
            if(kind<2)enforce(result.gradientEnergy<lastEnergy);
            if(kind==1)enforce(result.detailFrequency<lastFrequency);
            lastEnergy=result.gradientEnergy;lastFrequency=result.detailFrequency;
            JSONValue entry;
            entry["kind"]=JSONValue(kind);entry["sigma"]=JSONValue(sigma);
            double[] numbers;foreach(value;base)numbers~=cast(double)value;
            entry["base"]=JSONValue(numbers);
            entry["metrics"]=JSONValue([result.noiseSigma,result.gradientEnergy,result.detailFrequency]);
            entry["samples"]=JSONValue(result.samples);cases~=entry;
        }
    }
    root["quality_cases"]=JSONValue(cases);
    // Dyadic input keeps affine unit changes exact in float source storage.
    auto input=new float[w*h];
    foreach(i,ref value;input)value=cast(float)((i*17+i*i*31)%257)/16;
    auto scratch=new double[input.length];RegionQuality reference,result;
    enforce(tryRegionQuality(input,w,h,scratch,reference));
    foreach(factor;[1.0/1024,1024.0,-1.0]) {
        auto transformed=input.dup;foreach(ref v;transformed)v=cast(float)(factor*v+128*factor);
        enforce(tryRegionQuality(transformed,w,h,scratch,result));
        enforce(abs(result.noiseSigma/abs(factor)-reference.noiseSigma)<1e-12);
        enforce(abs(result.gradientEnergy/(factor*factor)-reference.gradientEnergy)<1e-12);
        enforce(abs(result.detailFrequency-reference.detailFrequency)<1e-14);
        enforce(result.samples==reference.samples);
    }
    // A bad center removes its 3x3 neighborhood of complete stencils.
    input[(h/2)*w+w/2]=float.nan;
    enforce(tryRegionQuality(input,w,h,scratch,result));
    enforce(result.samples==(w-2)*(h-2)-9);
    const previous=result;
    input[]=float.nan;
    enforce(!tryRegionQuality(input,w,h,scratch,result) && result==previous);
    enforce(!tryRegionQuality(input,w,h,scratch[0..1],result) && result==previous);
    root["quality_unit_cases"]=JSONValue(3);
}
