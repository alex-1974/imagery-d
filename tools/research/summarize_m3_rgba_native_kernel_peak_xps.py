#!/usr/bin/env python3
"""Cross-check one independent wait4 peak-RSS receipt and nine-stage trace.

Peak kernel RSS is process-wide; the source-labeled event peak only covers
interposed request *sizes*. Neither establishes a complete memory bound.
"""
import csv
import sys
from pathlib import Path

from summarize_m3_rgba_native_alloc_controls import summarize, validate
from summarize_m3_rgba_generation_memory_xps import validate as memory_validate

CASES = ("markers", "raw", "import", "full")
SIDES = (16, 64, 256, 512)
RUSAGE_COLUMNS = ("exit_code", "kernel_peak_rss_kib",
                  "minor_faults", "major_faults",
                  "launcher_pre_spawn_peak_rss_kib")
COLUMNS = ("case", "side", "kernel_peak_rss_kib", "minor_faults",
           "major_faults", "peak_intercepted_requested_bytes",
           "tagged_requested_bytes", "other_requested_bytes",
           "final_other_live_requested_bytes",
           "full_max_sampled_vm_hwm_kib",
           "launcher_pre_spawn_peak_rss_kib",
           "wait4_minus_max_sampled_hwm_kib",
           "full_max_sampled_vm_rss_kib",
           "wait4_minus_max_sampled_rss_kib",
           "full_hwm_exceeds_wait4",
           "full_rss_exceeds_wait4")


def peak_receipt(text):
    rows = list(csv.DictReader(text.splitlines()))
    if len(rows) != 1 or tuple(rows[0]) != RUSAGE_COLUMNS or (
        None in rows[0] or None in rows[0].values()
    ):
        raise ValueError("invalid wait4 receipt schema")
    receipt = {}
    for name in RUSAGE_COLUMNS:
        value = rows[0][name]
        if not value.isdecimal():
            raise ValueError("noncanonical wait4 receipt integer")
        receipt[name] = int(value)
    if receipt["exit_code"] != 0 or receipt["kernel_peak_rss_kib"] == 0:
        raise ValueError("failed child or missing observed kernel RSS peak")
    if (receipt["launcher_pre_spawn_peak_rss_kib"] == 0 or
            receipt["launcher_pre_spawn_peak_rss_kib"] >=
            receipt["kernel_peak_rss_kib"]):
        raise ValueError("launcher RSS high-water dominates child peak")
    return receipt


def signed_peak_differences(kernel_peak_kib, sampled_hwm_kib,
                            sampled_rss_kib):
    """Preserve disagreement rather than rejecting otherwise valid traces.

    Linux has exhibited non-monotonic /proc VmHWM in actual prior XPS
    evidence. Kernel wait4 and /proc high-water do not form a proven
    equality/ordering contract for this sampled environment. Negative
    values are material research findings, never clamped or normalized.
    """
    return {
        "wait4_minus_max_sampled_hwm_kib":
            kernel_peak_kib - sampled_hwm_kib,
        "wait4_minus_max_sampled_rss_kib":
            kernel_peak_kib - sampled_rss_kib,
        "full_hwm_exceeds_wait4":
            int(sampled_hwm_kib > kernel_peak_kib),
        "full_rss_exceeds_wait4":
            int(sampled_rss_kib > kernel_peak_kib)
    }


