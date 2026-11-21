module hessian_checks;
import imagery.analysis.hessian_lines;
import core.memory : GC;
import std.algorithm : min, max;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : abs, exp, sin, PI;
import raster.region : Region2D;

void checkHessian(ref JSONValue root)
{
    checkFixture(root,false);
    JSONValue extra;
    checkFixture(extra,true);
    root["hessian_extra"]=extra;
    JSONValue configured;
    checkFixture(configured,true,true);
    root["hessian_configured"]=configured;
}

private void checkFixture(ref JSONValue root,bool textured,bool configured=false)
{
    enum w=65,h=49;
    auto input=new float[w*h];
    foreach(i,ref v;input) {
        const x=cast(double)(i%w)-32;
        const y=cast(double)(i/w)-24;
        v=cast(float)(textured ? 0.25+0.35*exp(-0.5*((x+0.4*y)/2)^^2)+
            0.1*sin(x/3)*sin(y/4)+0.2*exp(-(x*x+y*y)/50) :
            0.25+0.5*exp(-0.5*(x/2)^^2));
    }
    double[3] sigmas=[1,2,4];
    if(configured)sigmas=[0.5,1.25,3.75];
    HessianLineWorkspace scratch;scratch.reserve(input.length);
    auto strength=new float[input.length],angle=new float[input.length],scale=new float[input.length];
    auto valid=new ubyte[input.length];
    root["hessian_input"]=JSONValue(input);
    root["hessian_sigmas"]=JSONValue(sigmas[]);
    JSONValue[] cases;
    foreach(variant;[HessianLineVariant.sato,HessianLineVariant.frangi,HessianLineVariant.meijering])
        foreach(polarity;[LinePolarity.bright,LinePolarity.dark,LinePolarity.both])
    {
        HessianLineParams params;
        params.variant=variant;params.polarity=polarity;
        if(configured) { params.beta=.8;params.gamma=.2;params.alpha= -1.0/3;params.responseScale=.7; }
        const before=GC.stats().allocatedInCurrentThread;
        hessianLineResponse(input,w,h,sigmas[],params,scratch,strength,angle,scale,valid);
        enforce(GC.stats().allocatedInCurrentThread==before,"Hessian evaluation allocated");
        JSONValue entry;
        entry["variant"]=JSONValue(cast(int)variant);entry["polarity"]=JSONValue(cast(int)polarity);
        entry["beta"]=JSONValue(params.beta);entry["gamma"]=JSONValue(params.gamma);
        entry["alpha"]=JSONValue(params.alpha);entry["responseScale"]=JSONValue(params.responseScale);
        entry["response"]=JSONValue(strength);entry["angles"]=JSONValue(angle);
        entry["scales"]=JSONValue(scale);entry["valid"]=JSONValue(valid);
        cases~=entry;
        foreach(roi;[Region2D(20,16,21,17),Region2D(0,1,17,13),Region2D(63,47,2,2)])
        {
            const halo=hessianLineHalo(sigmas[]);
            const x=roi.x>halo?roi.x-halo:0, y=roi.y>halo?roi.y-halo:0;
            const right=min(w,roi.x+roi.width+halo),bottom=min(h,roi.y+roi.height+halo);
            const pw=right-x,ph=bottom-y;
            auto patch=new float[pw*ph];
            foreach(py;0..ph)foreach(px;0..pw)patch[py*pw+px]=input[(y+py)*w+x+px];
            auto ps=new float[patch.length],pa=new float[patch.length],pz=new float[patch.length];
            auto pv=new ubyte[patch.length];
            HessianLineWorkspace work;work.reserve(patch.length);
            hessianLineResponse(patch,pw,ph,sigmas[],params,work,ps,pa,pz,pv);
            foreach(py;0..roi.height)foreach(px;0..roi.width) {
                const whole=(roi.y+py)*w+roi.x+px,part=(roi.y-y+py)*pw+roi.x-x+px;
                enforce(abs(ps[part]-strength[whole])<1e-7,"Hessian ROI strength");
                enforce(pz[part]==scale[whole] && pv[part]==valid[whole],"Hessian ROI scale/validity");
                if(valid[whole])enforce(abs(pa[part]-angle[whole])<1e-6,"Hessian ROI orientation");
            }
        }
    }
    root["hessian_cases"]=JSONValue(cases);
    if(!textured) {
        const center=(h/2)*w+w/2;
        enforce(valid[center]!=0);
        enforce(abs(angle[center]-PI/2)<1e-6,"Vertical line tangent");
    }
    // Explicit polarity inversion and scalar translation invariance.
    HessianLineParams bright,dark;
    dark.polarity=LinePolarity.dark;
    hessianLineResponse(input,w,h,sigmas[],bright,scratch,strength,angle,scale,valid);
    const original=strength.dup;
    foreach(ref v;input)v= -v;
    hessianLineResponse(input,w,h,sigmas[],dark,scratch,strength,angle,scale,valid);
    enforce(strength==original,"Hessian sign inversion");
    float[] sentinel=new float[input.length];sentinel[]=17;
    bool rejected;
    try { double[2] bad=[2,1];hessianLineResponse(input,w,h,bad[],bright,scratch,sentinel,angle,scale,valid); }
    catch(Exception) { rejected=true; }
    enforce(rejected);foreach(v;sentinel)enforce(v==17,"Hessian failure publication");
}
