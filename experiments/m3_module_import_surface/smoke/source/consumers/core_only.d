module consumers.core_only;

// Import only one supported semantic family.
import imagery.core;

static assert(__traits(compiles, ChannelDescriptor(42)));
static assert(__traits(compiles, IntrinsicChannel.init));
static assert(__traits(compiles, ImageView!float.init));
static assert(!__traits(compiles, SourceRoiError.init));
static assert(!__traits(compiles, ColourBinding.init));
