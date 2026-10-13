module consumers.direct;

// Demonstrates direct module and symbol-filtered imports.
import imagery.core.channel : ChannelDescriptor;
import imagery.core.metadata : IntrinsicChannel;
import imagery.core.image : ImageView;
import imagery.presentation.channels :
    ColourBinding, DeclaredColour, ValueInterpretation,
    ResearchLongLivedMetadataSource, SourceRoiError;

static assert(__traits(compiles, ImageView!float.init));
static assert(__traits(compiles, ValueInterpretation.physical));

private void check(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

/// Real ownership/metadata consumer smoke through *only* direct imports.
void runDirectConsumer()
{
    auto ids = [
        ChannelDescriptor(17), ChannelDescriptor(22),
        ChannelDescriptor(81)
    ];
    auto intrinsic = [
        IntrinsicChannel(17, "red", "unknown", true, 0.5f, 1.0f),
        IntrinsicChannel(22, "nir", "unknown", true, 2.0f, -1.0f),
        IntrinsicChannel(81, "blue", "unknown", true, 1.0f, 0.0f)
    ];
    auto binding = ColourBinding(1, 0, 2, DeclaredColour.unspecified);
    check(binding.redChannel == 1 && binding.greenChannel == 0,
        "selected channel order changed");

    auto first = ResearchLongLivedMetadataSource.snapshot(
        ids[], intrinsic[]);
    check(first.channelCount == 3, "snapshot metadata count");
    check(first.identities[0].semanticId == 17,
        "initial immutable identity");
    check(first.metadata[1].sourceLabel == "nir",
        "source labels stay opaque");

    // Prove the root imports are real compiled code, not empty stubs:
    // an unrelated mutable alias must not mutate this older generation.
    ids[0] = ChannelDescriptor(333);
    intrinsic[0] = IntrinsicChannel(
        333, "after", "unknown", true, 3.0f, 4.0f);
    check(first.identities[0].semanticId == 17
        && first.metadata[0].scale == 0.5f,
        "snapshot leaked mutable alias");
    auto later = ResearchLongLivedMetadataSource.snapshot(
        ids[], intrinsic[]);
    check(later.identities[0].semanticId == 333
        && later.metadata[0].sourceLabel == "after",
        "explicit refresh not published");

    // Already genuinely immutable arrays may be retained without a
    // redundant copy; this is not a mutable-to-immutable cast.
    immutable(ChannelDescriptor)[] sealedIds = ids.idup;
    immutable(IntrinsicChannel)[] sealedMeta = intrinsic.idup;
    auto borrowed = ResearchLongLivedMetadataSource.fromImmutable(
        sealedIds, sealedMeta);
    check(borrowed.channelCount == 3
        && borrowed.identities[0].semanticId == 333,
        "immutable provider mismatch");
}
