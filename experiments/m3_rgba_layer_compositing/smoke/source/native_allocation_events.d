module native_allocation_events;

// Issue #74: Research executable ONLY. No calls in default compilation.
// Linux/glibc LD_PRELOAD recorder exports these named functions; lookup
// happens before recording starts, outside hot producer allocations.
version (M3_NATIVE_ALLOCATION_EVENTS)
{
    import core.sys.posix.dlfcn : dlsym;
    // GNU glibc defines RTLD_DEFAULT as ((void*)0). Druntime's
    // posix.dlfcn bindings do not export the GNU-C preprocessor macro.
    // This bridge is intentionally Linux/glibc-only, not portable POSIX.

    private alias StageFn = extern(C) void function(uint);
    private alias IntentFn = extern(C) void function(uint, size_t);
    private StageFn stageFn;
    private IntentFn intentFn;

    void prepareNativeAllocationEvents()
    {
        stageFn = cast(StageFn)dlsym(null,
            "m3_trace_stage\0".ptr);
        intentFn = cast(IntentFn)dlsym(null,
            "m3_trace_intent\0".ptr);
        if (stageFn is null || intentFn is null)
            throw new Exception("missing research LD_PRELOAD trace recorder");
    }

    void nativeAllocationStage(uint phase)
    {
        if (stageFn !is null)
            stageFn(phase);
    }

    // kind 1=four-channel scratch; kind 2=published packed RGBA.
    void nativePixelAllocationIntent(uint kind, size_t bytes)
    {
        if (intentFn !is null)
            intentFn(kind, bytes);
    }
}
else
{
    // No production API and no research tracer overhead in normal CI
    // consumer builds. The version gate is part of a separate DUB config.
    void prepareNativeAllocationEvents() {}
    void nativeAllocationStage(uint phase) {}
    void nativePixelAllocationIntent(uint kind, size_t bytes) {}
}
