module consumers.root_only;

// This consumer sees the curated root, and never imports presentation.
import imagery;

static assert(__traits(compiles, ChannelDescriptor(42)));
static assert(__traits(compiles, IntrinsicChannel.init));
static assert(__traits(compiles, ImageView!float.init));
static assert(!__traits(compiles, ResearchLongLivedMetadataSource.init));
static assert(!__traits(compiles, ColourBinding.init));
