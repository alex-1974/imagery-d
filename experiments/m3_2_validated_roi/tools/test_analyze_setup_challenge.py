#!/usr/bin/env python3
"""Positive and intentionally invalid synthetic M3.2.13 evidence fixtures."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "analyze_setup_challenge", HERE / "analyze_setup_challenge.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class AnalyzerRegression(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.joinpath("environment.txt").write_text(
            "schema=imagery-d-m3.2.13-setup-challenge-v1\n"
            "repeats=1 rounds=4 iterations=24 warmups=1\n", encoding="utf-8"
        )
        lines = ["M3.2.6 PASS: immutable verified-once ROI/negative cases"]
        for channel in module.CHANNELS:
            for rnd in range(4):
                for slot in range(4):
                    mode = module.MODES[(rnd + 1 + slot) % 4]
                    checksum = module.expected_checksum(mode, 24, rnd + 1, {})
                    lines.append(
                        f"setup_challenge,{channel},{rnd},{slot},{mode},"
                        f"24,5000,{checksum},{checksum}"
                    )
        lines.append("M3.2.13 PASS: runtime-selected preparation oracle")
        self.log = self.root / "run-0.log"
        self.log.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def alter(self, old, new):
        raw = self.log.read_text(encoding="utf-8")
        self.assertIn(old, raw)
        self.log.write_text(raw.replace(old, new, 1), encoding="utf-8")

    def test_passes_complete_rotated_fixture(self):
        rows, _, report = module.qualify(self.root)
        self.assertEqual(len(rows), 64)
        self.assertTrue(report["balanced_slots"])

    def test_missing_mode_fails(self):
        lines = self.log.read_text().splitlines()
        self.log.write_text("\n".join(x for i, x in enumerate(lines) if i != 1) + "\n")
        with self.assertRaisesRegex(ValueError, "Incomplete measurement matrix"):
            module.qualify(self.root)

    def test_duplicate_mode_fails(self):
        lines = self.log.read_text().splitlines()
        self.log.write_text("\n".join(lines[:3] + [lines[1]] + lines[3:]) + "\n")
        with self.assertRaisesRegex(ValueError, "Duplicate run/channel/round/slot"):
            module.qualify(self.root)

    def test_oracle_forged_consistently_fails(self):
        lines = self.log.read_text().splitlines()
        row = lines[1].split(",")
        row[-2] = str(int(row[-2]) + 1)
        row[-1] = row[-2]  # old analyser accepted matching forged values
        lines[1] = ",".join(row)
        self.log.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(ValueError, "Independent LCG checksum mismatch"):
            module.qualify(self.root)

    def test_wrong_rotation_fails(self):
        lines = self.log.read_text().splitlines()
        row = lines[1].split(",")
        row[4] = module.MODES[0] if row[4] != module.MODES[0] else module.MODES[1]
        lines[1] = ",".join(row)
        self.log.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(ValueError, "Wrong mode for rotated slot"):
            module.qualify(self.root)

    def test_missing_process_fails(self):
        self.root.joinpath("environment.txt").write_text(
            "repeats=2 rounds=4 iterations=24 warmups=1\n")
        with self.assertRaisesRegex(ValueError, "Missing/extra processes"):
            module.qualify(self.root)

    def test_imbalanced_round_count_fails(self):
        self.root.joinpath("environment.txt").write_text(
            "repeats=1 rounds=3 iterations=24 warmups=1\n")
        with self.assertRaisesRegex(ValueError, "divisible by four"):
            module.qualify(self.root)

    def test_changed_iteration_count_fails(self):
        self.alter(",24,5000,", ",23,5000,")
        with self.assertRaisesRegex(ValueError, "Wrong iteration count"):
            module.qualify(self.root)

    def test_extra_channel_fails(self):
        self.alter("setup_challenge,3,", "setup_challenge,999,")
        with self.assertRaisesRegex(ValueError, "Unexpected channels/round/slot"):
            module.qualify(self.root)

    def test_missing_success_marker_fails(self):
        self.alter("M3.2.13 PASS: runtime-selected preparation oracle", "FAIL")
        with self.assertRaisesRegex(ValueError, "Missing successful D-run completion"):
            module.qualify(self.root)


if __name__ == "__main__":
    unittest.main()
