#!/usr/bin/env python3
"""Compile and run the complete programs actually printed in Markdown."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULTS = ("README.md", "docs/tutorial/levels.md", "docs/how-to/features.md")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("documents", nargs="*", default=list(DEFAULTS))
parser.add_argument("--compiler", default=os.environ.get("DC", "dmd"))
args = parser.parse_args()
programs = []
for document in args.documents:
    text = (ROOT / document).read_text()
    blocks = re.findall(r"^```d[ \t]*\n(.*?)^```[ \t]*$", text, re.MULTILINE | re.DOTALL)
    if not blocks:
        raise ValueError("no D example found in " + document)
    for index, code in enumerate(blocks, 1):
        if not re.search(r"\b(?:void|int)\s+main\s*\(", code):
            raise ValueError(f"{document} block {index} must be a complete program")
        programs.append((document, index, code))

for number, (document, index, code) in enumerate(programs, 1):
    with tempfile.TemporaryDirectory(prefix="imagery-doc-example-") as directory:
        project = Path(directory)
        (project / "source").mkdir()
        (project / "source/app.d").write_text(code)
        (project / "dub.json").write_text(json.dumps({
            "name": f"imagery-doc-example-{number}", "targetType": "executable",
            "dependencies": {"imagery-d": {"path": str(ROOT)}},
            "subConfigurations": {"imagery-d": "no-io"},
        }))
        print(f"Checking {document} block {index} with {args.compiler}", flush=True)
        # Debug mode keeps README assertions active; no copied fixture can
        # pass while the displayed Markdown example has drifted.
        subprocess.run(["dub", "run", "--root=" + str(project),
                        "--compiler=" + args.compiler, "--build=debug", "--force"], check=True)
print(f"DOC_EXAMPLES=PASS; programs={len(programs)} compiler={args.compiler}")
