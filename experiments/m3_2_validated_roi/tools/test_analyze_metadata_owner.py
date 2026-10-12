#!/usr/bin/env python3
"""Strict positive and malformed M3.2.17 ownership evidence fixtures."""
import csv
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "metadata_owner", HERE / "analyze_metadata_owner.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class MetadataOwnerAnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        (self.folder / "environment.txt").write_text(
            "schema=imagery-d-m3.2.17-metadata-owner-v1\n"
            "repeats=2 packets=2 sides=8 reuses=4\n")
        for run in range(2):
            for policy in mod.POLICIES:
                lines = ["metadata_owner_schema," + ",".join(mod.FIELDS)]
                for packet in range(2):
                    expected = mod.independent_checksum(packet, 4)
                    row = (
                        policy, 8, 4, packet,
                        100 if packet == 0 or policy == "snapshot_each" else 0,
                        1000, expected, expected,
                        17744 if policy == "snapshot_each" else 0,
                        400 if policy == "snapshot_once" and packet == 0 else 0,
                        17744 if policy == "snapshot_once" and packet == 0 else 0
                    )
                    lines.append("metadata_owner_case," + ",".join(map(str, row)))
                lines.append(
                    "M3.2.17 PASS: immutable ownership, snapshot isolation and actual ROI pixel oracle"
                )
                (self.folder / f"run-{run}-{policy}-8-4.log").write_text(
                    "\n".join(lines) + "\n", encoding="utf-8")

    def mutate(self, mode, mutate, run=0):
        path = self.folder / f"run-{run}-{mode}-8-4.log"
        lines = path.read_text().splitlines()
        row = lines[1].split(",")
        mutate(row)
        lines[1] = ",".join(row)
        path.write_text("\n".join(lines) + "\n")

    def test_complete(self):
        rows, processes, audit = mod.qualify(self.folder)
        self.assertEqual(len(rows), 12)
        self.assertEqual(len(processes), 6)
        self.assertEqual(audit["independent_physical_pixel_oracle"], "PASS")

    def test_actual_cli_serialization(self):
        output = subprocess.run(
            [sys.executable, str(HERE / "analyze_metadata_owner.py"),
             str(self.folder)], capture_output=True, text=True, check=True)
        self.assertIn("PASS: 6 processes, 12 independent", output.stdout)
        with (self.folder / "metadata-owner-raw.csv").open(newline="") as src:
            self.assertEqual(len(list(csv.DictReader(src))), 12)
        with (self.folder / "metadata-owner-processes.csv").open(newline="") as src:
            self.assertEqual(len(list(csv.DictReader(src))), 6)
        self.assertEqual(json.loads(
            (self.folder / "metadata-owner-summary.json").read_text()
        )["observations"], 12)

    def test_missing_process(self):
        (self.folder / "run-1-immutable-8-4.log").unlink()
        with self.assertRaisesRegex(ValueError, "Incomplete/extra"):
            mod.qualify(self.folder)

    def test_missing_record(self):
        path = self.folder / "run-0-immutable-8-4.log"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:1] + lines[2:]) + "\n")
        with self.assertRaisesRegex(ValueError, "Incorrect policy/packet|Incomplete"):
            mod.qualify(self.folder)

    def test_duplicate_record(self):
        path = self.folder / "run-0-immutable-8-4.log"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:2] + [lines[1]] + lines[2:]) + "\n")
        with self.assertRaisesRegex(ValueError, "Incorrect policy/packet"):
            mod.qualify(self.folder)

    def test_forged_checksum_and_expected(self):
        def forge(row):
            row[7] = str(float(row[7]) + 1000)
            row[8] = row[7]
        self.mutate("immutable", forge)
        with self.assertRaisesRegex(ValueError, "independent mapped-pixel oracle"):
            mod.qualify(self.folder)

    def test_unsafe_hot_allocation_in_prepared(self):
        self.mutate("snapshot_once", lambda row: row.__setitem__(9, "777"))
        with self.assertRaisesRegex(ValueError, "GC allocation in promised"):
            mod.qualify(self.folder)

    def test_missing_snapshot_once(self):
        self.mutate("snapshot_once", lambda row: row.__setitem__(11, "0"))
        with self.assertRaisesRegex(ValueError, "Missing measured one-time snapshot"):
            mod.qualify(self.folder)

    def test_missing_per_packet_copies(self):
        self.mutate("snapshot_each", lambda row: row.__setitem__(9, "0"))
        with self.assertRaisesRegex(ValueError, "Missing per-packet"):
            mod.qualify(self.folder)

    def test_wrong_policy(self):
        self.mutate("immutable", lambda row: row.__setitem__(1, "snapshot_each"))
        with self.assertRaisesRegex(ValueError, "Incorrect policy"):
            mod.qualify(self.folder)

    def test_setup_under_stopwatch_granularity_allowed(self):
        self.mutate("immutable", lambda row: row.__setitem__(5, "0"))
        self.assertEqual(len(mod.qualify(self.folder)[0]), 12)

    def test_missing_completion_marker(self):
        path = self.folder / "run-0-immutable-8-4.log"
        path.write_text(path.read_text().replace("M3.2.17 PASS:", "M3.2.17 FAIL:"))
        with self.assertRaisesRegex(ValueError, "Missing D full-pixel"):
            mod.qualify(self.folder)


if __name__ == "__main__":
    unittest.main()
