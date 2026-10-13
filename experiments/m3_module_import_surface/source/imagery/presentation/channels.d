/++
    RESEARCH ONLY: selected display components and scoped ROI execution.
    Metadata source still owns no raster pixels and can only borrow
    valid raster/validity views during its @safe @nogc mapping call.
+/
module imagery.presentation.channels;

public import m3_2_channel_metadata.contract :
    ColourBinding, DeclaredColour, ValueInterpretation;
public import m3_2_metadata_source.contract :
    ResearchLongLivedMetadataSource, SourceRoiError;
