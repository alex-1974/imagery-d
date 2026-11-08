#!/bin/sh
set -eu
cd "$(dirname "$0")"

dub test --config=default --compiler=dmd --force
dub test --config=default --compiler=ldc2 --force
dub test --config=no-io --compiler=dmd --force
dub test --config=no-io --compiler=ldc2 --force

echo "imagery-d io/no-io checks passed"
