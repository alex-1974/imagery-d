module generation_memory_linux;

// Issue #74. DIAGNOSTIC ONLY: Linux/glibc per-process memory snapshots.
// Neither /proc nor mallinfo2 is a portable allocator contract.
// Read into a fixed stack buffer: no D arrays, GC strings or allocations
// introduced by the sampler itself. The original GC thread counter is
// reported separately and is NOT part of mallinfo2.
version(linux)
{
    import core.stdc.stdio : FILE, fopen, fclose, fgets;
    import core.stdc.stdlib : strtoull;
    import core.stdc.string : strncmp;
    import core.memory : GC;

    // glibc mallinfo2 (not mallinfo: avoid integer overflow). Only valid
    // for Linux/glibc; uordblks counts allocator heap chunks but not
    // all mmapped backing bytes, which are reported separately as hblkhd.
    private struct MallInfo2
    {
        size_t arena, ordblks, smblks, hblks, hblkhd;
        size_t usmblks, fsmblks, uordblks, fordblks, keepcost;
    }
    extern(C) private MallInfo2 mallinfo2();

    struct MemorySnapshot
    {
        bool ok;
        size_t vmRssKiB, vmHwmKiB;
        size_t mallocUsedBytes, mallocMappedBytes, mallocFreeBytes;
        size_t gcAllocatedByCurrentThread;
    }

    MemorySnapshot sampleGenerationMemory()
    {
        MemorySnapshot result;
        auto status = fopen("/proc/self/status", "r");
        if (status is null)
            return result;
        char[256] line;
        bool rss, hwm;
        while (fgets(line.ptr, cast(int)line.length, status) !is null)
        {
            if (strncmp(line.ptr, "VmRSS:", 6) == 0)
            {
                result.vmRssKiB = cast(size_t)strtoull(line.ptr + 6, null, 10);
                rss = true;
            }
            else if (strncmp(line.ptr, "VmHWM:", 6) == 0)
            {
                result.vmHwmKiB = cast(size_t)strtoull(line.ptr + 6, null, 10);
                hwm = true;
            }
        }
        fclose(status);
        if (!rss || !hwm)
            return result;
        const native = mallinfo2();
        result.mallocUsedBytes = native.uordblks;
        result.mallocMappedBytes = native.hblkhd;
        result.mallocFreeBytes = native.fordblks;
        result.gcAllocatedByCurrentThread =
            GC.stats().allocatedInCurrentThread;
        result.ok = true;
        return result;
    }
}
