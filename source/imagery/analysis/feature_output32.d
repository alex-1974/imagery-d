/++
Convert feature results into the internal float32 output representation. The
region engine and prepared workers share this policy. Applications start with
`Engine.runPlanar` or `Float32FeatureWorker` rather than importing this
implementation module.
+/
module imagery.analysis.feature_output32;

import imagery.analysis.feature_regions : Value;
import std.math : isFinite;

@safe:

package struct Float32TileOutput
{
    float[][3] channels;
    ubyte[] valid,oriented,range;
    double[] rawPath;

    pragma(inline,true)
    void initialize(size_t count,bool initialValid) scope nothrow @nogc {
        foreach(ref c;channels)c[0..count]=0;
        valid[0..count]=cast(ubyte)initialValid;oriented[0..count]=0;range[0..count]=0;
        if(rawPath.length)rawPath[0..count]=0;
    }
    pragma(inline,true)
    bool mathematicalValid(size_t i) const scope nothrow @nogc { return valid[i]!=0 || range[i]!=0; }
    pragma(inline,true)
    double scalarAt(size_t i) const scope nothrow @nogc { return rawPath[i]; }
    pragma(inline,true)
    void invalidate(size_t i) scope nothrow @nogc {
        foreach(ref c;channels)c[i]=0;
        valid[i]=oriented[i]=range[i]=0;
        if(rawPath.length)rawPath[i]=0;
    }
    pragma(inline,true)
    void setValue(size_t i,Value value) scope nothrow @nogc {
        if(!value.valid) {invalidate(i);return;}
        float[3] converted;
        foreach(c;0..3)converted[c]=cast(float)value.channels[c];
        if(!isFinite(converted[0]) || !isFinite(converted[1]) || !isFinite(converted[2])) {
            invalidate(i);
            foreach(v;value.channels)if(!isFinite(v))return;
            if(rawPath.length)rawPath[i]=value.channels[0];
            range[i]=1;return;
        }
        foreach(c;0..3)channels[c][i]=converted[c];
        valid[i]=1;range[i]=0;oriented[i]=cast(ubyte)(value.orientationValid && converted[0]!=0);
        if(rawPath.length)rawPath[i]=value.channels[0];
    }
    // Row kernels prove a finite bounded numeric domain before this policy:
    // float32 overflow is impossible, but strength underflow still clears axes.
    pragma(inline,true)
    void setFiniteValue(size_t i,Value value) scope nothrow @nogc {
        foreach(c;0..3)channels[c][i]=cast(float)value.channels[c];
        valid[i]=1;range[i]=0;
        oriented[i]=cast(ubyte)(value.orientationValid&&channels[0][i]!=0);
    }
    pragma(inline,true)
    void setScalar(size_t i,double value) scope nothrow @nogc {channels[0][i]=cast(float)value;}
    pragma(inline,true)
    Float32TileOutput row(size_t start,size_t count) return scope nothrow @nogc {
        float[][3] sliced;
        foreach(c;0..3)sliced[c]=channels[c][start..start+count];
        return Float32TileOutput(sliced,valid[start..start+count],oriented[start..start+count],
            range[start..start+count],null);
    }
    pragma(inline,true)
    void putChannel(size_t i,size_t channel,double value) scope nothrow @nogc {
        // A profile needs every channel. Once a channel is unrepresentable,
        // subsequent radii cannot make the complete profile representable.
        if(range[i])return;
        const converted=cast(float)value;
        if(!isFinite(converted)) {invalidate(i);range[i]=1;return;}
        channels[channel][i]=converted;
    }
}

