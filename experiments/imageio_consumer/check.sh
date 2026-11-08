#!/bin/sh
set -eu
cd "$(dirname "$0")"
fixture="../../../../../Programmiersprachen/dlang/d-geospatial-workspace/libs/imageio-d/experiments/geotiff_metadata/.build/geotiff-metadata.tif"
../../../../../Programmiersprachen/dlang/d-geospatial-workspace/libs/imageio-d/experiments/geotiff_metadata/oracle_fixture.sh >/dev/null
for compiler in dmd ldc2; do
    dub run --compiler="$compiler" --force -- "$fixture"
done
echo "imagery imageio consumer passed under DMD/LDC"
