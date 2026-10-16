#!/usr/bin/env python3
"""Validate fused/extracted/direct-4N full-owned RGBA XPS timings.
Recalculate independently with original ELF manifest and rotated pairing.
"""
import csv
import hashlib
import io
import json
import statistics
import sys
import tempfile
from pathlib import Path

HEADER = (
    "meaning", "pattern", "layout", "roi", "width", "height",
    "pixels", "round", "iterations", "stage", "elapsed_ns",
    "thread_gc_bytes", "canonical_checksum",
)
STAGES = ("owned_fused_checked", "owned_extracted_library", "owned_direct_packed")
MANIFEST_EXTRAS = frozenset((
    "environment.txt", "build.log", "m3-direct-owned-consumer"))
SUMMARY = (
    "meaning", "pattern", "layout", "roi", "pixels", "rounds",
    "iterations", "fused_ns_px", "extracted_ns_px", "direct_ns_px",
    "paired_extracted_over_fused", "paired_direct_over_fused",
    "paired_direct_over_extracted", "paired_extracted_minus_fused_ns_px",
    "paired_direct_minus_fused_ns_px", "direct_fused_ratio_min",
    "direct_fused_ratio_max", "gc_fused", "gc_extracted", "gc_direct",
    "canonical_checksum",
)


def require(ok, explanation):
    if not ok:
        raise ValueError(explanation)


def format_case(width, meaning, pattern, layout, side):
    return f"{width}x{width}-{meaning}-{pattern}-{layout}-square{side}.csv"


