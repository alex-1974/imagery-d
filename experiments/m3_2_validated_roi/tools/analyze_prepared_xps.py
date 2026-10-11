#!/usr/bin/env python3
"""M3.2.9 three-way paired mapped-ROI benchmark analyzer (stdlib only)."""
import argparse
import csv
import json
import statistics
from collections import defaultdict
from pathlib import Path

MODES = ("revalidated_image", "verified_immutable_image", "prepared_semantic_map")


def median(xs):
    return statistics.median(xs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("directory", type=Path)
    options = ap.parse_args()
    pairs = defaultdict(dict)
    setup = defaultdict(list)
    raw = []
    runs = sorted(options.directory.glob("run-*.log"))
    if not runs:
        raise ValueError("No run-N.log files")

    for file in runs:
        run = int(file.stem.split("-")[1])
        for cells in csv.reader(file.read_text(encoding="utf-8").splitlines()):
            if not cells:
                continue
            if cells[0] == "prepared_map":
                if len(cells) != 11:
                    raise ValueError(f"Invalid prepared_map schema: {cells}")
                _, n, side, layout, mask, round_, slot, mode, loops, elapsed, checksum = cells
                n, side, round_, slot, loops, elapsed = map(
                    int, (n, side, round_, slot, loops, elapsed))
                checksum = float(checksum)
                if (layout not in ("planar", "interleaved")
                        or mask not in ("masked", "unmasked")
                        or mode not in MODES or loops <= 0 or elapsed <= 0
                        or slot not in (0, 1, 2)
                        or not (checksum == checksum)):
                    raise ValueError(f"Invalid value: {cells}")
                key = (run, n, side, layout, mask, round_)
                if mode in pairs[key]:
                    raise ValueError(f"Duplicate mode {key}/{mode}")
                pairs[key][mode] = (loops, elapsed, checksum, slot)
                raw.append({
                    "run": run, "channels": n, "side": side,
                    "layout": layout, "mask": mask, "round": round_,
                    "slot": slot, "mode": mode, "iterations": loops,
                    "elapsed_ns": elapsed, "checksum": checksum,
                })
            elif cells[0] == "consumer_setup":
                if len(cells) != 6:
                    raise ValueError(f"Invalid setup row {cells}")
                _, n, name, loops, elapsed, checksum = cells
                n, loops, elapsed, checksum = map(
                    int, (n, loops, elapsed, checksum))
                if loops <= 0 or elapsed <= 0 or checksum <= 0:
                    raise ValueError(f"Invalid setup data {cells}")
                setup[(n, name)].append(elapsed / loops)

    if not pairs:
        raise ValueError("No paired samples")

    caseRows = defaultdict(list)
    for key, modes in pairs.items():
        if set(modes) != set(MODES):
            raise ValueError(f"Incomplete triple {key}")
        vals = list(modes.values())
        if len({v[0] for v in vals}) != 1:
            raise ValueError(f"Different iterations in triple {key}")
        if len({v[2] for v in vals}) != 1:
            raise ValueError(f"Output checksums differ in triple {key}")
        if sorted(v[3] for v in vals) != [0, 1, 2]:
            raise ValueError(f"Duplicated position in triple {key}")
        _, n, side, layout, mask, _ = key
        per = {mode: modes[mode][1] / modes[mode][0] for mode in MODES}
        caseRows[(n, side, layout, mask)].append(per)

    summary = []
    for (n, side, layout, mask), samples in sorted(caseRows.items()):
        item = {"channels": n, "side": side, "layout": layout,
                "mask": mask, "triples": len(samples)}
        for name in MODES:
            vals = [s[name] for s in samples]
            med = median(vals)
            item[name + "_median_ns_per_map"] = round(med, 3)
            item[name + "_mad_ns_per_map"] = round(
                median([abs(x - med) for x in vals]), 3)
        for baseline in MODES[:2]:
            ratios = [
                s[baseline] / s["prepared_semantic_map"] for s in samples
            ]
            item[baseline + "_to_prepared_paired_median"] = round(
                median(ratios), 4)
        summary.append(item)

    output = options.directory
    with (output / "prepared-summary.csv").open(
            "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0]))
        w.writeheader()
        w.writerows(summary)
    with (output / "prepared-raw.csv").open(
            "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(raw[0]))
        w.writeheader()
        w.writerows(raw)
    prepSummary = []
    for (n, name), vals in sorted(setup.items()):
        prepSummary.append({"channels": n, "mode": name, "samples": len(vals),
                            "median_ns": round(median(vals), 3)})
    if prepSummary:
        with (output / "prepared-setup.csv").open(
                "w", encoding="utf-8", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(prepSummary[0]))
            w.writeheader()
            w.writerows(prepSummary)
    (output / "prepared-summary.json").write_text(
        json.dumps({
            "schema": "imagery-d-m3.2.9-prepared-consumer-v1",
            "disclaimer": "Synthetic image-domain ROI mapping only; "
                          "hosted CI timing is smoke, not speed evidence.",
            "processes": len(runs), "paired_triples": len(pairs),
            "cases": summary, "metadata_setup": prepSummary
        }, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Validated {len(runs)} processes and {len(pairs)} complete matched triples")
    for d in summary:
        print(d["channels"], d["side"], d["layout"], d["mask"],
              "old:", d["revalidated_image_median_ns_per_map"],
              "verified:", d["verified_immutable_image_median_ns_per_map"],
              "prepared:", d["prepared_semantic_map_median_ns_per_map"])


if __name__ == "__main__":
    main()
