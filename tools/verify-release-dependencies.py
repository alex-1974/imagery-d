#!/usr/bin/env python3
"""Reject dependency drift and optionally retain the exact publication graph."""
import argparse
import json
from pathlib import Path

from release_artifacts import verify_dependencies

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--describe", type=Path, required=True)
parser.add_argument("--baseline", type=Path, default=Path(__file__).resolve().parent.parent /
                    "docs/release/DEPENDENCIES-0.4.0.json")
parser.add_argument("--configuration", choices=("default", "no-io"), required=True)
parser.add_argument("--evidence", type=Path)
args = parser.parse_args()
actual = verify_dependencies(json.loads(args.describe.read_text()),
                             json.loads(args.baseline.read_text()), args.configuration)
if args.evidence:
    evidence = json.loads(args.evidence.read_text())
    evidence.setdefault("publication_dependencies", {})[args.configuration] = actual
    args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
print("RELEASE_DEPENDENCIES=PASS; " + args.configuration + "; " +
      ", ".join(name + "@" + version for name, version in actual.items()))
