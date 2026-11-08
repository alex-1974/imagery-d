/++ Curated image-processing entry point. +/
module imagery;
public import imagery.presentation.levels;
public import imagery.analysis.rgb_histogram;
public import imagery.presentation.luminance_stretch;
public import imagery.materialization;
version (imageio_io)
    public import imagery.io;
