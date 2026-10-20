#!/usr/bin/env python3
"""Exercise the real P6 Levels consumer on SHA-pinned M4 RGB fixtures."""
from __future__ import annotations

import importlib.util
import json
import math
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "m4_corpus", ROOT / "tools/verify-m4-corpus.py")
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


def p6_header(width: int, height: int) -> bytes:
    return f"P6\n{width} {height}\n255\n".encode("ascii")


def independent_gamma2(raw: bytes) -> bytes:
    return bytes(min(255, int(math.sqrt(value / 255.0) * 255 + 0.5))
                 for value in raw)


def side_by_side(left: bytes, right: bytes, tile_width: int, height: int) -> bytes:
    row = tile_width * 3
    return b"".join(left[y*row:(y+1)*row] + right[y*row:(y+1)*row]
                    for y in range(height))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_levels.py PPM_EXECUTABLE TMPDIR")
    executable = pathlib.Path(sys.argv[1]).resolve()
    tmpdir = pathlib.Path(sys.argv[2]).resolve()
    manifest = json.loads((ROOT / "tests/corpus/m4-v1.json").read_text("utf-8"))
    pixels = corpus.verify_manifest(manifest)
    by_id = {f["id"]: f for f in manifest["fixtures"]}
    processed = {}
    with tempfile.TemporaryDirectory(prefix="m4-levels-", dir=tmpdir) as name:
        path = pathlib.Path(name)
        for label in ("rgb-roi", "rgb-seam-whole",
                      "rgb-seam-left", "rgb-seam-right"):
            meta, original = by_id[label], pixels[label]
            assert meta["dtype"] == "u8" and meta["channels"] == 3
            header = p6_header(meta["width"], meta["height"])
            src, dst = path / (label + "-in.ppm"), path / (label + "-out.ppm")
            src.write_bytes(header + original)
            subprocess.run(
                [str(executable), str(src), str(dst), "0", "1", "2", "0", "1"],
                check=True, capture_output=True, text=True)
            returned = dst.read_bytes()
            assert returned.startswith(header), f"{label}: P6 header"
            processed[label] = returned[len(header):]
            assert processed[label] == independent_gamma2(original), (
                f"{label}: independent byte oracle")
        reconstructed = side_by_side(
            processed["rgb-seam-left"], processed["rgb-seam-right"], 4, 4)
        assert reconstructed == processed["rgb-seam-whole"], (
            "gamma-2 full-image result differs from separate adjacent tiles")
    print("M4_LEVELS_P6_CORPUS=PASS; 4 manifest-hashed RGB P6 fixtures, "
          "independent gamma2 bytes, row-wise seam exact; network=0")


if __name__ == "__main__":
    main()
