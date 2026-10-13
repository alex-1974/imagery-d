module consumers.all_only;

// Deliberately broad consumer import, unlike import imagery.
import imagery.all;

static assert(__traits(compiles, ChannelDescriptor(42)));
static assert(__traits(compiles, IntrinsicChannel.init));
static assert(__traits(compiles, ImageView!float.init));
static assert(__traits(compiles, ColourBinding.init));
static assert(__traits(compiles, ResearchLongLivedMetadataSource.init));
