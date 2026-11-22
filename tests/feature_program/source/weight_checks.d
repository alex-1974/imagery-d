module weight_checks;

import imagery.mosaic.validity_policy;
import color.alpha : Alpha,Premultiplied,premultiply,unpremultiply;
import color.rgb : LinearSRgbd;
import core.memory : GC;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : abs,isFinite,ldexp;

@safe:

private ulong state=0x9e3779b97f4a7c15UL;
private double unit()
{
    state=state*6364136223846793005UL+1442695040888963407UL;
    return cast(double)(state>>11)/9007199254740992.0;
}

// Test-only consumer recipe: quality weights remain separate from alpha and
// NoData. color-d owns alpha association. Geometry/union coverage is not inferred.
private bool mixture(scope const(QualityContributor)[] factors,
    scope const(Alpha!LinearSRgbd)[] colors,scope double[] scratch,
    ref Alpha!LinearSRgbd published) nothrow @nogc
{
    if(colors.length!=factors.length || !tryQualityWeights(factors,scratch))return false;
    double r=0,g=0,b=0,a=0;
    foreach(i,f;factors)if(scratch[i]>0) {
        const color=colors[i];
        if(!color.isValidAlpha)return false;
        if(color.alpha==0)continue; // Hidden transparent RGB is not data.
        if(!isFinite(color.color.r) || !isFinite(color.color.g) || !isFinite(color.color.b))return false;
        const premul=premultiply(color);
        r+=scratch[i]*premul.color.r;g+=scratch[i]*premul.color.g;b+=scratch[i]*premul.color.b;
        a+=scratch[i]*premul.alpha;
    }
    published=unpremultiply(Premultiplied!LinearSRgbd(LinearSRgbd(r,g,b),a));
    return true;
}

void checkWeights(ref JSONValue root)
{
    state=0x9e3779b97f4a7c15UL;
    JSONValue[] cases;
    void check(scope const(QualityContributor)[] input,string regime)
    {
        auto weights=new double[input.length+2];weights[]=37;
        const before=GC.stats().allocatedInCurrentThread;
        enforce(tryQualityWeights(input,weights));
        enforce(GC.stats().allocatedInCurrentThread==before && weights[$-1]==37 && weights[$-2]==37);
        JSONValue entry;JSONValue[] records;
        foreach(c;input) {
            JSONValue record;record["valid"]=JSONValue(c.valid);
            record["factors"]=JSONValue([c.coverage,c.quality,c.preference]);records~=record;
        }
        entry["contributors"]=JSONValue(records);entry["regime"]=JSONValue(regime);
        entry["weights"]=JSONValue(weights[0..input.length]);cases~=entry;
        auto reversed=input.dup;
        foreach(i;0..input.length)reversed[i]=input[$-1-i];
        auto reverseWeights=new double[input.length];enforce(tryQualityWeights(reversed,reverseWeights));
        foreach(i;0..input.length)enforce(abs(weights[i]-reverseWeights[$-1-i])<1e-15);
    }
    foreach(count;[1,2,3,8,31,257])foreach(extreme;[false,true])foreach(trial;0..8) {
        auto input=new QualityContributor[count];
        foreach(i,ref c;input) {
            c.valid=i==0 || unit()>.2;
            if(extreme)c=QualityContributor(c.valid,
                ldexp(.5+.5*unit(),-200-cast(int)(unit()*801)),
                ldexp(.5+.5*unit(),-200-cast(int)(unit()*801)),
                ldexp(.5+.5*unit(),cast(int)(unit()*2001)-1000));
            else c=QualityContributor(c.valid,.05+.95*unit(),.05+.95*unit(),
                ldexp(.5+.5*unit(),cast(int)(unit()*801)-400));
        }
        check(input,extreme?"extreme":"ordinary");
    }
    QualityContributor[2] recovery=[QualityContributor(true,1e-300,1e-300,1e300),
        QualityContributor(true,1e-300,1,1)];
    check(recovery[],"extreme");
    recovery[0]=QualityContributor(true,1e-160,1e-160,1e308);
    recovery[1]=QualityContributor(true,1e-12,1,1);
    check(recovery[],"extreme");
    QualityContributor[3] maximum=QualityContributor(true,1,1,double.max);
    check(maximum[],"ordinary");
    auto tiny=new QualityContributor[257];tiny[]=QualityContributor(true,1,1,1e-16);
    tiny[0].preference=1;check(tiny,"ordinary");
    QualityContributor[3] scaling=[QualityContributor(true,.75,.5,1),
        QualityContributor(true,.25,.75,3),QualityContributor(false,1,1,7)];
    double[3] reference,changed;
    enforce(tryQualityWeights(scaling[],reference[]));
    foreach(power;[-400,400]) {
        auto input=scaling;
        foreach(ref c;input)c.preference=ldexp(c.preference,power);
        enforce(tryQualityWeights(input[],changed[]));
        enforce(reference==changed);
    }
    foreach(kind;0..7) {
        auto input=scaling;
        switch(kind) {
            case 0:input[0].coverage=-.1;break;
            case 1:input[1].quality=1.1;break;
            case 2:input[2].preference=double.nan;break;
            case 3:input[1].preference=double.infinity;break;
            case 4:foreach(ref c;input)c.valid=false;break;
            case 5:foreach(ref c;input)c.coverage=0;break;
            default:foreach(ref c;input)c.preference=0;
        }
        double[5] untouched=37;
        enforce(!tryQualityWeights(input[],untouched[]));
        foreach(value;untouched)enforce(value==37);
    }
    double[2] tooSmall=37;
    enforce(!tryQualityWeights(scaling[],tooSmall[]) && tooSmall[0]==37 && tooSmall[1]==37);
    enforce(!tryQualityWeights(null,tooSmall[]) && tooSmall[0]==37 && tooSmall[1]==37);
    QualityContributor[4] factors=[QualityContributor(true),QualityContributor(true),
        QualityContributor(false),QualityContributor(true,1,.5)];
    Alpha!LinearSRgbd[4] colors=[Alpha!LinearSRgbd(LinearSRgbd(1,1,1),1),
        Alpha!LinearSRgbd(LinearSRgbd(double.nan,double.nan,double.nan),0),
        Alpha!LinearSRgbd.init,Alpha!LinearSRgbd(LinearSRgbd(0,0,1),.5)];
    double[4] scratch;Alpha!LinearSRgbd result;
    enforce(mixture(factors[],colors[],scratch[],result));
    root["quality_alpha_mixture"]=JSONValue([result.color.r,result.color.g,result.color.b,result.alpha]);
    foreach(ref c;colors)c=Alpha!LinearSRgbd(LinearSRgbd(double.nan,double.nan,double.nan),0);
    enforce(mixture(factors[],colors[],scratch[],result));
    enforce(result.alpha==0 && result.color==LinearSRgbd(0,0,0));
    QualityContributor[1] blackFactor=[QualityContributor(true)];
    Alpha!LinearSRgbd[1] black=[Alpha!LinearSRgbd(LinearSRgbd(0,0,0),1)];
    enforce(mixture(blackFactor[],black[],scratch[],result));
    enforce(result.alpha==1 && result.color==LinearSRgbd(0,0,0));
    const previous=result;
    blackFactor[0].valid=false;
    enforce(!mixture(blackFactor[],black[],scratch[],result) && result==previous);
    root["quality_weight_cases"]=JSONValue(cases);
    root["quality_weight_recipe"]=JSONValue("normalized-premultiplied-mixture-v1");
}
