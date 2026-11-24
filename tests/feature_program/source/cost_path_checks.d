module cost_path_checks;

import imagery.analysis.cost_path;
import core.memory : GC;
import std.algorithm : max;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : abs, isFinite, sqrt;

void checkCostPaths(ref JSONValue root)
{
    enum w=13,h=11,n=w*h;
    JSONValue[] cases;
    uint state=17467;
    double maxPathError=0;
    foreach(fixture;0..8) {
        auto costs=new double[n];
        foreach(i,ref v;costs) {
            state=1664525*state+1013904223;
            v=(state%67)/7.0;
            if(i%17==6) v=fixture%2?double.infinity:double.nan;
        }
        costs[0]=costs[n-1]=1;
        size_t[3] seeds=[n-1,0,n-1]; // duplicates and reversed order
        foreach(connectivity;[PathConnectivity.four,PathConnectivity.eight])
            foreach(steps;[[1.0,1.0],[.75,2.5],[1e-6,2e-6],[1e6,.25e6]]) {
                CostPath search;
                search.prepare(costs,w,h,seeds[],connectivity,steps[0],steps[1]);
                auto distances=new double[n];auto predecessors=new size_t[n];
                size_t[n] path;
                const before=GC.stats().allocatedInCurrentThread;
                enforce(!search.advance(n/2,0));
                size_t lastSettled;
                // A non-scan-order sequence must continue the same search.
                foreach(query;0..n) {
                    const target=(query*37)%n;
                    while(!search.advance(target,7) && !search.exhausted) {
                        size_t settled;
                        foreach(i;0..n)settled+=isFinite(search.distanceTo(i));
                        enforce(settled-lastSettled<=7,"Cost-path work budget");
                        lastSettled=settled;
                    }
                    size_t settled;
                    foreach(i;0..n)settled+=isFinite(search.distanceTo(i));
                    enforce(settled-lastSettled<=7,"Cost-path final work budget");
                    lastSettled=settled;
                    const distance=search.distanceTo(target);
                    const length=search.pathTo(target,path[]);
                    if(!isFinite(distance)) {
                        enforce(length==0 && search.predecessorOf(target)==size_t.max);
                        continue;
                    }
                    enforce(length && length<=n && path[length-1]==target);
                    enforce(path[0]==0 || path[0]==n-1);
                    double sum=0;
                    foreach(k;1..length) {
                        const a=path[k-1],b=path[k];
                        const dx=abs(cast(long)(a%w)-cast(long)(b%w));
                        const dy=abs(cast(long)(a/w)-cast(long)(b/w));
                        enforce(dx<=1 && dy<=1 && dx+dy>0);
                        enforce(connectivity==PathConnectivity.eight || dx+dy==1);
                        enforce(search.predecessorOf(b)==a && isFinite(costs[b]));
                        const step=sqrt((dx*steps[0])^^2+(dy*steps[1])^^2);
                        sum+=(costs[a]+costs[b])/2*step;
                    }
                    const error=abs(sum-distance)/max(1.0,abs(distance));
                    maxPathError=max(maxPathError,error);
                    enforce(error<3e-15,"Reconstructed path cost");
                }
                foreach(i;0..n) {
                    distances[i]=search.distanceTo(i);
                    predecessors[i]=search.predecessorOf(i);
                }
                enforce(GC.stats().allocatedInCurrentThread==before,"Cost-path query allocated");
                // Completing in one call yields the same deterministic map.
                CostPath replay;replay.prepare(costs,w,h,seeds[],connectivity,steps[0],steps[1]);
                // A blocked target drains the queue, including unreachable tails.
                enforce(!replay.advance(6) && replay.exhausted);
                foreach(i;0..n) enforce(replay.distanceTo(i)==distances[i] && replay.predecessorOf(i)==predecessors[i],"Cost-path query order");
                JSONValue entry;
                entry["connectivity"]=JSONValue(connectivity==PathConnectivity.eight?8:4);
                entry["steps"]=JSONValue(steps[]);
                auto encodedCosts=costs.dup,encodedDistances=distances.dup;
                foreach(ref v;encodedCosts)if(!isFinite(v))v= -1;
                foreach(ref v;encodedDistances)if(!isFinite(v))v= -1;
                entry["costs"]=JSONValue(encodedCosts);entry["distances"]=JSONValue(encodedDistances);
                cases~=entry;
            }
    }
    root["cost_path_cases"]=JSONValue(cases);
    root["cost_path_reconstruction_error"]=JSONValue(maxPathError);

    // Expensive exterior guarantees every optimum between interior samples
    // stays in the supplied window. Compare whole and windowed searches.
    enum fw=21,fh=17,pw=13,ph=11,left=4,top=3;
    auto full=new double[fw*fh];full[]=1e9;
    auto patch=new double[pw*ph];
    foreach(y;0..ph)foreach(x;0..pw) {
        const value=cast(double)(1+(x*17+y*31+x*y)%29);
        full[(top+y)*fw+left+x]=value;patch[y*pw+x]=value;
    }
    foreach(connectivity;[PathConnectivity.four,PathConnectivity.eight]) {
        CostPath whole,window;
        size_t[1] wholeSeed=[(top+2)*fw+left+1],windowSeed=[2*pw+1];
        whole.prepare(full,fw,fh,wholeSeed[],connectivity,.75,2.5);
        window.prepare(patch,pw,ph,windowSeed[],connectivity,.75,2.5);
        foreach(y;0..ph)foreach(x;0..pw) {
            const global=(top+y)*fw+left+x,local=y*pw+x;
            enforce(whole.advance(global) && window.advance(local));
            enforce(whole.distanceTo(global)==window.distanceTo(local),"Cost-path bounded-window optimum");
        }
    }

    checkLazyWindows(root);

    // Equal-cost alternatives have deterministic maps, including zero costs.
    uint[25] zero=0;size_t[1] seed=[0];
    CostPath first,second;first.prepare(zero[],5,5,seed[]);second.prepare(zero[],5,5,seed[]);
    enforce(first.advance(24) && second.advance(24));
    foreach(i;0..25)enforce(first.predecessorOf(i)==second.predecessorOf(i));
    size_t[1] tooSmall=[999];
    enforce(first.pathTo(24,tooSmall[])>1 && tooSmall[0]==999);
    const prior=first.distanceTo(24);
    auto invalid=new double[25];invalid[]=1;invalid[3]= -1;
    bool rejected;
    try { first.prepare(invalid,5,5,seed[]); } catch(Exception) { rejected=true; }
    enforce(rejected && first.distanceTo(24)==prior,"Cost-path failed reset");
    CostPath empty;
    enforce(empty.exhausted && !empty.advance(0) && !isFinite(empty.distanceTo(0)) && empty.predecessorOf(0)==size_t.max);
}


