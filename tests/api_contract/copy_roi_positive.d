module copy_roi_positive;
import imagery.analysis.execution : copyRoi, Roi;
import raster : RasterPlaneWindow;

@safe nothrow @nogc bool copyWindow(
    scope ref const RasterPlaneWindow!float input, scope float[] output)
{
    return copyRoi(p: input, roi: Roi(0, 0, 1, 1), destination: output);
}

@safe nothrow @nogc bool copyDouble(
    scope ref const RasterPlaneWindow!double input, scope double[] output)
{
    return copyRoi(input, Roi(0, 0, 1, 1), output);
}