def analyze(directory):
    env = {}
    for line in (directory / "environment.txt").read_text(
            encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    mode = env.get("mode")
    require(mode in ("smoke", "micro"), "unexpected XPS mode")
    require(env.get("source_mode") == "pinned-v0.2.0",
            "unpinned dependency source")
    require(env.get("benchmark_protocol") == "direct-4N",
            "missing/wrong direct-packing benchmark protocol")
    require(len(env.get("imagery_measured_commit", "")) == 40,
            "missing exact 40-digit imagery git commit")
    require("1.43.0" in env.get("compiler", ""),
            "XPS benchmark requires LDC 1.43.0")
    w = 192 if mode == "smoke" else 512
    sides = (16, 64) if mode == "smoke" else (16, 32, 64, 128, 256)
    patterns = ("mixed",) if mode == "smoke" else ("mixed", "transparent")
    meanings = ("encoded-straight", "linear-pm")
    layouts = ("planar", "interleaved")
    rounds = 2 if mode == "smoke" else 7
    iterations = 2 if mode == "smoke" else 24
    cases = sorted((meaning, pattern, layout, side)
                   for meaning in meanings for pattern in patterns
                   for layout in layouts for side in sides)
    raw_names = {format_case(w, *case) for case in cases}
    optimization = env.get("optimization_mode", "none")
    require(optimization in ("none", "thin-lto"),
            "unknown optimizer protocol")
    extra = set(MANIFEST_EXTRAS)
    if optimization == "thin-lto":
        require(env.get("lto_configuration") == "thin-lto" and
                env.get("linker") == "lld",
                "thinlto archive lacks explicit library/linker provenance")
        extra.add("CODEGEN_CALLS.json")
    expected = raw_names | extra
    manifest = {}
    for line in (directory / "CHECKSUMS.sha256").read_text(
            encoding="utf-8").splitlines():
        values = line.split(maxsplit=1)
        require(len(values) == 2, "invalid checksums row")
        digest, rel = values
        name = rel.lstrip("*").removeprefix("./")
        require(len(digest) == 64 and
                all(x in "0123456789abcdef" for x in digest) and
                "/" not in name and name not in manifest,
                "unsafe/duplicate manifest entry")
        manifest[name] = digest
    require(set(manifest) == expected, "missing/extra manifest files")
    actual_csv = {
        p.name for p in directory.glob("*.csv")
        if p.name != "DIRECT_COMPARISON.csv"}
    require(actual_csv == raw_names, "unexpected/missing raw CSVs")
    for name, digest in manifest.items():
        p = directory / name
        require(p.is_file(), "manifest file missing: " + name)
        require(hashlib.sha256(p.read_bytes()).hexdigest() == digest,
                "sha256 mismatch: " + name)
    binary = directory / "m3-direct-owned-consumer"
    require(binary.stat().st_size > 0,
            "missing measured consumer executable bytes")
    if optimization == "thin-lto":
        report = json.loads((directory / "CODEGEN_CALLS.json").read_text())
        require(report.get("binary_sha256") ==
                hashlib.sha256(binary.read_bytes()).hexdigest() and
                report.get("binary_bytes") == binary.stat().st_size and
                set(report.get("functions", {})) == {"private", "library"},
                "codegen inspection does not describe measured executable")
    out = []
    checksum_cross_layout = {}
    for meaning, pattern, layout, side in cases:
        name = format_case(w, meaning, pattern, layout, side)
        raw = (directory / name).read_text(encoding="utf-8")
        rows = list(csv.reader(io.StringIO(raw)))
        require(rows and tuple(rows[0]) == HEADER, "bad CSV columns: "+name)
        require(len(rows) == 2 + 3*rounds,
                "incomplete row matrix: "+name)
        # The producer's prose success line is comma-bearing.
        trailer = ",".join(rows[-1])
        require(trailer ==
                "M3 DIRECT OWNED BENCH PASS: three complete owned paths, "
                "four offset ROI exact byte and source independence",
                "missing/malformed successful all-pixel trailer: "+name)
        measurements = {}
        checked_hash = set()
        gc = {stage: 0 for stage in STAGES}
        for position, cells in enumerate(rows[1:-1]):
            require(len(cells) == len(HEADER), "malformed CSV record: "+name)
            row = dict(zip(HEADER, cells))
            round_number = int(row["round"])
            stage = row["stage"]
            require(0 <= round_number < rounds and stage in STAGES,
                    "invalid round/stage: "+name)
            require(stage == STAGES[(position % 3 + round_number) % 3] and
                    round_number == position // 3,
                    "lost rotated measurement pairing: "+name)
            require(row["meaning"] == meaning and
                    row["pattern"] == pattern and
                    row["layout"] == layout and
                    row["roi"] == f"square{side}" and
                    int(row["width"]) == w and
                    int(row["height"]) == w and
                    int(row["pixels"]) == side*side and
                    int(row["iterations"]) == iterations,
                    "wrong benchmark configuration: "+name)
            elapsed = int(row["elapsed_ns"])
            delta_gc = int(row["thread_gc_bytes"])
            # All three stages allocate AND publish a full owned result.
            require(elapsed > 0 and delta_gc >= 0,
                    "invalid full-owned duration/GC: "+name)
            key = (round_number, stage)
            require(key not in measurements, "duplicate stage/round: "+name)
            measurements[key] = elapsed
            gc[stage] += delta_gc
            checked_hash.add(int(row["canonical_checksum"]))
        require(len(checked_hash) == 1 and
                len(measurements) == rounds*len(STAGES),
                "incomplete samples/byte-oracle drift: "+name)
        checked = next(iter(checked_hash))
        cross = (meaning, pattern, side)
        if cross in checksum_cross_layout:
            require(checksum_cross_layout[cross] == checked,
                    "planar/interleaved output bytes disagree")
        else:
            checksum_cross_layout[cross] = checked
        def absolute_ns_px(stage):
            return statistics.median([
                measurements[(r,stage)] / iterations / (side*side)
                for r in range(rounds)])
        def paired(a,b):
            return [measurements[(r,a)]/measurements[(r,b)]
                    for r in range(rounds)]
        def signed(a,b):
            return [(measurements[(r,a)]-measurements[(r,b)]) /
                    (iterations*side*side) for r in range(rounds)]
        old = "owned_fused_checked"
        private = "owned_extracted_library"
        library = "owned_direct_packed"
        private_old = paired(private, old)
        library_old = paired(library, old)
        library_private = paired(library, private)
        private_extra = signed(private, old)
        library_extra = signed(library, old)
        out.append((
            meaning, pattern, layout, f"square{side}", side*side,
            rounds, iterations,
            f"{absolute_ns_px(old):.6f}",
            f"{absolute_ns_px(private):.6f}",
            f"{absolute_ns_px(library):.6f}",
            f"{statistics.median(private_old):.6f}",
            f"{statistics.median(library_old):.6f}",
            f"{statistics.median(library_private):.6f}",
            f"{statistics.median(private_extra):.6f}",
            f"{statistics.median(library_extra):.6f}",
            f"{min(library_old):.6f}", f"{max(library_old):.6f}",
            gc[old], gc[private], gc[library], checked))
    require(len(out) == len(cases), "incomplete case set")
    return out


def self_test():
    with tempfile.TemporaryDirectory(prefix="m3-owned-direct-replay-") as tmp:
        directory = Path(tmp)
        (directory / "environment.txt").write_text(
            "mode=smoke\nsource_mode=pinned-v0.2.0\n"
            "benchmark_protocol=direct-4N\n"
            "imagery_measured_commit=" + "a"*40 + "\n"
            "compiler=LDC - the LLVM D compiler (1.43.0):\n")
        (directory / "build.log").write_bytes(b"synthetic build receipt\n")
        (directory / "m3-direct-owned-consumer").write_bytes(b"synthetic binary")
        for meaning in ("encoded-straight", "linear-pm"):
            for pattern in ("mixed",):
                for layout in ("planar", "interleaved"):
                    for side in (16,64):
                        name = format_case(192, meaning, pattern, layout, side)
                        checksum = side * 100 + (1 if meaning == "linear-pm" else 0)
                        out = io.StringIO()
                        writer = csv.writer(out, lineterminator="\n")
                        writer.writerow(HEADER)
                        for r in range(2):
                            for offset in range(3):
                                stage = STAGES[(r + offset) % 3]
                                t = {"owned_fused_checked": 10000,
                                     "owned_extracted_library": 10100,
                                     "owned_direct_packed": 10200}[stage]
                                writer.writerow((
                                    meaning, pattern, layout, f"square{side}",
                                    192, 192, side*side, r, 2, stage,
                                    t, 0, checksum))
                        out.write(
                            "M3 DIRECT OWNED BENCH PASS: three complete owned"
                            " paths, four offset ROI exact byte"
                            " and source independence\n"
                        )
                        (directory / name).write_text(out.getvalue())
        names = sorted(
            [p.name for p in directory.glob("*.csv")]
            + list(MANIFEST_EXTRAS)
        )
        (directory / "CHECKSUMS.sha256").write_text(
            "".join(hashlib.sha256((directory / n).read_bytes()).hexdigest()
                    + "  " + n + "\n" for n in names))
        rows = analyze(directory)
        assert len(rows) == 8
        assert all(x[10] == "1.010000" and x[11] == "1.020000"
                   and x[12] == "1.009901"
                   for x in rows if x[4] == 256)
        target = directory / format_case(
            192, "linear-pm", "mixed", "interleaved", 16)
        target.write_bytes(target.read_bytes()+b"tamper")
        try:
            analyze(directory)
        except ValueError as e:
            assert "sha256 mismatch" in str(e)
        else:
            raise AssertionError("manifest mutation passed checksum gate")
        # A counterfeit human trailer must fail even after the raw CSV
        # SHA-256 is updated to match the modified bytes.
        target.write_bytes(target.read_bytes().removesuffix(b"tamper"))
        malformed = target.read_text().replace(
            "four offset ROI all-pixel old/fused/library equality",
            "not independently checked ROI samples")
        target.write_text(malformed)
        manifest_path = directory / "CHECKSUMS.sha256"
        manifest_lines = manifest_path.read_text().splitlines()
        manifest_path.write_text(
            "\n".join(
                hashlib.sha256(target.read_bytes()).hexdigest() + "  "
                + target.name if line.endswith("  " + target.name)
                else line
                for line in manifest_lines
            ) + "\n"
        )
        try:
            analyze(directory)
        except ValueError as e:
            assert "missing/malformed successful all-pixel trailer" in str(e)
        else:
            raise AssertionError("malformed comma-bearing trailer accepted")
    print("M3 DIRECT OWNED VALIDATOR SELF-TEST PASS")


def main(directory):
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(SUMMARY)
    writer.writerows(analyze(directory))


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
    elif len(sys.argv) == 2:
        main(Path(sys.argv[1]))
    else:
        raise SystemExit(
            "Usage: summarize_m3_rgba_direct_xps.py OUT|--self-test")
