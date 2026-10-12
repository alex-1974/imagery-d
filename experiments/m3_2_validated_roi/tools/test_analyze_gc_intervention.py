#!/usr/bin/env python3
"""Positive and deliberately malformed GC intervention evidence fixtures."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "gc_intervention", HERE / "analyze_gc_intervention.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class GCInterventionAnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        (self.folder / "environment.txt").write_text(
            "schema=imagery-d-m3.2.16-gc-intervention-v1\n"
            "repeats=2 rounds=2 warmups=1 smoke=1 side=32 reuse=1\n",
            encoding="utf-8"
        )
        for run in range(2):
            for mode in mod.MODES:
                lines = ["gc_intervention_schema," + ",".join(mod.FIELDS)]
                for rnd in range(2):
                    val = mod.independent_expected(rnd + 1, 1)
                    args = (
                        mode, rnd, 256, 32, "planar", 1, 1000, 1200,
                        2300, val, val, 17744, 0, 0, 1, 0,
                        1500 if mode == "precollect" else 0,
                        1 if mode == "precollect" else 0,
                        500 if mode == "precollect" else 0,
                        500_000, 2_000_000, 510_000, 1_990_000, 0, 0
                    )
                    lines.append("gc_intervention," + ",".join(map(str, args)))
                lines.append(
                    "M3.2.16 PASS: calibrated GC counterfactual pixel oracle"
                )
                (self.folder / f"run-{run}-{mode}.log").write_text(
                    "\n".join(lines) + "\n", encoding="utf-8"
                )

    def modify_first(self, operation, mode="normal"):
        path = self.folder / f"run-0-{mode}.log"
        lines = path.read_text().splitlines()
        row = lines[1].split(",")
        operation(row)
        lines[1] = ",".join(row)
        path.write_text("\n".join(lines) + "\n")

    def test_complete(self):
        rows, processes, result = mod.qualify(self.folder)
        self.assertEqual(len(rows), 12)
        self.assertEqual(len(processes), 6)
        self.assertEqual(result["independent_oracle"], "PASS")
        self.assertEqual(result["rows"], 12)

    def test_end_to_end_command_writes_all_evidence(self):
        import csv
        import json
        import subprocess
        import sys
        completed = subprocess.run(
            [sys.executable, str(HERE / "analyze_gc_intervention.py"),
             str(self.folder)],
            capture_output=True, text=True, check=True
        )
        self.assertIn("PASS: 12 calibrated measured batches", completed.stdout)
        raw_file = self.folder / "gc-intervention-raw.csv"
        processes_file = self.folder / "gc-intervention-processes.csv"
        summary_file = self.folder / "gc-intervention-summary.json"
        with raw_file.open(newline="") as handle:
            self.assertEqual(len(list(csv.DictReader(handle))), 12)
        with processes_file.open(newline="") as handle:
            self.assertEqual(len(list(csv.DictReader(handle))), 6)
        summary = json.loads(summary_file.read_text())
        self.assertEqual(summary["rows"], 12)
        self.assertTrue(summary["complete"])

    def test_missing_mode(self):
        (self.folder / "run-0-precollect.log").unlink()
        with self.assertRaisesRegex(ValueError, "Missing/extra process modes"):
            mod.qualify(self.folder)

    def test_missing_round(self):
        file = self.folder / "run-1-normal.log"
        lines = file.read_text().splitlines()
        file.write_text("\n".join(lines[:1] + lines[2:]) + "\n")
        with self.assertRaises(ValueError):
            mod.qualify(self.folder)

    def test_duplicate_round(self):
        file = self.folder / "run-1-normal.log"
        lines = file.read_text().splitlines()
        file.write_text("\n".join(lines[:2] + [lines[1]] + lines[2:]) + "\n")
        with self.assertRaises(ValueError):
            mod.qualify(self.folder)

    def test_wrong_policy(self):
        self.modify_first(lambda x: x.__setitem__(1, "deferred"))
        with self.assertRaisesRegex(ValueError, "Wrong mode"):
            mod.qualify(self.folder)

    def test_both_checksum_and_expected_forged(self):
        def bad(x):
            x[10] = str(float(x[10]) + 1000)
            x[11] = x[10]
        self.modify_first(bad)
        with self.assertRaisesRegex(ValueError, "Independent physical-pixel"):
            mod.qualify(self.folder)

    def test_negative_gc_pause(self):
        self.modify_first(lambda x: x.__setitem__(14, "-1"))
        with self.assertRaisesRegex(ValueError, "Negative GC"):
            mod.qualify(self.folder)

    def test_forbidden_precollect_in_normal(self):
        self.modify_first(lambda x: x.__setitem__(18, "1"))
        with self.assertRaisesRegex(ValueError, "Forbidden external precollection"):
            mod.qualify(self.folder)

    def test_forbidden_after_enable_in_precollect(self):
        self.modify_first(
            lambda x: x.__setitem__(24, "1"), mode="precollect")
        with self.assertRaisesRegex(ValueError, "Unexpected enable-time effects"):
            mod.qualify(self.folder)

    def test_zero_setup_is_timer_resolution(self):
        self.modify_first(lambda x: x.__setitem__(7, "0"))
        self.assertEqual(len(mod.qualify(self.folder)[0]), 12)

    def test_zero_mapping_invalid(self):
        self.modify_first(lambda x: x.__setitem__(8, "0"))
        with self.assertRaisesRegex(ValueError, "Invalid measured duration"):
            mod.qualify(self.folder)

    def test_missing_pass(self):
        p = self.folder / "run-1-deferred.log"
        p.write_text(p.read_text().replace("M3.2.16 PASS:", "M3.2.16 FAIL:"))
        with self.assertRaisesRegex(ValueError, "Missing D oracle pass marker"):
            mod.qualify(self.folder)


if __name__ == "__main__":
    unittest.main()
