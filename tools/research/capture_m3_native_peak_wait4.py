#!/usr/bin/env python3
"""Linux research-only child wait4 peak-RSS receipt plus independent FD9 trace.

Unlike ten /proc checkpoints, wait4 returns the OS-observed process-lifetime
ru_maxrss, including intervals BETWEEN stage snapshots. This is still NOT
an allocator/residency budget, attribution to raster-d, or thread-local cost.
"""
import csv
import os
from pathlib import Path
import subprocess
import sys


def run(prefix: Path, interposer: Path | None, command: list[str]) -> int:
    if not command:
        raise ValueError("missing child command")
    if not hasattr(os, "wait4"):
        raise RuntimeError("Linux/Unix wait4 is required")
    paths = [prefix.with_name(prefix.name + suffix) for suffix in (
        "-events.csv", "-stdout.txt", "-stderr.txt", "-wait4.csv")]
    if any(path.exists() for path in paths):
        raise FileExistsError("refusing an already captured process result")
    env = os.environ.copy()
    if interposer is not None:
        if not interposer.is_file():
            raise FileNotFoundError("missing research interposer")
        env["LD_PRELOAD"] = str(interposer.resolve())
    output_fd = os.open(paths[0], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    if output_fd != 9:
        os.dup2(output_fd, 9, inheritable=True)
        os.close(output_fd)
    else:
        os.set_inheritable(9, True)
    try:
        with paths[1].open("wb") as stdout, paths[2].open("wb") as stderr:
            child = subprocess.Popen(
                command, stdout=stdout, stderr=stderr,
                env=env, pass_fds=(9,))
            try:
                _, status, usage = os.wait4(child.pid, 0)
            except BaseException:
                # On interrupted collection, reap the child before leaving.
                child.wait()
                raise
            child.returncode = os.waitstatus_to_exitcode(status)
    finally:
        os.close(9)
    with paths[3].open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(("exit_code", "kernel_peak_rss_kib",
                         "minor_faults", "major_faults"))
        writer.writerow((child.returncode, usage.ru_maxrss,
                         usage.ru_minflt, usage.ru_majflt))
    return child.returncode


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        prefix = Path(directory) / "child"
        code = ("import os; os.write(9, b'S,1,0x0,0,0\\n'); "
                "print('child-pass')")
        assert run(prefix, None, [sys.executable, "-c", code]) == 0
        assert (Path(str(prefix) + "-events.csv").read_bytes() ==
                b"S,1,0x0,0,0\n")
        assert (Path(str(prefix) + "-stdout.txt").read_text().strip() ==
                "child-pass")
        with Path(str(prefix) + "-wait4.csv").open(newline="") as f:
            rows = list(csv.DictReader(f))
        assert len(rows) == 1
        assert rows[0]["exit_code"] == "0"
        assert int(rows[0]["kernel_peak_rss_kib"]) > 0
        try:
            run(prefix, None, [sys.executable, "-c", code])
        except FileExistsError:
            pass
        else:
            raise AssertionError("overwrote previous evidence")
    print("NATIVE WAIT4 PEAK CAPTURE SELF-TEST PASS")


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(sys.argv) < 5 or sys.argv[1] != "--capture":
        raise SystemExit(
            "usage: capture_m3_native_peak_wait4.py --self-test | "
            "--capture OUT_PREFIX INTERPOSER EXE [ARGS...]")
    result = run(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:])
    if result != 0:
        raise SystemExit("research child terminated with exit code %s" % result)


if __name__ == "__main__":
    main()
