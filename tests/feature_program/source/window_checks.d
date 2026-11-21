module window_checks;
import imagery.analysis.feature_regions;
import raster.region : Region2D;
import std.algorithm : clamp, min, max;
import std.math : abs, sqrt;
import std.exception : enforce;

struct WindowCheckResult
{
    double maxMeanError=0,maxDeviationError=0;
    size_t samples;
}

WindowCheckResult checkWindows()
{
    WindowCheckResult measured;
    enum w=11,h=9;
    foreach(pattern;0..5)
    {
        const double baseline=pattern==1?1e12:0;
        double value(int x,int y) {
            if(pattern==2)return 17;
            if(pattern==4)return ((x*7+y*19)%37)/53.37;
            return baseline+((x*7+y*19)%37)*(pattern==1?0.000244140625:0.125);
        }
        bool valid(int x,int y) { return pattern!=3 && (x*3+y*5)%13!=0; }
        Source source;
        source.width=w;source.height=h;source.grid="window-oracle";
        source.band="measurement";source.unit="K";
        source.read=(Region2D r,scope Sample[] outValues) {
            foreach(i,ref s;outValues) {
                const x=cast(int)(r.x+i%r.width),y=cast(int)(r.y+i/r.width);
                s=Sample(value(x,y),[0,0,0],valid(x,y));
            }
        };
        foreach(radius;1..32)
        {
            const threshold=cast(uint)((2*radius+1)^^2/2+1);
            auto expected=new Value[w*h];
            auto ranges=new double[w*h];
            foreach(y;0..h)foreach(x;0..w)
            {
                size_t n;
                real sum=0;
                double low=double.infinity,high=-double.infinity;
                foreach(dy;-radius..radius+1)foreach(dx;-radius..radius+1) {
                    const sx=clamp(x+dx,0,w-1),sy=clamp(y+dy,0,h-1);
                    if(!valid(sx,sy))continue;
                    const v=value(sx,sy);sum+=cast(real)(v-baseline);++n;
                    low=min(low,v);high=max(high,v);
                }
                if(!valid(x,y) || n<threshold)continue;
                const real mean=sum/n;
                real squared=0;
                foreach(dy;-radius..radius+1)foreach(dx;-radius..radius+1) {
                    const sx=clamp(x+dx,0,w-1),sy=clamp(y+dy,0,h-1);
                    if(valid(sx,sy))squared+=(cast(real)(value(sx,sy)-baseline)-mean)^^2;
                }
                expected[y*w+x]=Value([cast(double)(mean+baseline),cast(double)sqrt(squared/n),0],true,false);
                ranges[y*w+x]=high-low;
            }
            foreach(edge;[1u,7u,256u])foreach(feature;[Feature.localStatistics,Feature.dynamicRange])
            {
                Engine engine;
                engine.run(source,Region2D(0,0,w,h),feature,edge,
                    LocalStatisticsParams(radius,threshold),
                    (Region2D r,scope const(Value)[] values,Provenance origin) {
                        foreach(i,v;values) {
                            const p=(r.y+i/r.width)*w+r.x+i%r.width;
                            enforce(v.valid==expected[p].valid,"Window validity");
                            if(!v.valid)continue;
                            if(feature==Feature.dynamicRange)enforce(v.channels[0]==ranges[p],"Window extrema");
                            else {
                                measured.maxMeanError=max(measured.maxMeanError,abs(v.channels[0]-expected[p].channels[0]));
                                measured.maxDeviationError=max(measured.maxDeviationError,abs(v.channels[1]-expected[p].channels[1]));
                                ++measured.samples;
                                enforce(abs(v.channels[0]-expected[p].channels[0])<=
                                    (pattern==1?0.000244140625:1e-14),"Window mean");
                                enforce(abs(v.channels[1]-expected[p].channels[1])<1e-14,"Window standard deviation");
                            }
                        }
                    });
                enforce(engine.metrics.peakTileBytes<=8*1024*1024,"Window scratch budget");
            }
        }
    }
    Source extremes;
    extremes.width=9;extremes.height=3;extremes.grid="extreme";extremes.band="K";extremes.unit="K";
    extremes.read=(Region2D r,scope Sample[] cells) {
        foreach(i,ref c;cells)c=Sample(r.x+i%r.width<4?1e200:-1e200,[0,0,0],true);
    };
    Engine fallback;
    fallback.run(extremes,Region2D(0,0,9,3),Feature.localStatistics,256,LocalStatisticsParams(1,9),
        (Region2D r,scope const(Value)[] cells,Provenance p) {
            foreach(i,c;cells)if((r.x+i%r.width)>=6)
                enforce(c.valid && c.channels[0]== -1e200 && c.channels[1]==0,"Extreme fallback");
        });
    Source contrast;
    contrast.width=21;contrast.height=11;contrast.grid="contrast-transition";
    contrast.band="measurement";contrast.unit="1";
    contrast.read=(Region2D r,scope Sample[] cells) {
        foreach(i,ref c;cells) {
            const x=r.x+i%r.width;
            c=Sample(x<5?1e6:1e-8*(x%3),[0,0,0],true);
        }
    };
    Engine rebased;
    rebased.run(contrast,Region2D(0,0,21,11),Feature.localStatistics,256,LocalStatisticsParams(1,9),
        (Region2D r,scope const(Value)[] cells,Provenance p) {
            foreach(i,c;cells) {
                const x=r.x+i%r.width;
                if(x<7 || x>=20)continue;
                enforce(c.valid && abs(c.channels[0]-1e-8)<1e-22,"Low-variance mean after high contrast");
                enforce(abs(c.channels[1]-sqrt(2.0/3)*1e-8)<1e-22,"Low-variance rebase");
            }
        });
    return measured;
}
