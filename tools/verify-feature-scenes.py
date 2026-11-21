"""Replay shared imagery requests on located Dunia research scenes.

This checks real pixel processing and sharing. It does not create human labels
or claim application classification acceptance.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from PIL import Image

consumer = str(Path(sys.argv[1]).resolve())
base = Path(sys.argv[2])
for name in ["marchfeld", "wienerwald", "semmering"]:
    path = base / name / "esri.png"
    image = Image.open(path).convert("RGB")
    # Retain a real, unscaled source region. Output never enters the repository.
    x, y = max(0, image.width//2-128), max(0, image.height//2-128)
    crop = image.crop((x, y, min(x+256, image.width), min(y+256, image.height)))
    with tempfile.TemporaryDirectory(prefix="imagery-scene-") as directory:
        raw = Path(directory) / "input.rgb"
        raw.write_bytes(crop.tobytes())
        result = json.loads(subprocess.check_output([consumer, "--rgb", str(raw), str(crop.width), str(crop.height)], text=True))
    result.update(scene=name, source=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), crop=[x,y,crop.width,crop.height])
    print(json.dumps(result, sort_keys=True))
