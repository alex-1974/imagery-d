#!/bin/sh
set -eu
cd "$(dirname "$0")"
url="https://sentinel-cogs.s3.amazonaws.com/sentinel-s2-l2a-cogs/12/R/UU/2024/4/S2A_12RUU_20240421_0_L2A/B02.tif"
for compiler in dmd ldc2; do
    dub run --compiler="$compiler" --force -- "$url"
done
echo "imagery URL imageio consumer passed under DMD/LDC"
