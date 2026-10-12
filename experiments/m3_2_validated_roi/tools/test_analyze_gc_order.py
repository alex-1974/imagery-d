#!/usr/bin/env python3
"""Positive and deliberate negative replay tests for counterbalanced evidence."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "gc_order", HERE / "analyze_gc_order.py"
)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class GCOrderEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        (self.folder / "environment.txt").write_text(
            "schema=imagery-d-m3.2.15-gc-order-v1\n"
            "repeats=2 rounds=2 warmups=1 smoke=1\n",
            encoding="utf-8"
        )
        for run in range(2):
            lines = ["reuse_gc_schema," + ",".join(mod.FIELDS)]
            for case_rank, n, side, layout, mask, policy, count in mod.order_cases(
                run, smoke=True
            ):
                for rnd in range(2):
                    absolute = rnd + 1
                    choice = (absolute * 5 + count) % 8
                    permutation = (absolute + count) % 3
                    checksum = mod.expected_sum(
                        n, count, absolute, permutation, choice, mask
                    )
                    for slot in range(2):
                        mode = mod.MODES[(absolute + slot) % 2]
                        values = (
                            case_rank, run, n, side, layout, mask, policy,
                            count, rnd, slot, mode, 100, 2000, 2300,
                            checksum, checksum, 384 if mode == "prepared" else 0,
                            0, 0, 0, 0
                        )
                        lines.append("reuse_gc_case," + ",".join(map(str, values)))
            lines.append(
                "M3.2.15 PASS: counterbalanced order and instrumented ROI oracle"
            )
            (self.folder / f"run-{run}.log").write_text(
                "\n".join(lines) + "\n", encoding="utf-8"
            )

    def mutate_first(self, func):
        path = self.folder / "run-1.log"
        lines = path.read_text().splitlines()
        row = lines[1].split(",")
        func(row)
        lines[1] = ",".join(row)
        path.write_text("\n".join(lines) + "\n")

    def test_complete_two_process_orders(self):
        rows, summary, report = mod.qualify(self.folder)
        self.assertEqual(len(rows), 384)
        self.assertEqual(len(summary), 96)
        self.assertEqual(report["paired_cycles"], 192)
        self.assertEqual(report["independent_pixel_oracle"], "PASS")

    def test_missing_row(self):
        p = self.folder / "run-0.log"
        lines = p.read_text().splitlines()
        p.write_text("\n".join(lines[:1] + lines[2:]) + "\n")
        with self.assertRaisesRegex(ValueError, "Incomplete process/case matrix"):
            mod.qualify(self.folder)

    def test_wrong_case_order(self):
        self.mutate_first(lambda r: r.__setitem__(1, str(int(r[1]) + 1)))
        with self.assertRaisesRegex(ValueError, "Incorrect deterministic case order"):
            mod.qualify(self.folder)

    def test_wrong_process_seed(self):
        self.mutate_first(lambda r: r.__setitem__(2, "0"))
        with self.assertRaisesRegex(ValueError, "Run seed mismatch"):
            mod.qualify(self.folder)

    def test_forged_matching_checksums(self):
        def forge(r):
            r[15] = str(float(r[15]) + 500)
            r[16] = r[15]
        self.mutate_first(forge)
        with self.assertRaisesRegex(ValueError, "Independent pixel checksum"):
            mod.qualify(self.folder)

    def test_negative_gc_allocation_delta(self):
        self.mutate_first(lambda r: r.__setitem__(17, "-1"))
        with self.assertRaisesRegex(ValueError, "Negative setup or negative GC"):
            mod.qualify(self.folder)

    def test_negative_major_fault_delta(self):
        self.mutate_first(lambda r: r.__setitem__(21, "-1"))
        with self.assertRaisesRegex(ValueError, "Negative setup or negative GC"):
            mod.qualify(self.folder)

    def test_tiny_quantized_setup_is_valid(self):
        self.mutate_first(lambda r: r.__setitem__(12, "0"))
        rows, _, _ = mod.qualify(self.folder)
        self.assertEqual(len(rows), 384)

    def test_invalid_map_elapsed(self):
        self.mutate_first(lambda r: r.__setitem__(13, "0"))
        with self.assertRaisesRegex(ValueError, "Nonpositive measured map"):
            mod.qualify(self.folder)

    def test_missing_process(self):
        (self.folder / "run-1.log").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or additional processes"):
            mod.qualify(self.folder)

    def test_wrong_completion_marker(self):
        p = self.folder / "run-0.log"
        p.write_text(p.read_text().replace("M3.2.15 PASS:", "M3.2.15 FAIL:"))
        with self.assertRaisesRegex(ValueError, "Missing D-run completion marker"):
            mod.qualify(self.folder)


if __name__ == "__main__":
    unittest.main()
