module app;

import std.stdio : writeln;

// Each is a separately compiled consumer module. Imports are per-module;
// accidental imports in this entry point cannot make their tests pass.
import consumers.root_only;
import consumers.core_only;
import consumers.presentation_only;
import consumers.all_only;
import consumers.direct : runDirectConsumer;
import consumers.roi : runImageRoiConsumer;
import consumers.tiles : runTileBackgroundConsumer;

void main()
{
    runDirectConsumer();
    runImageRoiConsumer();
    runTileBackgroundConsumer();
    writeln("M3 import-surface PASS: curated root, core, presentation, ",
            "all, direct symbols and immutable metadata reuse");
}
