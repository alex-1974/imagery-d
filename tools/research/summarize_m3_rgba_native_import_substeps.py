#!/usr/bin/env python3
"""Research-only replay of M3 native import substep traces (Issue #74).

No guessed RasterBacking type sizes. This validates pointer ownership, tagged
pixel lifetime, stage order and requested bytes only. Read this together with
the pinned raster-d v0.2.0 source, not as an all-in memory bound.
"""
import collections
import csv
import pathlib
import sys

STAGES = 13
TAG_ALLOCATION_PHASE = {1: 2, 2: 6}
TAG_RELEASE_PHASE = {1: 10, 2: 12}
CASES = {"raw", "adopt", "import"}


def replay(rows, case, side):
    if case not in CASES or side not in (16, 256):
        raise ValueError("unsupported case or ROI")
    expected_bytes = 4 * side * side
    stage = 0
    closed = 0
    pending = None
    live = {}  # pointer -> (requested bytes, kind, birth stage)
    history = []  # (birth, death, bytes, kind); None death means alive
    counts = {i: collections.Counter() for i in range(1, STAGES + 1)}
    tags_seen = collections.Counter()
    tags_freed = collections.Counter()
    for line_no, row in enumerate(rows, 1):
        if len(row) != 5:
            raise ValueError("bad field count at line %d" % line_no)
        action, phase_text, pointer, size_text, kind_text = row
        try:
            p, n, k = int(phase_text), int(size_text), int(kind_text)
            address = int(pointer, 16)
        except ValueError as e:
            raise ValueError("malformed event at line %d" % line_no) from e
        if p < 1 or p > STAGES or n < 0 or k < 0:
            raise ValueError("invalid fields at line %d" % line_no)
        if action == "S":
            if stage or p != closed + 1 or address or n or k:
                raise ValueError("misordered start marker at line %d" % line_no)
            stage = p
            continue
        if action == "E":
            if pending is not None or p != stage or address or n != p or k:
                raise ValueError("misordered end marker at line %d" % line_no)
            closed = stage
            stage = 0
            continue
        if p != stage or not stage:
            raise ValueError("event outside stage at line %d" % line_no)
        counter = counts[p]
        if action == "I":
            if pending is not None or address or k not in (1, 2):
                raise ValueError("bad intent at line %d" % line_no)
            if p != TAG_ALLOCATION_PHASE[k] or n != expected_bytes:
                raise ValueError("wrong tagged pixel intent")
            pending = (k, n)
            continue
        if action == "A":
            if not address or address in live or k not in (0, 1, 2):
                raise ValueError("duplicate or null allocation at line %d" % line_no)
            if pending is not None:
                if (k, n) != pending:
                    raise ValueError("intent not followed by matching allocation")
                pending = None
            elif k:
                raise ValueError("allocation tag without intent")
            if k:
                if p != TAG_ALLOCATION_PHASE[k] or n != expected_bytes:
                    raise ValueError("tagged allocation in wrong stage/size")
                tags_seen[k] += 1
            live[address] = (n, k, p)
            counter["alloc_calls"] += 1
            counter["alloc_bytes"] += n
            counter["tagged_calls" if k else "other_calls"] += 1
            counter["tagged_bytes" if k else "other_bytes"] += n
            continue
        if action == "F":
            if not address or n or k or pending is not None:
                raise ValueError("malformed free or dangling intent")
            if address not in live:
                # The recorder starts after fixture/runtime warmup: pretrace
                # frees are visible but cannot be assigned to this study.
                counter["pretrace_free"] += 1
                continue
            size, kind, born = live.pop(address)
            history.append((born, p, size, kind))
            counter["free_calls"] += 1
            if kind:
                if p != TAG_RELEASE_PHASE[k]:
                    raise ValueError("tagged pixel released in wrong stage")
                tags_freed[k] += 1
            continue
        raise ValueError("unknown action at line %d" % line_no)
    if stage or pending is not None or closed != STAGES:
        raise ValueError("incomplete stage sequence")
    if tags_seen != collections.Counter({1: 1, 2: 1}):
        raise ValueError("expected exactly two marked allocations")
    if tags_freed != collections.Counter({1: 1, 2: 1}):
        raise ValueError("expected final marked frees")
    if any(kind for _, kind, _ in live.values()):
        raise ValueError("tagged payload escaped the trace")
    for size, kind, born in live.values():
        history.append((born, None, size, kind))
    return counts, history


def summarize(trace, case, side, destination):
    with open(trace, newline="", encoding="utf-8") as stream:
        counts, history = replay(csv.reader(stream), case, side)
    with open(destination, "w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(("case", "side", "stage", "other_calls", "other_bytes",
                         "tagged_calls", "tagged_bytes", "free_calls",
                         "pretrace_free", "other_live_end_bytes"))
        for stage in range(1, STAGES + 1):
            c = counts[stage]
            outstanding = sum(n for start, end, n, k in history
                              if not k and start <= stage and
                              (end is None or stage < end))
            writer.writerow((case, side, stage, c["other_calls"],
                             c["other_bytes"], c["tagged_calls"],
                             c["tagged_bytes"], c["free_calls"],
                             c["pretrace_free"], outstanding))
    print("M3 NATIVE IMPORT SUBSTEPS TRACE PASS: case=%s side=%d" %
          (case, side))


def synthetic():
    out = []
    for stage in range(1, STAGES + 1):
        out.append(("S", str(stage), "0x0", "0", "0"))
        if stage == 2:
            out += [("I", "2", "0x0", "1024", "1"),
                    ("A", "2", "0x1", "1024", "1")]
        if stage == 6:
            out += [("I", "6", "0x0", "1024", "2"),
                    ("A", "6", "0x2", "1024", "2")]
        if stage == 10:
            out.append(("F", "10", "0x1", "0", "0"))
        if stage == 12:
            out.append(("F", "12", "0x2", "0", "0"))
        out.append(("E", str(stage), "0x0", str(stage), "0"))
    return out


def self_test():
    valid = synthetic()
    replay(valid, "raw", 16)
    # Add a native allocation that survives import and is freed with
    # the last packed owner, without pretending to know its D type.
    extra = list(valid)
    extra.insert(extra.index(("E", "8", "0x0", "8", "0")),
                 ("A", "8", "0x3", "40", "0"))
    extra.insert(extra.index(("E", "12", "0x0", "12", "0")),
                 ("F", "12", "0x3", "0", "0"))
    _, history = replay(extra, "import", 16)
    assert (8, 12, 40, 0) in history
    negatives = []
    x = list(valid)
    x.pop()
    negatives.append(x)
    x = list(valid)
    x[x.index(("F", "10", "0x1", "0", "0"))] = ("F", "9", "0x1", "0", "0")
    negatives.append(x)
    x = list(valid)
    x.insert(x.index(("E", "2", "0x0", "2", "0")),
             ("A", "2", "0x1", "7", "0"))
    negatives.append(x)
    x = list(valid)
    x.remove(("A", "6", "0x2", "1024", "2"))
    negatives.append(x)
    for broken in negatives:
        try:
            replay(broken, "raw", 16)
        except ValueError:
            pass
        else:
            raise AssertionError("negative fixture accepted")
    print("NATIVE IMPORT SUBSTEPS SELF-TEST PASS")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 5:
        summarize(pathlib.Path(sys.argv[1]), sys.argv[2],
                  int(sys.argv[3]), pathlib.Path(sys.argv[4]))
    else:
        raise SystemExit("usage: summarize_m3_rgba_native_import_substeps.py "
                         "--self-test | EVENTS CASE SIDE STAGES_CSV")