private struct TestCosts
{
    const(double)[] values;
    size_t width;
    double opCall(size_t x,size_t y) const @safe nothrow @nogc { return values[y*width+x]; }
}

private void checkLazyWindows(ref JSONValue root)
{
    import raster.region : Region2D;
    enum width=23,height=19;
    auto costs=new double[width*height];
    foreach(i,ref v;costs) {v=((i*37+i/width*11)%59)/7.0;if(i%17==9)v=double.infinity;}
    TestCosts provider;provider.values=costs;provider.width=width;
    JSONValue[] cases;
    foreach(connectivity;[PathConnectivity.four,PathConnectivity.eight]) {
        LazyCostPath!TestCosts search;
        search.prepare(provider,width,height,256,connectivity,.75,2.5);
        foreach(round;0..18) {
            const x=round%7,y=(round*3)%5,w=7+round%5,h=6+round%7;
            const domain=Region2D(x,y,w,h);
            size_t[2] seeds=[y*width+x,(y+h-1)*width+x+w-1];
            costs[seeds[0]]=costs[seeds[1]]=1;
            auto patch=new double[w*h];
            foreach(yy;0..h)foreach(xx;0..w)patch[yy*w+xx]=costs[(y+yy)*width+x+xx];
            size_t[2] localSeeds=[0,w*h-1];
            CostPath reference;reference.prepare(patch,w,h,localSeeds[],connectivity,.75,2.5);
            CostPath owned;owned.prepare(costs,width,height,seeds[],connectivity,.75,2.5,domain);
            auto actual=new double[w*h];
            auto predecessor=new size_t[w*h];
            size_t[256] path;
            const before=GC.stats().allocatedInCurrentThread;
            enforce(search.reset(seeds[],domain)==PathSearchError.none);
            enforce(search.costEvaluations==2&&!search.epochCleared);
            foreach(yy;0..h)foreach(xx;0..w) {
                const global=(y+yy)*width+x+xx,local=yy*w+xx;
                while(!search.advance(global,3)&&!search.exhausted) {}
                reference.advance(local);owned.advance(global);
                const a=search.distanceTo(global);
                enforce(a==reference.distanceTo(local)&&a==owned.distanceTo(global),"Windowed geometric distance");
                const old=reference.predecessorOf(local),p=search.predecessorOf(global);
                enforce(p==(old==size_t.max?size_t.max:(y+old/w)*width+x+old%w),"Windowed deterministic predecessor");
                enforce(p==owned.predecessorOf(global));
                const length=search.pathTo(global,path[]);
                if(isFinite(a))enforce(length&&path[length-1]==global);
                actual[local]=isFinite(a)?a:-1;predecessor[local]=p;
            }
            enforce(GC.stats().allocatedInCurrentThread==before,"Lazy/reset allocated");
            enforce(search.error==PathSearchError.none&&search.costEvaluations==search.touchedCells&&search.touchedCells<=w*h);
            enforce(owned.storageBytes==costs.length*8+w*h*19&&search.storageBytes==256*27);
            JSONValue entry;entry["width"]=JSONValue(w);entry["height"]=JSONValue(h);
            entry["connectivity"]=JSONValue(connectivity==PathConnectivity.eight?8:4);
            auto encoded=patch.dup;foreach(ref v;encoded)if(!isFinite(v))v=-1;
            entry["costs"]=JSONValue(encoded);entry["distances"]=JSONValue(actual);cases~=entry;
        }
    }
    root["cost_window_cases"]=JSONValue(cases);
}
