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
    private ArmFn importBeginFn;
    private alias EndFn = extern(C) void function();
    private EndFn importEndFn;
    private GetterFn packedAllocatedFn;
    private GetterFn packedFreedFn;

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
        importBeginFn = cast(ArmFn)dlsym(null,
            "m3_fault_import_begin\0".ptr);
        importEndFn = cast(EndFn)dlsym(null,
            "m3_fault_import_end\0".ptr);
        packedAllocatedFn = cast(GetterFn)dlsym(null,
            "m3_fault_packed_allocated\0".ptr);
        packedFreedFn = cast(GetterFn)dlsym(null,
            "m3_fault_packed_freed\0".ptr);
        if (armFn is null || intentFn is null ||
            failureCountFn is null || failureKindFn is null ||
            scratchAllocatedFn is null || scratchFreedFn is null ||
            importBeginFn is null || importEndFn is null ||
            packedAllocatedFn is null || packedFreedFn is null)
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
    void beginNativeImportFault(uint kind, size_t bytes)
    {
        importBeginFn(kind, bytes);
    }
    void endNativeImportFault() { importEndFn(); }
    uint nativePackedAllocations() { return packedAllocatedFn(); }
    uint nativePackedFrees() { return packedFreedFn(); }
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
    void beginNativeImportFault(uint kind, size_t bytes) {}
    void endNativeImportFault() {}
    uint nativePackedAllocations() { return 0; }
    uint nativePackedFrees() { return 0; }
}
