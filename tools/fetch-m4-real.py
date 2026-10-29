#!/usr/bin/env python3
"""Verify or opt-in fetch the first pinned, untracked M4 real-image source."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests/corpus/m4-real-v1.json"
DESTINATION = ROOT / "data/m4/land_ocean_ice_2048.jpg"


def verify(data, record):
    if len(data) != record["byte_length"]:
        raise ValueError("M4 real image byte length mismatch")
    if hashlib.sha256(data).hexdigest() != record["sha256"]:
        raise ValueError("M4 real image SHA-256 mismatch")
    if not data.startswith(b"\xff\xd8\xff") or not data.endswith(b"\xff\xd9"):
        raise ValueError("M4 real image JPEG framing mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true",
                        help="download the pinned NASA image if absent")
    args = parser.parse_args()
    record = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if record["schema_version"] != 1:
        raise ValueError("unsupported M4 real manifest version")

    fetched = False
    if not DESTINATION.exists() and args.fetch:
        DESTINATION.parent.mkdir(parents=True, exist_ok=True)
        with urlopen(record["download_url"], timeout=30) as response:
            data = response.read(record["byte_length"] + 1)
        verify(data, record)
        with tempfile.NamedTemporaryFile(dir=DESTINATION.parent,
                                         prefix=".m4-real-", delete=False) as tmp:
            tmp.write(data)
            temporary = Path(tmp.name)
        try:
            os.replace(temporary, DESTINATION)
            fetched = True
        finally:
            temporary.unlink(missing_ok=True)

    if not DESTINATION.is_file():
        raise FileNotFoundError(
            f"{DESTINATION} is absent; run with --fetch for opt-in retrieval")
    verify(DESTINATION.read_bytes(), record)
    print(f"M4_REAL_IMAGE=PASS; id:{record['id']},sha256:{record['sha256']},"
          f"bytes:{record['byte_length']},network:{int(fetched)}")


if __name__ == "__main__":
    main()
