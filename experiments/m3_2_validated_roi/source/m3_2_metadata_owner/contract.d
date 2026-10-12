module m3_2_metadata_owner.contract;

import m1_5_image_view.contract : ChannelDescriptor;
import m3_2_channel_metadata.contract : IntrinsicChannel;

/++
    Research-only container for immutable metadata references.

    This is NOT a no-copy freeze operation. Borrowed already-immutable
    backing stays immutable for its full lifetime. Mutable/const backing
    is always copied with .idup before becoming immutable.

    The GC holds the immutable array allocations alive while referenced;
    this struct adds no reference counting or separate allocator policy.
    It is intentionally not a public imagery-d API or a UniqueBuffer.
+/
struct ResearchMetadataState
{
private:
    immutable(ChannelDescriptor)[] ids_;
    immutable(IntrinsicChannel)[] intrinsic_;

public:
    /// Borrow data which is already genuinely immutable; no deep copy.
    static ResearchMetadataState fromImmutable(
        immutable(ChannelDescriptor)[] ids,
        immutable(IntrinsicChannel)[] intrinsic
    ) @safe pure nothrow @nogc
    {
        ResearchMetadataState result;
        result.ids_ = ids;
        result.intrinsic_ = intrinsic;
        return result;
    }

    /++
        Make exactly two independent GC-backed immutable array snapshots.
        const views may still refer to mutable backing: never freeze by cast.
        IntrinsicChannel labels are strings (immutable character backing);
        copying structs retains those safe immutable labels.
    +/
    static ResearchMetadataState snapshot(
        scope const(ChannelDescriptor)[] ids,
        scope const(IntrinsicChannel)[] intrinsic
    ) @safe
    {
        ResearchMetadataState result;
        result.ids_ = ids.idup;
        result.intrinsic_ = intrinsic.idup;
        return result;
    }

    @property size_t channelCount() const @safe pure nothrow @nogc
    {
        return ids_.length;
    }

    @property immutable(ChannelDescriptor)[] identities() const
        return scope @safe pure nothrow @nogc
    {
        return ids_;
    }

    @property immutable(IntrinsicChannel)[] metadata() const
        return scope @safe pure nothrow @nogc
    {
        return intrinsic_;
    }
}

// An illegal direct mutable/const -> immutable conversion must fail to
// compile in both DMD and LDC; these are negative CI build configurations.
version (M3217_NEGATIVE_MUTABLE_FREEZE)
{
    @safe void illegalFreezeMutable(ChannelDescriptor[] ids)
    {
        immutable(ChannelDescriptor)[] wrong = ids;
        assert(wrong.length == ids.length);
    }
}

version (M3217_NEGATIVE_CONST_FREEZE)
{
    @safe void illegalFreezeConst(const(IntrinsicChannel)[] meta)
    {
        immutable(IntrinsicChannel)[] wrong = meta;
        assert(wrong.length == meta.length);
    }
}

unittest
{
    auto sourceIds = [
        ChannelDescriptor(7), ChannelDescriptor(8)
    ];
    auto sourceMeta = [
        IntrinsicChannel(7, "A", "Q", true, 0.5f, -4.0f),
        IntrinsicChannel(8, "B", "Q", true, 2.0f, 1.0f)
    ];
    auto owned = ResearchMetadataState.snapshot(sourceIds[], sourceMeta[]);
    assert(owned.channelCount == 2);
    sourceIds[0] = ChannelDescriptor(777);
    sourceMeta[0] = IntrinsicChannel(777, "changed", "Q", true, 9.0f, 1.0f);
    assert(owned.identities[0].semanticId == 7);
    assert(owned.metadata[0].semanticId == 7);
    assert(owned.metadata[0].scale == 0.5f);

    immutable(ChannelDescriptor)[] alreadyIds = [
        ChannelDescriptor(11), ChannelDescriptor(12)
    ];
    immutable(IntrinsicChannel)[] alreadyMeta = [
        IntrinsicChannel(11, "X", "Q", true, 1.0f, 0.0f),
        IntrinsicChannel(12, "Y", "Q", true, 1.0f, 0.0f)
    ];
    auto borrowed = ResearchMetadataState.fromImmutable(
        alreadyIds, alreadyMeta);
    assert(borrowed.identities.ptr is alreadyIds.ptr);
    assert(borrowed.metadata.ptr is alreadyMeta.ptr);
}
