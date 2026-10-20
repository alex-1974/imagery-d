#!/usr/bin/env python3
"""Verify a small offline imagery corpus and optionally emit local raw pixels."""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import struct
import sys

VALID_ID = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
GENERATOR = "m4-grid-v1"


def bytes_per_sample(dtype: str) -> int:
    return {"u8": 1, "u16le": 2, "f32le": 4}[dtype]


def fixture_bytes(f: dict) -> bytes:
    """Interleaved row-major payload with no header or row padding."""
    if f["generator"] not in (GENERATOR, "m4-mask-v1") or f["dtype"] not in (
        "u8", "u16le", "f32le"
    ):
        raise ValueError("unknown generator/dtype")
    if f["generator"] == "m4-mask-v1" and (
        f["dtype"] != "u8" or f["channels"] != 1
    ):
        raise ValueError("mask must be one u8 channel")
    w, h, bands = f["width"], f["height"], f["channels"]
    ox, oy = f["origin"]
    if any(type(v) is not int for v in (w, h, bands, ox, oy)):
        raise ValueError("shape/origin must be integers")
    if not (1 <= w <= 4096 and 1 <= h <= 4096 and 1 <= bands <= 16):
        raise ValueError("invalid shape")
    if not (0 <= ox <= 1_000_000 and 0 <= oy <= 1_000_000):
        raise ValueError("invalid global origin")
    if w * h * bands * bytes_per_sample(f["dtype"]) > 16 * 1024 * 1024:
        raise ValueError("M4 fixture exceeds 16 MiB")
    payload = bytearray()
    for y in range(oy, oy + h):
        for x in range(ox, ox + w):
            for ch in range(bands):
                if f["generator"] == "m4-mask-v1":
                    payload.append((0, 128, 255)[(x + 2 * y) % 3])
                elif f["dtype"] == "u8":
                    payload.append((29 * x + 31 * y + 17 * ch + 7) % 256)
                elif f["dtype"] == "u16le":
                    payload.extend(struct.pack(
                        "<H", (257 * x + 4099 * y + 1009 * ch + 11) % 65536))
                else:
                    # Exact finite binary32 values independent of host endianness.
                    payload.extend(struct.pack(
                        "<f", ((7 * x + 11 * y + 3 * ch) % 128) / 128.0))
    return bytes(payload)


def verify_manifest(manifest: dict) -> dict[str, bytes]:
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported M4 manifest schema")
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ValueError("fixtures must be a nonempty array")
    actual, metadata = {}, {}
    for f in fixtures:
        name = f["id"]
        if not isinstance(name, str) or not VALID_ID.fullmatch(name) or name in actual:
            raise ValueError("duplicate or unsafe fixture id")
        if (f.get("provenance") != "synthetic:" + f.get("generator", "") or
                f.get("retrieval") != "offline-generator"):
            raise ValueError("provenance/retrieval must be explicit and offline")
        payload = fixture_bytes(f)
        if len(payload) != f.get("byte_length"):
            raise ValueError(f"{name}: byte_length mismatch")
        if hashlib.sha256(payload).hexdigest() != f.get("sha256"):
            raise ValueError(f"{name}: SHA-256 mismatch")
        actual[name], metadata[name] = payload, f
    relations = manifest.get("relations", [])
    if not isinstance(relations, list):
        raise ValueError("relations must be an array")
    for relation in relations:
        if relation.get("kind") != "horizontal-seam":
            raise ValueError("unknown relation")
        whole, left, right = (metadata[relation[k]]
                              for k in ("whole", "left", "right"))
        if not (whole["dtype"] == left["dtype"] == right["dtype"] and
                whole["channels"] == left["channels"] == right["channels"] and
                whole["height"] == left["height"] == right["height"] and
                whole["origin"] == left["origin"] and
                right["origin"] == [
                    left["origin"][0] + left["width"], left["origin"][1]] and
                whole["width"] == left["width"] + right["width"]):
            raise ValueError("horizontal-seam geometry or dtype mismatch")
        stride = whole["channels"] * bytes_per_sample(whole["dtype"])
        lw, rw = left["width"] * stride, right["width"] * stride
        combined = b"".join(
            actual[left["id"]][y * lw:(y + 1) * lw] +
            actual[right["id"]][y * rw:(y + 1) * rw]
            for y in range(whole["height"]))
        if combined != actual[whole["id"]]:
            raise ValueError("horizontal-seam bytes differ from whole image")
    return actual


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", type=pathlib.Path,
                   default="tests/corpus/m4-v1.json")
    p.add_argument("--materialize", type=pathlib.Path,
                   help="optional local raw payload directory, outside tracked Git")
    a = p.parse_args()
    try:
        fixtures = verify_manifest(json.loads(a.manifest.read_text("utf-8")))
        if a.materialize is not None:
            if a.materialize.is_symlink():
                raise ValueError("refuse symlink materialization directory")
            a.materialize.mkdir(parents=True, exist_ok=True)
            for name, data in fixtures.items():
                path = a.materialize / (name + ".raw")
                if path.is_symlink():
                    raise ValueError("refuse symlink output")
                path.write_bytes(data)
                if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(data).digest():
                    raise ValueError("post-write digest mismatch")
        print(f"M4_CORPUS=PASS; fixtures={len(fixtures)} "
              f"relations={len(json.loads(a.manifest.read_text('utf-8'))['relations'])} "
              f"total_bytes={sum(map(len, fixtures.values()))} network=0")
        return 0
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as err:
        print(f"M4_CORPUS=FAIL; {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
