#!/usr/bin/env python3
"""Inspect exact measured ELF without execution. Advisory codegen evidence only.

Report retained accessor call sites in full private and extracted functions.
The count is STATIC call sites in their complete bodies, not dynamic calls,
nor a numerical predictor of pixel latency. LTO can legitimately inline or
eliminate an entire function; empty 'matches' must not be called zero calls.
"""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def inspect(path):
    path = Path(path)
    raw = path.read_bytes()
    output = subprocess.check_output(
        ["objdump", "-Cd", "--no-show-raw-insn", str(path)],
        text=True, errors="replace")
    headers = list(re.finditer(
        r"^([0-9a-fA-F]{8,16}) <(.+)>:\s*$", output, re.MULTILINE))
    targets = {
        "private": "app.tryCompositeOwnedPackedResearch(",
        "library": "imagery.presentation.owned.tryCompositeOwnedRgbaResearch(",
    }
    data = {"binary_sha256": hashlib.sha256(raw).hexdigest(),
            "binary_bytes": len(raw), "functions": {}}
    for role, expected in targets.items():
        matches = []
        for i, header in enumerate(headers):
            if not header.group(2).startswith(expected):
                continue
            end = headers[i+1].start() if i + 1 < len(headers) else len(output)
            body = output[header.end():end]
            calls = [line.strip() for line in body.splitlines()
                     if re.search(r"\bcallq?\b", line)]
            matches.append({"address": header.group(1),
                            "symbol": header.group(2),
                            "call_instructions": len(calls),
                            "trySample_calls":
                                sum("trySample(" in c for c in calls),
                            "trySetSample_calls":
                                sum("trySetSample(" in c for c in calls)})
        data["functions"][role] = matches
    return data


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: inspect_m3_owned_lto_codegen.py measured_elf")
    print(json.dumps(inspect(sys.argv[1]), indent=2, sort_keys=True))
