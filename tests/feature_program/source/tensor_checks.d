module tensor_checks;

import imagery.analysis.structure_tensor;
import core.memory : GC;
import raster.region : Region2D;
import std.algorithm : min, max;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : abs, cos, sin, exp, PI;

void checkTensor(ref JSONValue root)
{
    enum w=65,h=49;
    auto input=new float[w*h];
    auto angle=new float[input.length], coherence=new float[input.length], energy=new float[input.length];
    auto valid=new ubyte[input.length];
    TensorWorkspace scratch;scratch.reserve(input.length);
    JSONValue[] cases;
    double roiError=0,analyticError=0;
    foreach(kind;0..4) {
        foreach(i,ref value;input) {
            const x=cast(double)(i%w)-32, y=cast(double)(i/w)-24;
            switch(kind) {
                case 0:value=cast(float)exp(-0.5*(x/2)^^2);break;
                case 1:value=cast(float)sin(2*PI*(x*cos(.65)+y*sin(.65))/19);break;
                case 2:value=cast(float)(sin(x/2)*cos(y/3)+.2*exp(-(x*x+y*y)/30));break;
                default:value=cast(float)exp(-(x*x+y*y)/30);break;
            }
        }
        foreach(params;[StructureTensorParams(.5,0),StructureTensorParams(.75,.5),
            StructureTensorParams(1.25,2.5),StructureTensorParams(2.75,4),StructureTensorParams(32,32)]) {
            const before=GC.stats().allocatedInCurrentThread;
            structureTensor(input,w,h,params,scratch,angle,coherence,energy,valid);
            enforce(GC.stats().allocatedInCurrentThread==before,"Tensor evaluation allocated");
            foreach(i;0..input.length) enforce(coherence[i]>=0 && coherence[i]<=1 && energy[i]>=0);
            JSONValue entry;
            entry["kind"]=JSONValue(kind);entry["input"]=JSONValue(input);
            entry["gradient_sigma"]=JSONValue(params.gradientSigma);
            entry["integration_sigma"]=JSONValue(params.integrationSigma);
            entry["angles"]=JSONValue(angle);entry["coherences"]=JSONValue(coherence);
            entry["energies"]=JSONValue(energy);entry["valid"]=JSONValue(valid);
            cases~=entry;
            foreach(roi;[Region2D(21,17,19,13),Region2D(0,3,8,9),Region2D(63,47,2,2)]) {
                const halo=params.halo();
                const x=roi.x>halo?roi.x-halo:0,y=roi.y>halo?roi.y-halo:0;
                const right=min(w,roi.x+roi.width+halo),bottom=min(h,roi.y+roi.height+halo);
                const pw=right-x,ph=bottom-y;
                auto patch=new float[pw*ph];
                foreach(py;0..ph)foreach(px;0..pw)patch[py*pw+px]=input[(y+py)*w+x+px];
                auto pa=new float[patch.length],pc=new float[patch.length],pe=new float[patch.length];
                auto pv=new ubyte[patch.length];
                TensorWorkspace work;work.reserve(patch.length);
                structureTensor(patch,pw,ph,params,work,pa,pc,pe,pv);
                foreach(py;0..roi.height)foreach(px;0..roi.width) {
                    const full=(roi.y+py)*w+roi.x+px,part=(roi.y-y+py)*pw+roi.x-x+px;
                    enforce(pc[part]==coherence[full] && pe[part]==energy[full] && pv[part]==valid[full],"Tensor ROI values");
                    if(valid[full]) {
                        roiError=max(roiError,cast(double)abs(pa[part]-angle[full]));
                        enforce(pa[part]==angle[full],"Tensor ROI orientation");
                    }
                }
            }
            // The center of a radial signal is isotropic by symmetry.
            if(kind==3 && params.halo()<=h/2)
                enforce(valid[(h/2)*w+w/2]==0,"Tensor isotropic orientation");
        }
    }
    root["tensor_cases"]=JSONValue(cases);

    // Analytic affine gradients: exact rank-one orientation, independent of
    // gradient/integration scale away from source borders.
    foreach(theta;[0.0,PI/4,-.4]) {
        foreach(i,ref value;input)
            value=cast(float)(((cast(double)(i%w)-32)*cos(theta)+(cast(double)(i/w)-24)*sin(theta))/64);
        structureTensor(input,w,h,StructureTensorParams(1.25,2.5),scratch,angle,coherence,energy,valid);
        foreach(y;16..33)foreach(x;16..49) {
            const i=y*w+x;
            analyticError=max(analyticError,abs(cast(double)angle[i]-theta));
            enforce(valid[i]!=0 && abs(angle[i]-theta)<1e-7 && abs(coherence[i]-1)<=float.epsilon);
        }
        auto originalAngle=angle.dup,originalEnergy=energy.dup,originalCoherence=coherence.dup;
        auto originalValid=valid.dup;
        auto scaled=input.dup;
        foreach(factor;[1.0/1024,1024.0]) {
            foreach(i,ref value;scaled)value=cast(float)(input[i]*factor);
            structureTensor(scaled,w,h,StructureTensorParams(1.25,2.5),scratch,angle,coherence,energy,valid);
            enforce(angle==originalAngle && coherence==originalCoherence && valid==originalValid,"Tensor unit rescaling");
            foreach(i;0..input.length) enforce(energy[i]==originalEnergy[i]*factor*factor,"Tensor energy units");
        }
    }
    root["tensor_roi_max_error"]=JSONValue(roiError);
    root["tensor_analytic_max_error"]=JSONValue(analyticError);

    // Invalid calls publish no partial output and reserve no hidden storage.
    input[]=1;
    angle[]=17;coherence[]=18;energy[]=19;valid[]=7;
    void reject(StructureTensorParams params,bool reserved=true,bool malformed=false) {
        TensorWorkspace empty;
        bool caught;
        try { structureTensor(input,malformed?w+1:w,h,params,reserved?scratch:empty,angle,coherence,energy,valid); }
        catch(Exception) { caught=true; }
        enforce(caught);
        foreach(i;0..input.length) enforce(angle[i]==17 && coherence[i]==18 && energy[i]==19 && valid[i]==7,"Tensor failure publication");
    }
    reject(StructureTensorParams(0,2));reject(StructureTensorParams(double.nan,2));
    reject(StructureTensorParams(1,-1));reject(StructureTensorParams(1,33));
    reject(StructureTensorParams.init,false);reject(StructureTensorParams.init,true,true);
    input[123]=float.nan;reject(StructureTensorParams.init);
    input[]=1;
    structureTensor(input,w,h,StructureTensorParams(1e-200,0),scratch,angle,coherence,energy,valid);
    foreach(i;0..input.length) enforce(angle[i]==0 && coherence[i]==0 && energy[i]==0 && valid[i]==0);
}
