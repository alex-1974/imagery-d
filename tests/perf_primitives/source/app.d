module app;
import core.time : MonoTime;
import imagery.analysis.primitives : gaussianBlur, sobel, canny;
import std.algorithm.sorting : sort;
import std.stdio : writefln;
enum warmups = 2, runs = 7;
long measure(size_t w, size_t h, size_t op) { auto n=w*h; auto src=new float[](n); auto a=new float[](n); auto b=new float[](n); auto e=new ubyte[](n); foreach(i;0..n)src[i]=cast(float)((i*37)&255)/255.0f; auto t0=MonoTime.currTime; foreach(i;0..warmups+runs){if(op==0)gaussianBlur(src,w,h,1.2f,a);else if(op==1)sobel(src,w,h,a,b);else canny(src,w,h,0.15f,0.3f,e);} return (MonoTime.currTime-t0).total!"nsecs"/(runs); }
void main() { foreach(dim;[[1920,1080],[3840,2160]]) foreach(op;0..3){long[] times;foreach(i;0..runs)times~=measure(dim[0],dim[1],op);times.sort();writefln("%s %dx%d median=%.3fms p95=%.3fms",op==0?"gaussian":op==1?"sobel":"canny",dim[0],dim[1],times[$/2]/1_000_000.0,times[$-1]/1_000_000.0);} }
