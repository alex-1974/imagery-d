module app;
import core.time : MonoTime;
import imagery.analysis.primitives : gaussianBlur, sobel, canny;
import std.algorithm.sorting : sort;
import std.stdio : writefln;
import std.string : toLower;
enum warmups = 2, runs = 7;
long measure(size_t w, size_t h, size_t op) { auto n=w*h; auto src=new float[](n); auto a=new float[](n); auto b=new float[](n); auto e=new ubyte[](n); foreach(i;0..n)src[i]=cast(float)((i*37)&255)/255.0f; auto t0=MonoTime.currTime; foreach(i;0..warmups+runs){if(op==0)gaussianBlur(src,w,h,1.2f,a);else if(op==1)sobel(src,w,h,a,b);else canny(src,w,h,0.15f,0.3f,e);} return (MonoTime.currTime-t0).total!"nsecs"/(runs); }
void main(string[] args) { bool full=args.length==0; bool fourK=args.length>1 && toLower(args[1])=="4k"; int selected=-1;if(args.length>2){auto k=toLower(args[2]);selected=k=="gaussian"?0:k=="sobel"?1:k=="canny"?2:-1;} auto dims=fourK?[[3840,2160]]:[[1920,1080]]; foreach(dim;dims) foreach(op;0..3) if(selected<0||selected==op){long[] times;foreach(i;0..runs)times~=measure(dim[0],dim[1],op);times.sort();writefln("%s %dx%d median=%.3fms p95=%.3fms",op==0?"gaussian":op==1?"sobel":"canny",dim[0],dim[1],times[$/2]/1_000_000.0,times[$-1]/1_000_000.0);} }
