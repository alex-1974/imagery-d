#!/usr/bin/env python3
"""Validate records and optionally fetch the pinned, untracked M4 images."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests/corpus/m4-real-v1.json"
DESTINATION = ROOT / "data/m4"
MAX_SOURCE_BYTES = 16 * 1024 * 1024


def records():
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 2:
        raise ValueError("unsupported M4 real manifest version")
    sources = manifest.get("sources")
    if not isinstance(sources, list) or len(sources) < 3:
        raise ValueError("M4 real corpus requires at least three sources")
    seen_ids = set()
    seen_files = set()
    for record in sources:
        required = {
            "id", "filename", "description", "source_record", "download_url",
            "credit", "source", "acquisition", "format", "width", "height",
            "channels", "byte_length", "sha256",
        }
        if set(record) != required:
            raise ValueError(f"M4 real source fields differ: {record.get('id')}")
        if record["id"] in seen_ids or record["filename"] in seen_files:
            raise ValueError("duplicate M4 real source identity")
        seen_ids.add(record["id"])
        seen_files.add(record["filename"])
        if Path(record["filename"]).name != record["filename"]:
            raise ValueError("M4 real filename must be a basename")
        if record["format"] != "JPEG" or record["channels"] != 3:
            raise ValueError("M4 real corpus currently requires RGB JPEG records")
        if not (0 < record["width"] <= 4096 and 0 < record["height"] <= 4096):
            raise ValueError("M4 real dimensions out of bounds")
        if not (0 < record["byte_length"] <= MAX_SOURCE_BYTES):
            raise ValueError("M4 real byte length out of bounds")
        if len(record["sha256"]) != 64 or any(
                c not in "0123456789abcdef" for c in record["sha256"]):
            raise ValueError("M4 real SHA-256 is malformed")
        if not record["source_record"].startswith("https://") or not record[
                "download_url"].startswith("https://"):
            raise ValueError("M4 real source URLs must use HTTPS")
    return manifest, sources


def verify(data, record):
    if len(data) != record["byte_length"]:
        raise ValueError(f"M4 real image byte length mismatch: {record['id']}")
    if hashlib.sha256(data).hexdigest() != record["sha256"]:
        raise ValueError(f"M4 real image SHA-256 mismatch: {record['id']}")
    if not data.startswith(b"\xff\xd8\xff") or not data.endswith(b"\xff\xd9"):
        raise ValueError(f"M4 real image JPEG framing mismatch: {record['id']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true",
                        help="download every absent pinned image")
    parser.add_argument("--manifest-only", action="store_true",
                        help="validate records without requiring image bytes")
    args = parser.parse_args()
    if args.fetch and args.manifest_only:
        parser.error("--fetch and --manifest-only are mutually exclusive")
    manifest, sources = records()
    if args.manifest_only:
        print(f"M4_REAL_MANIFEST=PASS; collection:{manifest['id']},"
              f"sources:{len(sources)},network:0")
        return

    fetched = 0
    for record in sources:
        destination = DESTINATION / record["filename"]
        if not destination.exists() and args.fetch:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with urlopen(record["download_url"], timeout=30) as response:
                data = response.read(record["byte_length"] + 1)
            verify(data, record)
            with tempfile.NamedTemporaryFile(dir=destination.parent,
                                             prefix=".m4-real-",
                                             delete=False) as tmp:
                tmp.write(data)
                temporary = Path(tmp.name)
            try:
                os.replace(temporary, destination)
                fetched += 1
            finally:
                temporary.unlink(missing_ok=True)
        if not destination.is_file():
            raise FileNotFoundError(
                f"{destination} is absent; run with --fetch for opt-in retrieval")
        verify(destination.read_bytes(), record)
    print(f"M4_REAL_IMAGES=PASS; collection:{manifest['id']},"
          f"sources:{len(sources)},fetched:{fetched}")


if __name__ == "__main__":
    main()
