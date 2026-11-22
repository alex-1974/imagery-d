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
