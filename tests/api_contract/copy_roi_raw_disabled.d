module copy_roi_raw_disabled;
import imagery.analysis.execution : copyRoi, PlaneWindow, Roi;

// Rejected even from @system code: raw pointer extent/type provenance is absent.
void rejected() @system
{
    PlaneWindow input;
    float[] output;
    copyRoi!float(input, Roi(0, 0, 1, 1), output);
}
