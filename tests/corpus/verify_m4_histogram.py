#!/usr/bin/env python3
"""Check the real RGB histogram file consumer against SHA-pinned M4 bytes."""
from __future__ import annotations

import importlib.util
import json
import math
import pathlib
import subprocess
import sys
import tempfile
from fractions import Fraction

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "m4_corpus", ROOT / "tools/verify-m4-corpus.py")
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


def reference(raw: bytes, width: int, roi: tuple[int, int, int, int],
              mask: bytes | None) -> dict:
    """Compute from decoded input bytes, independently of the D implementation."""
    x0, y0, w, h = roi
    channels = [[], [], []]
    excluded = 0
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            pixel = y * width + x
            if mask is not None and mask[pixel] == 0:
                excluded += 1
                continue
            for ch in range(3):
                channels[ch].append(raw[3 * pixel + ch])
    bins = [[values.count(v) for v in range(256)] for values in channels]
    return {
        "includedPixels": len(channels[0]), "excludedPixels": excluded,
        "bins": bins,
        "minimum": [min(values, default=0) for values in channels],
        "maximum": [max(values, default=0) for values in channels],
        "mean": [float(Fraction(sum(values), len(values))) if values else 0.0
                 for values in channels],
    }


def check(actual: dict, expected: dict) -> None:
    assert actual.keys() == expected.keys(), "complete histogram record"
    for key in ("includedPixels", "excludedPixels", "bins", "minimum", "maximum"):
        assert actual[key] == expected[key], key
    assert len(actual["mean"]) == 3, "RGB mean shape"
    for got, want in zip(actual["mean"], expected["mean"]):
        assert math.isfinite(got) and math.isclose(got, want, rel_tol=0, abs_tol=1e-12), (
            "mean", got, want)


def check_partitions(whole: dict, parts: list[dict]) -> None:
    for key in ("includedPixels", "excludedPixels"):
        assert whole[key] == sum(part[key] for part in parts), key
    for ch in range(3):
        assert whole["bins"][ch] == [sum(part["bins"][ch][v] for part in parts)
                                     for v in range(256)], "tile bin additivity"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_histogram.py PPM_EXECUTABLE TMPDIR")
    exe = pathlib.Path(sys.argv[1]).resolve()
    manifest = json.loads((ROOT / "tests/corpus/m4-v1.json").read_text("utf-8"))
    # Verify provenance, complete digests and seam law BEFORE invoking the CLI.
    pixels = corpus.verify_manifest(manifest)
    metadata = {f["id"]: f for f in manifest["fixtures"]}
    cases = 0
    negatives = 0
    with tempfile.TemporaryDirectory(prefix="m4-histogram-", dir=sys.argv[2]) as name:
        path = pathlib.Path(name)
        files = {}
        originals = {}
        for label in ("rgb-roi", "rgb-seam-whole", "rgb-seam-left", "rgb-seam-right"):
            meta = metadata[label]
            assert meta["dtype"] == "u8" and meta["channels"] == 3
            header = f"P6\n# verified M4 fixture\n{meta['width']} {meta['height']}\n255\n".encode()
            source = path / (label + ".ppm")
            source.write_bytes(header + pixels[label])
            files[label] = source
            originals[source] = source.read_bytes()

        def execute(label, roi=None, mask=None):
            nonlocal cases
            meta = metadata[label]
            if roi is None:
                roi = (0, 0, meta["width"], meta["height"])
            args = [str(exe), "--histogram", str(files[label]), *map(str, roi)]
            if mask is not None:
                mask_path = path / "selection.raw"
                mask_path.write_bytes(mask)
                args.append(str(mask_path))
            run = subprocess.run(args, check=True, capture_output=True, text=True, timeout=15)
            actual = json.loads(run.stdout)
            check(actual, reference(pixels[label], meta["width"], roi, mask))
            if mask is not None:
                assert mask_path.read_bytes() == mask, "input mask unchanged"
            cases += 1
            return actual

        def reject(args):
            nonlocal negatives
            run = subprocess.run([str(exe), "--histogram", *map(str, args)],
                                 capture_output=True, text=True, timeout=15)
            assert run.returncode != 0 and run.stdout == "", (
                "invalid request must not publish JSON", args, run.stdout)
            negatives += 1

        outputs = {label: execute(label) for label in files}
        check_partitions(outputs["rgb-seam-whole"],
                         [outputs["rgb-seam-left"], outputs["rgb-seam-right"]])
        execute("rgb-roi", (1, 1, 4, 3))
        execute("rgb-seam-whole", (3, 1, 3, 2))  # ROI crosses the tile boundary

        mask = pixels["mask-selection"]
        selected = execute("rgb-seam-whole", mask=mask)
        execute("rgb-seam-whole", (3, 1, 3, 2), mask)
        left_mask = b"".join(mask[y*8:y*8+4] for y in range(4))
        right_mask = b"".join(mask[y*8+4:y*8+8] for y in range(4))
        parts = [execute("rgb-seam-left", mask=left_mask),
                 execute("rgb-seam-right", mask=right_mask)]
        check_partitions(selected, parts)
        execute("rgb-seam-whole", mask=bytes(32))
        all_active = bytes(value or 1 for value in mask)
        all_selected = execute("rgb-seam-whole", mask=all_active)
        check(all_selected, outputs["rgb-seam-whole"])
        single = bytearray(32)
        single[2*8+3] = 1
        execute("rgb-seam-whole", mask=bytes(single))

        # Preserve exact maxval delimiter handling when the first pixel is whitespace.
        whitespace = path / "whitespace.ppm"
        whitespace.write_bytes(b"P6\r\n1 1\r\n255\r\n" + bytes([10, 32, 13]))
        originals[whitespace] = whitespace.read_bytes()
        run = subprocess.run([str(exe), "--histogram", str(whitespace), "0", "0", "1", "1"],
                             check=True, capture_output=True, text=True, timeout=15)
        check(json.loads(run.stdout), reference(bytes([10, 32, 13]), 1, (0, 0, 1, 1), None))
        cases += 1

        whole = files["rgb-seam-whole"]
        for roi in ((0, 0, 0, 1), (8, 0, 1, 1), (-1, 0, 1, 1),
                    (0, 0, "bad", 1), (0, 0, 8, 5)):
            reject([whole, *roi])
        for length in (0, 31, 33):
            bad_mask = path / "bad-mask.raw"
            bad_mask.write_bytes(bytes(length))
            reject([whole, 0, 0, 8, 4, bad_mask])
        bad_image = path / "bad.ppm"
        for payload in (b"P6\n8 4\n255\n", b"P6\n1 1\n65535\n" + bytes(6)):
            bad_image.write_bytes(payload)
            reject([bad_image, 0, 0, 1, 1])
        reject([whole, 0, 0])
        for source, original in originals.items():
            assert source.read_bytes() == original, "input P6 unchanged"
    print(f"M4_RGB_HISTOGRAM_CORPUS=PASS; {cases} exact-byte oracle cases, "
          f"{negatives} rejected requests, ROI/mask/tile laws; network=0")


if __name__ == "__main__":
    main()
