#!/usr/bin/env python3
"""Check luminance stretch on every pinned M4 real-image source.

The optional offline test decodes each JPEG with Pillow, then supplies the
same decoded RGB bytes to the D consumer and independent scalar sRGB/XYZ-D65
oracle used by the synthetic M4 gate.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests/corpus/m4-real-v1.json"
IMAGE_DIR = ROOT / "data/m4"
spec = importlib.util.spec_from_file_location(
    "m4_luminance", ROOT / "tests/corpus/verify_m4_luminance_stretch.py")
luminance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(luminance)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_m4_real_luminance.py PPM_EXECUTABLE TMPDIR")
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
    maximum_byte_error = 0
    with tempfile.TemporaryDirectory(prefix="m4-real-luminance-",
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
            for workers in (0, 4):
                result = luminance.run(exe, directory,
                    f"{record['id']}-w{workers}", raw, width, height,
                    1, 99, workers=workers)
                maximum_byte_error = max(maximum_byte_error, result[3])
                cases += 1
            mask = bytes(0 if (x // 64 + y // 64) % 4 == 0 else 255
                         for y in range(height) for x in range(width))
            result = luminance.run(exe, directory,
                f"{record['id']}-masked-w4", raw, width, height,
                1, 99, mask=mask, workers=4)
            maximum_byte_error = max(maximum_byte_error, result[3])
            cases += 1
            if hashlib.sha256(image_path.read_bytes()).hexdigest() != record["sha256"]:
                raise AssertionError("consumer modified pinned source")
    print(f"M4_REAL_RGB_LUMINANCE=PASS; sources:{len(sources)},cases:{cases},"
          f"max_byte_error:{maximum_byte_error},"
          f"jpeg_decoder:Pillow-{Image.__version__}/{features.version('jpg')},"
          "network:0")


if __name__ == "__main__":
    main()
