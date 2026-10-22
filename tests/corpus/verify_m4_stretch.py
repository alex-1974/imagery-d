#!/usr/bin/env python3
"""Verify the real P6 contrast-LUT consumer on SHA-pinned M4 RGB bytes."""
from __future__ import annotations

import importlib.util
from fractions import Fraction
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "m4_corpus", ROOT / "tools/verify-m4-corpus.py")
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


def expected_stretch(raw: bytes, lower: int, upper: int) -> bytes:
    channels = [sorted(raw[c::3]) for c in range(3)]
    count = len(channels[0])
    assert count > 0

    def rank(p: int) -> int:
        return 0 if p == 0 else (p * count + 99) // 100 - 1

    bounds = [(values[rank(lower)], values[rank(upper)])
              for values in channels]
    result = bytearray(len(raw))
    for i, value in enumerate(raw):
        lo, hi = bounds[i % 3]
        if lo == hi:
            mapped = value
        elif value <= lo:
            mapped = 0
        elif value >= hi:
            mapped = 255
        else:
            mapped = int(Fraction((value - lo) * 255, hi - lo) +
                         Fraction(1, 2))
        result[i] = mapped
    return bytes(result)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_stretch.py PPM_EXECUTABLE TMPDIR")
    executable = pathlib.Path(sys.argv[1]).resolve()
    manifest = json.loads((ROOT / "tests/corpus/m4-v1.json").read_text("utf-8"))
    pixels = corpus.verify_manifest(manifest)
    by_id = {entry["id"]: entry for entry in manifest["fixtures"]}
    labels = ("rgb-roi", "rgb-seam-whole", "rgb-seam-left", "rgb-seam-right")
    with tempfile.TemporaryDirectory(prefix="m4-stretch-", dir=sys.argv[2]) as name:
        directory = pathlib.Path(name)
        for label in labels:
            meta, raw = by_id[label], pixels[label]
            assert meta["dtype"] == "u8" and meta["channels"] == 3
            header = f'P6\n{meta["width"]} {meta["height"]}\n255\n'.encode()
            source, output = directory / f"{label}.ppm", directory / f"{label}-out.ppm"
            original = header + raw
            source.write_bytes(original)
            completed = subprocess.run(
                [str(executable), "--stretch", str(source), str(output), "1", "99"],
                capture_output=True, text=True, timeout=15)
            assert completed.returncode == 0, (label, completed.stderr)
            assert output.read_bytes() == header + expected_stretch(raw, 1, 99), label
            assert source.read_bytes() == original, f"{label}: input changed"

        # A constant channel has coincident percentile bounds and stays unchanged.
        constant = bytes([42, 10, 200, 42, 200, 10])
        source = directory / "constant.ppm"
        source.write_bytes(b"P6\n2 1\n255\n" + constant)
        output = directory / "constant-out.ppm"
        completed = subprocess.run(
            [str(executable), "--stretch", str(source), str(output), "0", "100"],
            capture_output=True, text=True, timeout=15)
        assert completed.returncode == 0, completed.stderr
        assert output.read_bytes() == b"P6\n2 1\n255\n" + expected_stretch(constant, 0, 100)
        assert output.read_bytes()[len(b"P6\n2 1\n255\n")::3] == bytes([42, 42])

        for lower, upper in ((50, 50), (100, 0), (0, 101), ("bad", 99)):
            rejected = directory / f"reject-{lower}-{upper}.ppm"
            completed = subprocess.run(
                [str(executable), "--stretch", str(source), str(rejected),
                 str(lower), str(upper)], capture_output=True, text=True, timeout=15)
            assert completed.returncode != 0 and not rejected.exists(), (
                lower, upper, "invalid request published output")
    print("M4_RGB_STRETCH_P6=PASS; 4 hashed fixtures, independent byte oracle, "
          "constant channel and invalid requests; network=0")


if __name__ == "__main__":
    main()