def analyze(prefix, case, side):
    if case not in CASES or side not in SIDES:
        raise ValueError("unknown native control or side")
    def path(suffix):
        return prefix.with_name(prefix.name + suffix)
    receipt = peak_receipt(path("-wait4.csv").read_text(encoding="utf-8"))
    if path("-stderr.txt").stat().st_size:
        raise ValueError("nonempty child stderr")
    stdout = path("-stdout.txt").read_text(encoding="utf-8")
    if case == "full":
        report = memory_validate(stdout)
        if report["side"] != side:
            raise ValueError("full producer memory ROI mismatch")
        full_hwm = report["max_observed_vmhwm_kib"]
        # The memory validator has already strictly checked the 10 phase
        # rows. Use their original VmRSS rather than estimating a physical
        # bound from VmHWM or a glibc/GC counter.
        samples = list(csv.DictReader(
            [line for line in stdout.splitlines() if line.startswith(
                "experiment,side,phase,")] +
            [line for line in stdout.splitlines() if line.startswith(
                "m3_generation_memory,")]))
        if len(samples) != 10:
            raise ValueError("missing full-producer memory rows")
        full_rss = max(int(row["vmrss_kib"]) for row in samples)
    else:
        phrase = ("M3 ALLOCATION CONTROL PASS: case=%s side=%s " %
                  (case, side))
        if sum(x.startswith(phrase) for x in stdout.splitlines()) != 1:
            raise ValueError("control success marker missing/duplicated")
        full_hwm = 0
        full_rss = 0
    stream = path("-events.csv").read_text(encoding="utf-8")
    details = summarize(stream, case, side)
    phases = validate(stream, case, side)
    if len(phases) != 9:
        raise ValueError("missing nine-stage replay")
    result = {
        "case": case,
        "side": side,
        "kernel_peak_rss_kib": receipt["kernel_peak_rss_kib"],
        "minor_faults": receipt["minor_faults"],
        "major_faults": receipt["major_faults"],
        "peak_intercepted_requested_bytes":
            details["peak_intercepted_requested_bytes"],
        "tagged_requested_bytes": details["tagged_requested_bytes"],
        "other_requested_bytes": details["other_requested_bytes"],
        "final_other_live_requested_bytes": details["other_end_live_bytes"],
        "full_max_sampled_vm_hwm_kib": full_hwm,
        "launcher_pre_spawn_peak_rss_kib":
            receipt["launcher_pre_spawn_peak_rss_kib"],
        "full_max_sampled_vm_rss_kib": full_rss,
        **(signed_peak_differences(
            receipt["kernel_peak_rss_kib"], full_hwm, full_rss)
           if case == "full" else {
               "wait4_minus_max_sampled_hwm_kib": 0,
               "wait4_minus_max_sampled_rss_kib": 0,
               "full_hwm_exceeds_wait4": 0,
               "full_rss_exceeds_wait4": 0
           })
    }
    return result, phases


def write_report(prefix, case, side, destination):
    row, phases = analyze(prefix, case, side)
    with destination.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerow(row)
    if not destination.name.endswith("-summary.csv"):
        raise ValueError("summary path must end with -summary.csv")
    phase_path = destination.with_name(
        destination.name.removesuffix("-summary.csv") + "-stages.csv")
    with phase_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=tuple(phases[0]))
        writer.writeheader()
        writer.writerows(phases)
    print("NATIVE KERNEL PEAK TRACE PASS: case=%s side=%s" % (case, side))


def self_test():
    good = ("exit_code,kernel_peak_rss_kib,minor_faults,major_faults,"
            "launcher_pre_spawn_peak_rss_kib\n0,8192,71,0,512\n")
    assert peak_receipt(good)["kernel_peak_rss_kib"] == 8192
    assert peak_receipt(good)["launcher_pre_spawn_peak_rss_kib"] == 512
    for broken in (
        good.replace("0,8192,71,0,512", "2,8192,71,0,512"),
        good.replace("0,8192,71,0,512", "0,0,71,0,512"),
        good.replace("8192", "-1"),
        good + "0,8192,71,0,512\n",
        good.replace("minor_faults", "faults"),
        good.replace("0,8192,71,0,512", "0,8192,71,0,8192"),
        good.replace(",launcher_pre_spawn_peak_rss_kib", ""),
    ):
        try:
            peak_receipt(broken)
        except ValueError:
            continue
        raise AssertionError("invalid or inherited peak receipt accepted")
    # Regression: the real XPS mismatch must remain a signed observation,
    # not a parser failure, artificial zero or a silent average.
    discordant = signed_peak_differences(3900, 4016, 3872)
    assert discordant == {
        "wait4_minus_max_sampled_hwm_kib": -116,
        "wait4_minus_max_sampled_rss_kib": 28,
        "full_hwm_exceeds_wait4": 1,
        "full_rss_exceeds_wait4": 0
    }
    rss_discordant = signed_peak_differences(3900, 4016, 3916)
    assert rss_discordant["full_rss_exceeds_wait4"] == 1
    assert rss_discordant["wait4_minus_max_sampled_rss_kib"] == -16
    concordant = signed_peak_differences(4800, 4016, 3872)
    assert not concordant["full_hwm_exceeds_wait4"]
    assert concordant["wait4_minus_max_sampled_hwm_kib"] == 784
    print("NATIVE KERNEL PEAK SUMMARY SELF-TEST PASS")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 5:
        write_report(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]),
                     Path(sys.argv[4]))
    else:
        raise SystemExit(
            "usage: summarize_m3_rgba_native_kernel_peak_xps.py "
            "--self-test | PREFIX CASE SIDE OUTPUT-SUMMARY.csv")
