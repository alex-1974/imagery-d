module mixed_delivery_schedule;

// Issue #74 research-only deterministic mixed direct-mapped trace.
// Each 100 events contain the exact requested integer hit percentage.
// Two slots each toggle between distinct ROI keys (0↔2 and 1↔3).
// No RNG, hashing, scheduler, allocations, raster ownership, or thread policy.
@safe pure nothrow @nogc
bool plannedMixedHit(size_t eventIndex, size_t hitPercent)
{
    return ((eventIndex % 100) * 37 + 11) % 100 < hitPercent;
}

@safe pure nothrow @nogc
size_t mixedSlot(size_t eventIndex)
{
    return eventIndex % 2;
}

@safe pure nothrow @nogc
size_t alternateMixedKey(size_t currentKey)
{
    return currentKey ^ 2;
}

@safe pure nothrow @nogc
bool checkMixedDeliverySchedule()
{
    foreach (percent; [25, 75, 95])
    {
        size_t hits;
        size_t[2] keys = [0, 1];
        foreach (eventIndex; 0 .. 100)
        {
            const slot = mixedSlot(eventIndex);
            if (plannedMixedHit(eventIndex, percent))
                ++hits;
            else
                keys[slot] = alternateMixedKey(keys[slot]);
            if (keys[slot] % 2 != slot || keys[slot] >= 4)
                return false;
        }
        if (hits != percent)
            return false;
    }
    return true;
}
