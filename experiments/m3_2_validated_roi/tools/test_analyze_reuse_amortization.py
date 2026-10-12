#!/usr/bin/env python3
"""Synthetic positive/negative completeness gates for the ROI reuse analyser."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "reuse_analyzer", DIR / "analyze_reuse_amortization.py"
)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class ReuseAnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.environment = self.folder / "environment.txt"
        self.environment.write_text(
            "schema=imagery-d-m3.2.14-reuse-v1\n"
            "repeats=1 rounds=2 warmups=1 smoke=1\n", encoding="utf-8"
        )
        lines = ["reuse_schema," + ",".join(mod.FIELDS)]
        for n in mod.CHANNELS[:2]:
            for side in mod.SIDES[:1]:
                for layout in mod.LAYOUTS:
                    mask = "masked" if layout == "planar" else "unmasked"
                    for policy in mod.POLICIES:
                        for count in mod.REUSE:
                            for rnd in range(2):
                                exp = mod.expected_sum(
                                    n, side, policy, count, rnd + 1, mask
                                )
                                for slot in range(2):
                                    mode = mod.MODES[(rnd + 1 + slot) % 2]
                                    lines.append(
                                        f"reuse_case,{n},{side},{layout},{mask},"
                                        f"{policy},{count},{rnd},{slot},{mode},"
                                        f"100,2000,2200,{exp},{exp}"
                                    )
        lines.append("M3.2.14 PASS: paired reuse, full pixels and calibrated oracle")
        self.log = self.folder / "run-0.log"
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def replace_line(self, transform):
        lines = self.log.read_text(encoding="utf-8").splitlines()
        lines[1] = transform(lines[1])
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_complete_passes(self):
        rows, _, report = mod.qualify(self.folder)
        self.assertEqual(len(rows), 192)
        self.assertEqual(report["paired_cycles"], 96)
        self.assertTrue(report["balanced_slots"])

    def test_missing_measurement(self):
        lines = self.log.read_text().splitlines()
        self.log.write_text("\n".join(lines[:1] + lines[2:]) + "\n")
        with self.assertRaisesRegex(ValueError, "incomplete reuse measurement"):
            mod.qualify(self.folder)

    def test_duplicate_measurement(self):
        lines = self.log.read_text().splitlines()
        self.log.write_text("\n".join(lines[:2] + [lines[1]] + lines[2:]) + "\n")
        with self.assertRaisesRegex(ValueError, "duplicate measurement"):
            mod.qualify(self.folder)

    def test_matching_but_forged_checksum(self):
        def forged(line):
            row = line.split(",")
            row[-2] = str(float(row[-2]) + 200.0)
            row[-1] = row[-2]
            return ",".join(row)
        self.replace_line(forged)
        with self.assertRaisesRegex(ValueError, "independent calibrated pixel oracle"):
            mod.qualify(self.folder)

    def test_wrong_rotation(self):
        def rotate(line):
            row = line.split(",")
            row[9] = "prepared" if row[9] == "one_shot" else "one_shot"
            return ",".join(row)
        self.replace_line(rotate)
        with self.assertRaisesRegex(ValueError, "invalid rotated method order"):
            mod.qualify(self.folder)

    def test_wrong_input_policy(self):
        def policy(line):
            row = line.split(",")
            row[5] = "invalid_policy"
            return ",".join(row)
        self.replace_line(policy)
        with self.assertRaisesRegex(ValueError, "unexpected benchmark dimension"):
            mod.qualify(self.folder)

    def test_negative_timing(self):
        def timing(line):
            row = line.split(",")
            row[10] = "-1"
            return ",".join(row)
        self.replace_line(timing)
        with self.assertRaisesRegex(ValueError, "non-positive timed phase"):
            mod.qualify(self.folder)

    def test_missing_process(self):
        self.environment.write_text(
            "repeats=2 rounds=2 warmups=1 smoke=1\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ValueError, "missing or additional process"):
            mod.qualify(self.folder)

    def test_odd_round_count(self):
        self.environment.write_text(
            "repeats=1 rounds=3 warmups=1 smoke=1\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ValueError, "imbalanced reuse"):
            mod.qualify(self.folder)

    def test_missing_success_marker(self):
        body = self.log.read_text(encoding="utf-8")
        self.log.write_text(body.replace("M3.2.14 PASS:", "M3.2.14 FAIL:"))
        with self.assertRaisesRegex(ValueError, "missing program pass marker"):
            mod.qualify(self.folder)


if __name__ == "__main__":
    unittest.main()
