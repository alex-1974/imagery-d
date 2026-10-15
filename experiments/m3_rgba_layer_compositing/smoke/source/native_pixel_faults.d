module native_pixel_faults;

// Issue #75, independent native glibc fault experiment ONLY.
// No symbols/configuration added to imagery-d production modules.
// No role in the earlier all-success allocation-event trace protocols.
version (M3_NATIVE_PIXEL_FAULTS)
{
    import core.sys.posix.dlfcn : dlsym;

    private alias ArmFn = extern(C) void function(uint, size_t);
    private alias GetterFn = extern(C) uint function();
    private ArmFn armFn;
    private ArmFn intentFn;
    private GetterFn failureCountFn;
    private GetterFn failureKindFn;
    private GetterFn scratchAllocatedFn;
    private GetterFn scratchFreedFn;

    void prepareNativePixelFaults()
    {
        armFn = cast(ArmFn)dlsym(null, "m3_fault_arm\0".ptr);
        intentFn = cast(ArmFn)dlsym(null, "m3_fault_intent\0".ptr);
        failureCountFn = cast(GetterFn)dlsym(null,
            "m3_fault_failed_count\0".ptr);
        failureKindFn = cast(GetterFn)dlsym(null,
            "m3_fault_failed_kind\0".ptr);
        scratchAllocatedFn = cast(GetterFn)dlsym(null,
            "m3_fault_scratch_allocated\0".ptr);
        scratchFreedFn = cast(GetterFn)dlsym(null,
            "m3_fault_scratch_freed\0".ptr);
        if (armFn is null || intentFn is null ||
            failureCountFn is null || failureKindFn is null ||
            scratchAllocatedFn is null || scratchFreedFn is null)
            throw new Exception("missing native malloc fault interposer");
    }

    void armNativePixelFault(uint kind, size_t bytes)
    {
        armFn(kind, bytes);
    }
    void nativeFaultPixelIntent(uint kind, size_t bytes)
    {
        if (intentFn !is null)
            intentFn(kind, bytes);
    }
    uint nativePixelFailureCount() { return failureCountFn(); }
    uint nativePixelFailedKind() { return failureKindFn(); }
    uint nativeScratchAllocations() { return scratchAllocatedFn(); }
    uint nativeScratchFrees() { return scratchFreedFn(); }
}
else
{
    void prepareNativePixelFaults() {}
    void armNativePixelFault(uint kind, size_t bytes) {}
    void nativeFaultPixelIntent(uint kind, size_t bytes) {}
    uint nativePixelFailureCount() { return 0; }
    uint nativePixelFailedKind() { return 0; }
    uint nativeScratchAllocations() { return 0; }
    uint nativeScratchFrees() { return 0; }
}
