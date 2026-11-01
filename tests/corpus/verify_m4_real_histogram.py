#!/usr/bin/env python3
"""Check RGB histogram behavior on every pinned M4 real-image source.

This optional offline test needs Pillow for JPEG decoding. For each source,
the same decoded bytes feed the independent Python oracle and D P6 consumer.
"""

import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests/corpus/m4-real-v1.json"
IMAGE_DIR = ROOT / "data/m4"


def reference(raw: bytes, width: int, roi: tuple[int, int, int, int],
              mask: bytes | None = None) -> dict:
    x0, y0, w, h = roi
    bins = [[0] * 256 for _ in range(3)]
    sums = [0, 0, 0]
    minimum = [255, 255, 255]
    maximum = [0, 0, 0]
    included = excluded = 0
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            pixel = y * width + x
            if mask is not None and mask[pixel] == 0:
                excluded += 1
                continue
            included += 1
            for channel in range(3):
                value = raw[3 * pixel + channel]
                bins[channel][value] += 1
                sums[channel] += value
                minimum[channel] = min(minimum[channel], value)
                maximum[channel] = max(maximum[channel], value)
    return {
        "includedPixels": included,
        "excludedPixels": excluded,
        "bins": bins,
        "minimum": minimum if included else [0, 0, 0],
        "maximum": maximum if included else [0, 0, 0],
        "mean": [total / included for total in sums] if included else [0.0] * 3,
    }


def check(actual: dict, expected: dict) -> None:
    if actual.keys() != expected.keys():
        raise AssertionError("incomplete histogram record")
    for key in ("includedPixels", "excludedPixels", "bins", "minimum", "maximum"):
        if actual[key] != expected[key]:
            raise AssertionError(f"real-image histogram mismatch: {key}")
    if len(actual["mean"]) != 3:
        raise AssertionError("real-image RGB mean shape mismatch")
    for got, want in zip(actual["mean"], expected["mean"]):
        if not math.isfinite(got) or not math.isclose(got, want, rel_tol=0,
                                                     abs_tol=1e-12):
            raise AssertionError("real-image RGB mean mismatch")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_real_histogram.py PPM_EXECUTABLE TMPDIR")
    try:
        from PIL import Image, features
    except ImportError as error:
        raise SystemExit("Pillow is required for this optional JPEG decode check") from error
    exe = Path(sys.argv[1]).resolve()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 2:
        raise AssertionError("unexpected M4 real manifest schema")
    sources = manifest["sources"]
    cases = 0
    with tempfile.TemporaryDirectory(prefix="m4-real-histogram-",
                                     dir=sys.argv[2]) as name:
        directory = Path(name)
        for record in sources:
            image_path = IMAGE_DIR / record["filename"]
            source = image_path.read_bytes()
            if (len(source) != record["byte_length"] or
                    hashlib.sha256(source).hexdigest() != record["sha256"]):
                raise AssertionError(f"pinned source differs: {record['id']}")
            with Image.open(image_path) as image:
                if image.format != "JPEG" or image.size != (
                        record["width"], record["height"]):
                    raise AssertionError(f"format or dimensions differ: {record['id']}")
                raw = image.convert("RGB").tobytes()
            width, height = record["width"], record["height"]
            if len(raw) != width * height * 3:
                raise AssertionError("decoded RGB payload size differs")
            ppm = directory / f"{record['id']}.ppm"
            ppm_bytes = f"P6\n{width} {height}\n255\n".encode("ascii") + raw
            ppm.write_bytes(ppm_bytes)

            def execute(roi: tuple[int, int, int, int],
                        mask: bytes | None = None) -> dict:
                nonlocal cases
                args = [str(exe), "--histogram", str(ppm), *map(str, roi)]
                if mask is not None:
                    selection = directory / f"{record['id']}-selection.raw"
                    selection.write_bytes(mask)
                    args.append(str(selection))
                run = subprocess.run(args, check=True, capture_output=True,
                                     text=True, timeout=30)
                actual = json.loads(run.stdout)
                check(actual, reference(raw, width, roi, mask))
                cases += 1
                return actual

            whole = execute((0, 0, width, height))
            left = execute((0, 0, width // 2, height))
            right = execute((width // 2, 0, width - width // 2, height))
            for channel in range(3):
                if whole["bins"][channel] != [
                    left["bins"][channel][value] + right["bins"][channel][value]
                    for value in range(256)
                ]:
                    raise AssertionError("real-image partition histogram mismatch")
            roi = (width // 16, height // 9,
                   max(1, width // 8), max(1, height // 7))
            execute(roi)
            mask = bytes(0 if (x // 32 + y // 32) % 3 == 0 else 255
                         for y in range(height) for x in range(width))
            execute(roi, mask)
            if ppm.read_bytes() != ppm_bytes:
                raise AssertionError("P6 consumer modified input")
            if hashlib.sha256(image_path.read_bytes()).hexdigest() != record["sha256"]:
                raise AssertionError("P6 consumer modified pinned source")
    print(f"M4_REAL_RGB_HISTOGRAM=PASS; sources:{len(sources)},cases:{cases},"
          f"jpeg_decoder:Pillow-{Image.__version__}/{features.version('jpg')},"
          "network:0")


if __name__ == "__main__":
    main()
