#!/usr/bin/env python3
"""Strict positive and manipulated ordered scoped-session record fixtures."""
import csv
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "prepared_session", HERE / "analyze_prepared_session.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ScopedSessionAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        (self.folder / "environment.txt").write_text(
            "schema=imagery-d-m3.2.20-scoped-prepared-session-v1\n"
            "repeats=2 packets=2 sides=8 reuses=4\n"
        )
        for repeat in range(2):
            for mode in mod.POLICIES:
                rows = [
                    "prepared_session_schema," + ",".join(mod.CASE_FIELDS),
                    "prepared_session_roi_schema," + ",".join(mod.ROI_FIELDS)
                ]
                for phase in mod.PHASES:
                    for packet in range(2):
                        for roi in range(4):
                            i = (packet + roi) % 4
                            x, y = mod.XS[i], mod.YS[i]
                            corners = [
                                mod.expected_pixel(phase, c, x, y)
                                for c in range(3)
                            ] + [
                                mod.expected_pixel(phase, c, x + 7, y + 7)
                                for c in range(3)
                            ]
                            fields = (
                                mode, phase, packet, roi, 8, 4, x, y,
                                *(f"{v:.6g}" for v in corners)
                            )
                            rows.append("prepared_session_roi," +
                                        ",".join(map(str, fields)))
                    case = (mode, phase, 8, 4, 2, 20000, 0,
                            2 if mode == "reprepare" else 1, 8)
                    rows.append("prepared_session_case," +
                                ",".join(map(str, case)))
                rows.append(
                    "M3.2.20 PASS: scoped multi-packet Prepared lifetime, "
                    "ordered physical ROIs and zero mapping GC"
                )
                (self.folder / f"run-{repeat}-{mode}-8-4.log").write_text(
                    "\n".join(rows) + "\n"
                )

    def corrupt(self, line_index, replacement, mode="session"):
        path = self.folder / f"run-0-{mode}-8-4.log"
        lines = path.read_text().splitlines()
        row = lines[line_index].split(",")
        replacement(row)
        lines[line_index] = ",".join(row)
        path.write_text("\n".join(lines) + "\n")

    def test_complete_all_roi_values(self):
        obs, cases, processes, summary = mod.audit(self.folder)
        self.assertEqual(len(obs), 64)
        self.assertEqual(len(cases), 8)
        self.assertEqual(len(processes), 4)
        self.assertEqual(summary["six_independent_samples_per_roi"], 384)

    def test_actual_cli_outputs(self):
        out = subprocess.run([
            sys.executable, str(HERE / "analyze_prepared_session.py"),
            str(self.folder)
        ], capture_output=True, text=True, check=True)
        self.assertIn("QUALIFIED: 4 processes", out.stdout)
        for filename, expected in (
            ("prepared-session-rois.csv", 64),
            ("prepared-session-phases.csv", 8),
            ("prepared-session-processes.csv", 4),
        ):
            with (self.folder / filename).open(newline="") as f:
                self.assertEqual(len(list(csv.DictReader(f))), expected)
        summary = json.loads(
            (self.folder / "prepared-session-summary.json").read_text())
        self.assertEqual(summary["hot_gc_allocation_bytes"], 0)

    def test_missing_process(self):
        (self.folder / "run-1-session-8-4.log").unlink()
        with self.assertRaisesRegex(ValueError, "Missing/extra"):
            mod.audit(self.folder)

    def test_swapped_roi_order(self):
        path = self.folder / "run-0-session-8-4.log"
        lines = path.read_text().splitlines()
        lines[2], lines[3] = lines[3], lines[2]
        path.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(ValueError, "swapped"):
            mod.audit(self.folder)

    def test_missing_roi(self):
        path = self.folder / "run-0-session-8-4.log"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:3] + lines[4:]) + "\n")
        with self.assertRaises(ValueError):
            mod.audit(self.folder)

    def test_forged_component(self):
        self.corrupt(2, lambda row: row.__setitem__(
            12, str(float(row[12]) + 50)))
        with self.assertRaisesRegex(ValueError, "physical pixel"):
            mod.audit(self.folder)

    def test_forged_roi_location(self):
        self.corrupt(2, lambda row: row.__setitem__(7, "20"))
        with self.assertRaisesRegex(ValueError, "position"):
            mod.audit(self.folder)

    def test_fake_gc_free(self):
        self.corrupt(10, lambda row: row.__setitem__(7, "17744"))
        with self.assertRaisesRegex(ValueError, "preparation/GC"):
            mod.audit(self.folder)

    def test_fake_preparation_count(self):
        self.corrupt(10, lambda row: row.__setitem__(8, "2"))
        with self.assertRaisesRegex(ValueError, "preparation/GC"):
            mod.audit(self.folder)

    def test_fake_roi_count(self):
        self.corrupt(10, lambda row: row.__setitem__(9, "7"))
        with self.assertRaisesRegex(ValueError, "preparation/GC"):
            mod.audit(self.folder)

    def test_duplicate_completion_marker(self):
        path = self.folder / "run-0-session-8-4.log"
        with path.open("a") as out:
            out.write("M3.2.20 PASS: scoped multi-packet Prepared lifetime, "
                      "ordered physical ROIs and zero mapping GC\n")
        with self.assertRaisesRegex(ValueError, "Missing/duplicate"):
            mod.audit(self.folder)


if __name__ == "__main__":
    unittest.main()
