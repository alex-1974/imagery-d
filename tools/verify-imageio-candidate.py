"""Qualify an explicit imageio checkout without modifying global DUB registrations.

Usage: python tools/verify-imageio-candidate.py /path/to/imageio-checkout --compiler=ldc-1.43.0
Uses the same consumer/oracle, additionally requiring a successful RGB GeoTIFF handoff.
"""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('imageio')
parser.add_argument('--compiler', default='ldc-1.43.0')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
candidate = Path(args.imageio).resolve()
assert (candidate/'source/imageio/tiff.d').is_file()
with tempfile.TemporaryDirectory(prefix='imagery-imageio-candidate-') as directory:
    root = Path(directory)
    shutil.copytree(repo/'tests/materialization/source', root/'source')
    # A direct path dependency overrides the transitive version in this isolated
    # project only. Existing package registrations and both worktrees stay intact.
    (root/'dub.sdl').write_text(
        'name "materialization-fixed"\ntargetType "executable"\n'
        f'dependency "imagery-d" path={json.dumps(str(repo))}\n'
        f'dependency "imageio-d" path={json.dumps(str(candidate))}\n')
    subprocess.check_call(['dub', 'build', f'--root={root}', f'--compiler={args.compiler}', '--build=release'])
    subprocess.check_call([sys.executable, str(repo/'tools/verify-materialization.py'),
                           str(root/'materialization-fixed'), '--rgb-decoder-fixed'])
