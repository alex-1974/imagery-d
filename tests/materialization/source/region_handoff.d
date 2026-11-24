module region_handoff;

import imagery.io : materializeUbyte;
import imageio : inspectTiff=inspect, decodeRegion;
import transport : FileSource;
import std.algorithm : min,max;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue;

// Consumer fixture, deliberately not a new imagery/CRS framework. Dunia owns
// registration, band meaning and NoData membership; imagery owns materialization.
JSONValue checkRegionHandoff(string path,size_t channels=1)
{
    auto source=new FileSource(path);
    auto metadata=inspectTiff(source);enforce(metadata.ok,"GeoTIFF metadata inspection");
    const info=metadata.info;
    enforce(info.hasProjectedCrsGeoKey && info.projectedCrsGeoKey==32633 &&
        info.hasRasterTypeGeoKey && info.rasterTypeGeoKey==1 &&
        info.modelPixelScale.length==3 && info.modelTiepoint.length==6 &&
        info.modelTransformation.length==0 && info.noDataValue.length,"fixture GeoTIFF contract");
    // This fixture explicitly declares north-up UTM metres / PixelIsArea. No
    // generic CRS lookup or reprojection is smuggled into imagery-d.
    enforce(info.modelPixelScale[0]==2 && info.modelPixelScale[1]==2 &&
        info.modelTiepoint[0]==0 && info.modelTiepoint[1]==0);
    double[6] transform=[info.modelTiepoint[3],info.modelPixelScale[0],0,
        info.modelTiepoint[4],0,-info.modelPixelScale[1]];
    const(ubyte)[] nodataText=info.noDataValue;
    while(nodataText.length && nodataText[$-1]==0)nodataText=nodataText[0..$-1];
    const noData=to!double(cast(string)nodataText);
    enforce(noData==0);
    enum x=3,y=1,w=9,h=7;
    auto decoded=decodeRegion(source,x,y,w,h);enforce(decoded.ok,"GeoTIFF visible region decode: "~to!string(decoded.error));
    enforce(decoded.region.info.width==w && decoded.region.info.height==h &&
        decoded.region.originX==x && decoded.region.originY==y && decoded.region.info.componentCount==channels);
    auto frame=materializeUbyte(decoded.region,w*h*channels);enforce(frame.ok);
    auto retained=frame.raster;
    // Decoder output may disappear; the materialized raster must stay valid.
    decoded.region.data[]=255; // prove storage independence before releasing input
    decoded=typeof(decoded).init;
    source=null; // FileSource reads are self-contained; retain no source object.
    auto view=retained.view();
    ubyte[] pixels,validity;
    foreach(yy;0..h)foreach(xx;0..w)
    {
        bool valid;
        foreach(c;0..channels)
        {
            ubyte value;enforce(view.trySample(c,xx,yy,value));pixels~=value;
            valid|=value!=noData; // explicit consumer NoData membership
        }
        validity~=cast(ubyte)valid;
    }
    const left=transform[0]+x*transform[1],top=transform[3]+y*transform[5];
    JSONValue result;
    result["source_identity"]=JSONValue(channels==1?"gdal-geotiff-intensity-fixture":"gdal-geotiff-rgb-fixture");
    result["source_revision"]=JSONValue("fixture-v1");
    result["grid"]=JSONValue("utm33-pixel-area-v1");
    result["crs"]=JSONValue("EPSG:"~to!string(info.projectedCrsGeoKey));
    result["units"]=JSONValue("m");
    result["source_transform"]=JSONValue(transform[]);
    result["roi_transform"]=JSONValue([left,transform[1],0,top,0,transform[5]]);
    result["extent"]=JSONValue([left,top+h*transform[5],left+w*transform[1],top]);
    result["first_pixel_center"]=JSONValue([left+.5*transform[1],top+.5*transform[5]]);
    result["gsd"]=JSONValue([transform[1],-transform[5]]);
    result["region"]=JSONValue([x,y,w,h]);
    result["overview"]=JSONValue(0);
    result["bands"]=JSONValue(channels==1?["intensity"]:["red","green","blue"]);
    result["band_units"]=JSONValue(channels==1?["1"]:["1","1","1"]);
    result["alpha"]=JSONValue("absent");
    result["nodata"]=JSONValue(noData);
    result["validity_policy"]=JSONValue(channels==1?"single-band-equals-u8-nodata-v1":"all-bands-equal-u8-nodata-v1");
    result["pixels"]=JSONValue(pixels);result["validity"]=JSONValue(validity);
    result["owned_bytes"]=JSONValue(w*h*channels);
    return result;
}
