#!/usr/bin/env python3
"""Verify the P6 luminance consumer against independent sRGB/XYZ equations."""
from __future__ import annotations

import importlib.util
import json
import math
import pathlib
import struct
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "m4_corpus", ROOT / "tools/verify-m4-corpus.py")
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)

HEADER = b"P6\n"


def linear(v: int) -> float:
    encoded = v / 255.0
    return encoded / 12.92 if encoded <= 0.04045 else ((encoded + 0.055) / 1.055) ** 2.4


def luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = map(linear, rgb)
    # Independent scalar form of the standard linear-sRGB -> XYZ D65 Y row.
    return (87098 / 409605) * r + (175762 / 245763) * g + (12673 / 175545) * b


def encoded(linear_value: float) -> float:
    return 12.92 * linear_value if linear_value <= 0.0031308 else (
        1.055 * linear_value ** (1 / 2.4) - 0.055)


def f32(value: float) -> float:
    return struct.unpack("=f", struct.pack("=f", value))[0]


def byte(value: float) -> int:
    # Mirrors only the consumer's explicit float-to-P6 serialization step.
    return min(255, max(0, math.floor(f32(value) * 255.0 + 0.5)))


def reference(raw: bytes, lower: int, upper: int,
              mask: bytes | None = None) -> bytes:
    count = len(raw) // 3
    ys = [luminance(tuple(raw[i:i + 3])) for i in range(0, len(raw), 3)]
    bins = [min(65535, max(0, math.floor(y * 65536))) for y in ys]
    included = [i for i in range(count) if mask is None or mask[i] != 0]
    assert included
    histogram = [0] * 65536
    for i in included:
        histogram[bins[i]] += 1

    def selected_bin(percentile: int) -> int:
        rank = 1 if percentile == 0 else (len(included) * percentile + 99) // 100
        cumulative = 0
        for index, frequency in enumerate(histogram):
            cumulative += frequency
            if cumulative >= rank:
                return index
        raise AssertionError("rank exceeds histogram")

    lo, hi = selected_bin(lower), selected_bin(upper)
    out = bytearray(len(raw))
    for pixel, y in enumerate(ys):
        if hi == lo:
            mapped = y
        elif bins[pixel] <= lo:
            mapped = 0.0
        elif bins[pixel] >= hi:
            mapped = 1.0
        else:
            mapped = (bins[pixel] - lo) / (hi - lo)
        scale = mapped / y if y > 0 else 0.0
        for channel in range(3):
            value = min(1.0, max(0.0, linear(raw[3 * pixel + channel]) * scale))
            out[3 * pixel + channel] = byte(encoded(value))
    return bytes(out)


def run(exe: pathlib.Path, folder: pathlib.Path, label: str, raw: bytes,
        width: int, height: int, lower: int, upper: int,
        mask: bytes | None = None) -> tuple[bytes, pathlib.Path, bytes]:
    source = folder / f"{label}.ppm"
    output = folder / f"{label}-out.ppm"
    header = HEADER + f"{width} {height}\n255\n".encode()
    original = header + raw
    source.write_bytes(original)
    args = [str(exe), "--luminance-stretch", str(source), str(output),
            str(lower), str(upper)]
    mask_path = None
    if mask is not None:
        mask_path = folder / f"{label}.mask"
        mask_path.write_bytes(mask)
        args.append(str(mask_path))
    completed = subprocess.run(args, capture_output=True, text=True, timeout=20)
    assert completed.returncode == 0, (label, completed.stderr)
    actual = output.read_bytes()
    assert actual.startswith(header), (label, "output header/shape")
    payload = actual[len(header):]
    expected = reference(raw, lower, upper, mask)
    assert len(payload) == len(expected)
    error = max((abs(a - b) for a, b in zip(payload, expected)), default=0)
    assert error <= 1, (label, "independent byte oracle", error)
    assert source.read_bytes() == original, (label, "input modified")
    if mask_path is not None:
        assert mask_path.read_bytes() == mask, (label, "mask modified")
    return payload, output, header


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_luminance_stretch.py PPM_EXECUTABLE TMPDIR")
    exe = pathlib.Path(sys.argv[1]).resolve()
    manifest = json.loads((ROOT / "tests/corpus/m4-v1.json").read_text("utf-8"))
    pixels = corpus.verify_manifest(manifest)
    entries = {entry["id"]: entry for entry in manifest["fixtures"]}
    cases = 0
    negatives = 0
    with tempfile.TemporaryDirectory(prefix="m4-luminance-", dir=sys.argv[2]) as name:
        folder = pathlib.Path(name)
        for label in ("rgb-roi", "rgb-seam-whole", "rgb-seam-left", "rgb-seam-right"):
            entry, raw = entries[label], pixels[label]
            assert entry["dtype"] == "u8" and entry["channels"] == 3
            for lower, upper in ((0, 100), (1, 99)):
                run(exe, folder, f"{label}-{lower}-{upper}", raw,
                    entry["width"], entry["height"], lower, upper)
                cases += 1

        whole = entries["rgb-seam-whole"]
        mask = pixels["mask-selection"]
        assert len(mask) == whole["width"] * whole["height"]
        run(exe, folder, "masked-seam", pixels["rgb-seam-whole"],
            whole["width"], whole["height"], 0, 100, mask)
        cases += 1

        neutral = bytes(channel for value in (16, 64, 128, 240)
                        for channel in (value, value, value))
        run(exe, folder, "neutral", neutral, 4, 1, 0, 100)
        cases += 1
        constant = bytes((42, 42, 42) * 4)
        actual, _, _ = run(exe, folder, "constant", constant, 4, 1, 0, 100)
        assert actual == constant, "single-bin luminance must be identity"
        cases += 1

        invalid_source = folder / "neutral.ppm"
        invalid_output = folder / "invalid.ppm"
        for lower, upper in ((50, 50), (100, 0), (0, 101)):
            result = subprocess.run([str(exe), "--luminance-stretch",
                str(invalid_source), str(invalid_output), str(lower), str(upper)],
                capture_output=True, text=True, timeout=20)
            assert result.returncode != 0 and not invalid_output.exists()
            negatives += 1
        empty_mask = folder / "empty.mask"
        empty_mask.write_bytes(bytes(4))
        result = subprocess.run([str(exe), "--luminance-stretch",
            str(invalid_source), str(invalid_output), "0", "100", str(empty_mask)],
            capture_output=True, text=True, timeout=20)
        assert result.returncode != 0 and not invalid_output.exists()
        negatives += 1

    print(f"M4_RGB_LUMINANCE_STRETCH=PASS; {cases} independent XYZ-D65-Y oracle cases, "
          f"{negatives} rejected requests, masks and constant-bin identity; network=0")


if __name__ == "__main__":
    main()
