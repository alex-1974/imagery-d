/++
 Explicit overview-grid selection for one logical image extent.

 This module chooses among caller-described grids only. It does not read
 pixels, resample, decode, mosaic, cache or schedule work. Every level must
 cover the same logical extent and use compatible alignment; those
 image/source facts remain the caller's responsibility.
+/
module imagery.pyramid.overview_selection;

/++ Dimensions of one available overview grid.

 A level list is ordered from finest to coarsest. Width and height must both
 be non-increasing, and at least one dimension must strictly decrease at each
 step. Arbitrary non-power-of-two levels and monotonic anisotropic levels are
 valid.
+/
struct OverviewLevel
{
    /// Number of samples across the common logical extent.
    size_t width;
    /// Number of sample rows across the common logical extent.
    size_t height;
}

/++ Result of selecting one entry from the caller's level list. +/
struct OverviewSelection
{
    /// Zero-based index into the exact level list supplied to selection.
    size_t index;
    /++
     True when the selected level has at least the target width and height.
     False means even the finest available level undersamples the requested
     target on one or both axes; index is then zero.
    +/
    bool avoidsUndersampling;
}

/++ Status returned by `trySelectOverviewLevel`.

 The default value deliberately does not mean success.
+/
enum OverviewSelectionError : ubyte
{
    /// No selection call has been attempted.
    notAttempted,
    /// A selection was published.
    none,
    /// Target width or height is zero.
    invalidTarget,
    /// No available level was supplied.
    emptyLevels,
    /// A level is empty, duplicated or not ordered finest to coarsest.
    invalidLevels
}

/++
 Select the coarsest available grid that avoids undersampling a target grid.

 Both the target and every level describe sample dimensions over the same
 caller-defined logical image extent. A level avoids undersampling only when
 its width and height are each at least the corresponding target dimension.
 Among such levels, the last (coarsest) entry is selected. If none qualifies,
 the finest entry at index zero is selected and `avoidsUndersampling` is
 false, making the unavoidable quality deficit explicit.

 The complete list is validated before publication. Empty dimensions,
 duplicate dimensions, an increase on either axis, an empty list or an empty
 target fail and leave `published` unchanged. No multiplication, allocation,
 floating-point comparison or raster access occurs.

 Params:
     levels = Available grids, strictly ordered from finest to coarsest.
     targetWidth = Required horizontal sample count over the common extent.
     targetHeight = Required vertical sample count over the common extent.
     published = Assigned only after complete validation and selection.
 Returns: Explicit success or validation status.

 Example:
 ---
 OverviewLevel[4] levels = [
     OverviewLevel(4000, 3000), OverviewLevel(2000, 1500),
     OverviewLevel(1000, 750), OverviewLevel(500, 375)
 ];
 OverviewSelection selected;
 assert(trySelectOverviewLevel(levels[], 800, 600, selected) ==
     OverviewSelectionError.none);
 assert(selected == OverviewSelection(2, true));
 ---
+/
OverviewSelectionError trySelectOverviewLevel(
    scope const OverviewLevel[] levels,
    size_t targetWidth,
    size_t targetHeight,
    ref OverviewSelection published)
@safe pure nothrow @nogc
{
    if (targetWidth == 0 || targetHeight == 0)
        return OverviewSelectionError.invalidTarget;
    if (levels.length == 0)
        return OverviewSelectionError.emptyLevels;

    OverviewLevel previous = levels[0];
    if (previous.width == 0 || previous.height == 0)
        return OverviewSelectionError.invalidLevels;
    foreach (index; 1 .. levels.length)
    {
        const current = levels[index];
        if (current.width == 0 || current.height == 0 ||
            current.width > previous.width ||
            current.height > previous.height ||
            (current.width == previous.width &&
             current.height == previous.height))
            return OverviewSelectionError.invalidLevels;
        previous = current;
    }

    size_t selectedIndex;
    bool adequate;
    foreach (index, level; levels)
    {
        if (level.width < targetWidth || level.height < targetHeight)
            break;
        selectedIndex = index;
        adequate = true;
    }
    published = OverviewSelection(selectedIndex, adequate);
    return OverviewSelectionError.none;
}

