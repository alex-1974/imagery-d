/++ Curated image-processing entry point. +/
module imagery;
public import imagery.presentation.levels;
public import imagery.presentation.brightness_contrast;
public import imagery.presentation.exposure_curves;
public import imagery.analysis.rgb_histogram;
public import imagery.presentation.luminance_stretch;
public import imagery.materialization;
version (imageio_io)
    public import imagery.io;
public import imagery.pyramid.overview_selection;
public import imagery.compositing.source_over;
// Keep the package facade focused on consumer-facing, established operation
// names. Parallel/partitioned kernels and intermediate Canny stages remain
// available from `imagery.analysis.primitives` for advanced consumers without
// expanding the default import surface.
public import imagery.analysis.filters;
public import imagery.analysis.edges;
public import imagery.analysis.morphology;
public import imagery.analysis.segmentation;
public import imagery.analysis.indices;
