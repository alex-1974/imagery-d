module consumers.presentation_only;

// Presentation is usable without pulling core names into this namespace.
import imagery.presentation;

static assert(__traits(compiles, ColourBinding.init));
static assert(__traits(compiles, ValueInterpretation.physical));
static assert(__traits(compiles, ResearchLongLivedMetadataSource.init));
static assert(__traits(compiles, SourceRoiError.none));
static assert(!__traits(compiles, ChannelDescriptor.init));