@safe pure nothrow @nogc unittest
{
    OverviewLevel[4] levels = [
        OverviewLevel(4000, 3000), OverviewLevel(2000, 1500),
        OverviewLevel(1000, 750), OverviewLevel(500, 375)
    ];
    OverviewSelection selected;
    assert(trySelectOverviewLevel(levels[], 800, 600, selected) ==
        OverviewSelectionError.none);
    assert(selected == OverviewSelection(2, true));

    assert(trySelectOverviewLevel(levels[], 1000, 750, selected) ==
        OverviewSelectionError.none);
    assert(selected == OverviewSelection(2, true));

    assert(trySelectOverviewLevel(levels[], 100, 100, selected) ==
        OverviewSelectionError.none);
    assert(selected == OverviewSelection(3, true));

    assert(trySelectOverviewLevel(levels[], 8000, 6000, selected) ==
        OverviewSelectionError.none);
    assert(selected == OverviewSelection(0, false));
}

@safe pure nothrow @nogc unittest
{
    // Non-power-of-two and ripmap-like levels remain deterministic.
    OverviewLevel[5] levels = [
        OverviewLevel(4093, 3079), OverviewLevel(2047, 3079),
        OverviewLevel(2047, 1540), OverviewLevel(1024, 770),
        OverviewLevel(513, 385)
    ];
    OverviewSelection selected;
    assert(trySelectOverviewLevel(levels[], 1500, 700, selected) ==
        OverviewSelectionError.none);
    assert(selected == OverviewSelection(2, true));

    OverviewLevel[2] huge = [
        OverviewLevel(size_t.max, size_t.max),
        OverviewLevel(size_t.max - 1, size_t.max)
    ];
    assert(trySelectOverviewLevel(huge[], size_t.max - 1, size_t.max,
        selected) == OverviewSelectionError.none);
    assert(selected == OverviewSelection(1, true));
}

@safe pure nothrow @nogc unittest
{
    OverviewSelection published = OverviewSelection(77, true);
    const sentinel = published;
    OverviewLevel[1] valid = [OverviewLevel(10, 10)];
    assert(trySelectOverviewLevel(valid[], 0, 1, published) ==
        OverviewSelectionError.invalidTarget && published == sentinel);
    OverviewLevel[] noLevels;
    assert(trySelectOverviewLevel(noLevels, 1, 1, published) ==
        OverviewSelectionError.emptyLevels && published == sentinel);

    OverviewLevel[2] empty = [OverviewLevel(10, 10), OverviewLevel(5, 0)];
    OverviewLevel[2] duplicate = [OverviewLevel(10, 10), OverviewLevel(10, 10)];
    OverviewLevel[2] wider = [OverviewLevel(10, 10), OverviewLevel(11, 5)];
    OverviewLevel[2] taller = [OverviewLevel(10, 10), OverviewLevel(5, 11)];
    assert(trySelectOverviewLevel(empty[], 1, 1, published) ==
        OverviewSelectionError.invalidLevels && published == sentinel);
    assert(trySelectOverviewLevel(duplicate[], 1, 1, published) ==
        OverviewSelectionError.invalidLevels && published == sentinel);
    assert(trySelectOverviewLevel(wider[], 1, 1, published) ==
        OverviewSelectionError.invalidLevels && published == sentinel);
    assert(trySelectOverviewLevel(taller[], 1, 1, published) ==
        OverviewSelectionError.invalidLevels && published == sentinel);
}

static assert(OverviewSelectionError.init ==
    OverviewSelectionError.notAttempted);
static assert(OverviewSelectionError.init != OverviewSelectionError.none);
