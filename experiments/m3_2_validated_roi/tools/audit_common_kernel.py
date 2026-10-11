#!/usr/bin/env python3
"""Fail the M3.2.10 hosted codegen gate if mapping paths differ in kernel.

Read only the objdump -d -C output from the *timed* executable.
Require exactly one shared noninline kernel symbol with calls from the
one-shot and prepared semantic paths (including wrappers where inlined).
This is a control-plane codegen audit, not a bytewise proof of all inputs.
"""
import argparse
import gzip
import re
from pathlib import Path

TARGET = "researchExecuteCheckedPixels"
HEAD = re.compile(r"^[0-9a-fA-F]+ <(.+)>:$")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("disassembly", type=Path)
    args = p.parse_args()
    if args.disassembly.suffix == ".gz":
        with gzip.open(args.disassembly, "rt", errors="replace") as stream:
            lines = stream.readlines()
    else:
        lines = args.disassembly.read_text(errors="replace").splitlines()

    functions = {}
    active = None
    for line in lines:
        head = HEAD.match(line.strip())
        if head:
            active = head.group(1)
            functions.setdefault(active, [])
        elif active is not None:
            functions[active].append(line)

    defs = [name for name in functions if TARGET in name]
    if len(defs) != 1:
        raise SystemExit(
            f"FAIL: expected one shared execution body, found {len(defs)}: {defs}"
        )

    callers = []
    for name, body in functions.items():
        if name in defs:
            continue
        callsites = [line for line in body
                     if re.search(r"\bcall(q)?\b", line)
                     and TARGET in line]
        if callsites:
            callers.append((name, len(callsites)))

    original = [name for name, _ in callers
                if "mapComponentsInto" in name]
    prepared = [name for name, _ in callers
                if "PreparedSemanticMap" in name
                or "mapPrepared" in name]
    print("shared_kernel_definition:", defs[0])
    print("callers:")
    for name, count in callers:
        print(f"  {count} call(s) from {name}")

    if not original or not prepared:
        raise SystemExit(
            "FAIL: both one-shot mapComponentsInto and prepared map "
            "must call the same noninline checked kernel symbol. "
            "Review compiler inlining and the actual executable."
        )
    print("PASS: single common codegen kernel used by both mapped paths")


if __name__ == "__main__":
    main()
