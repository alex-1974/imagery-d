# M6 primitive benchmark protocol

Run the same input plane and tile plan in serial and bounded parallel modes.
Record median and p95 over at least 30 iterations after five warm-up runs.
The required matrix is 1920x1080 and 3840x2160, tile sizes 256, 512 and 1024,
worker limits 1, 2 and 4, with and without a validity mask.

Report wall-clock time per complete image and allocation count. The target
for interactive work is 16.7 ms (60 fps); 30 ms is the fallback target
(approximately 33 fps). Results are machine-specific and must include DMD/LDC
and CPU details.
