#!/usr/bin/env python3
"""Check the P6 RGB equalization consumer against SHA-pinned M4 bytes."""
from __future__ import annotations

from collections import Counter
from fractions import Fraction
import importlib.util
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


def expected_equalization(raw: bytes) -> bytes:
    tables = []
    for channel in range(3):
        frequencies = Counter(raw[channel::3])
        count = sum(frequencies.values())
        assert count > 0
        first = frequencies[min(frequencies)]
        if first == count:
            tables.append(bytes(range(256)))
            continue
        cumulative = 0
        table = bytearray(256)
        for value in range(256):
            cumulative += frequencies[value]
            if cumulative > first:
                table[value] = int(Fraction(255 * (cumulative - first),
                                            count - first) + Fraction(1, 2))
        tables.append(bytes(table))
    return bytes(tables[i % 3][value] for i, value in enumerate(raw))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_equalize.py PPM_EXECUTABLE TMPDIR")
    executable = pathlib.Path(sys.argv[1]).resolve()
    manifest = json.loads((ROOT / "tests/corpus/m4-v1.json").read_text("utf-8"))
    pixels = corpus.verify_manifest(manifest)
    by_id = {entry["id"]: entry for entry in manifest["fixtures"]}
    labels = ("rgb-roi", "rgb-seam-whole", "rgb-seam-left", "rgb-seam-right")
    with tempfile.TemporaryDirectory(prefix="m4-equalize-", dir=sys.argv[2]) as name:
        directory = pathlib.Path(name)
        for label in labels:
            meta, raw = by_id[label], pixels[label]
            assert meta["dtype"] == "u8" and meta["channels"] == 3
            header = f'P6\n{meta["width"]} {meta["height"]}\n255\n'.encode()
            source = directory / f"{label}.ppm"
            output = directory / f"{label}-equalized.ppm"
            original = header + raw
            source.write_bytes(original)
            completed = subprocess.run(
                [str(executable), "--equalize", str(source), str(output)],
                capture_output=True, text=True, timeout=15)
            assert completed.returncode == 0, (label, completed.stderr)
            assert output.read_bytes() == header + expected_equalization(raw), label
            assert source.read_bytes() == original, f"{label}: input changed"

        # A flat R channel remains byte-identical; other channels still map.
        raw = bytes([42, 0, 255, 42, 128, 0, 42, 255, 128])
        header = b"P6\n3 1\n255\n"
        source = directory / "constant.ppm"
        output = directory / "constant-out.ppm"
        source.write_bytes(header + raw)
        completed = subprocess.run(
            [str(executable), "--equalize", str(source), str(output)],
            capture_output=True, text=True, timeout=15)
        assert completed.returncode == 0, completed.stderr
        assert output.read_bytes() == header + expected_equalization(raw)
        assert output.read_bytes()[len(header)::3] == bytes([42, 42, 42])

        # Existing destinations and malformed invocation publish no new data.
        before = output.read_bytes()
        rejected = subprocess.run(
            [str(executable), "--equalize", str(source), str(output)],
            capture_output=True, text=True, timeout=15)
        assert rejected.returncode != 0 and output.read_bytes() == before
        missing = directory / "missing-out.ppm"
        rejected = subprocess.run(
            [str(executable), "--equalize", str(source), str(missing), "extra"],
            capture_output=True, text=True, timeout=15)
        assert rejected.returncode != 0 and not missing.exists()
    print("M4_RGB_EQUALIZE_P6=PASS; 4 hashed fixtures, independent rational "
          "CDF oracle, constant channel and output preservation; network=0")


if __name__ == "__main__":
    main()
