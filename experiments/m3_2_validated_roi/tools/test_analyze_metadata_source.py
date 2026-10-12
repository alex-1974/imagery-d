#!/usr/bin/env python3
"""Synthetic complete and adversarial order-sensitive transcript fixtures."""
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
    "metadata_source", HERE / "analyze_metadata_source.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MetadataSourceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        (self.folder / "environment.txt").write_text(
            "schema=imagery-d-m3.2.18-metadata-source-ordered-v1\n"
            "repeats=2 packets=2 sides=8 reuses=4\n",
            encoding="utf-8"
        )
        for run in range(2):
            for policy in module.POLICIES:
                rows = [
                    "metadata_source_packet_schema," +
                    ",".join(module.PACKET_FIELDS),
                    "metadata_source_roi_schema," +
                    ",".join(module.ROI_FIELDS),
                ]
                for phase in module.PHASES:
                    for packet in range(2):
                        for roi in range(4):
                            k = (packet + roi) % 4
                            x, y = module.XS[k], module.YS[k]
                            first = [
                                module.physical(phase, component, x, y)
                                for component in range(3)
                            ]
                            last = [
                                module.physical(phase, component, x + 7, y + 7)
                                for component in range(3)
                            ]
                            record = (
                                policy, phase, packet, roi, 8, 4, x, y,
                                *[f"{value:.6g}" for value in first + last],
                            )
                            rows.append(
                                "metadata_source_roi," +
                                ",".join(map(str, record))
                            )
                        rows.append(
                            "metadata_source_packet," +
                            ",".join(map(str, (policy, phase, packet, 8, 4,
                                               1000, 0)))
                        )
                rows.append(
                    "M3.2.18 PASS: immutable source lifetime "
                    "and all ordered ROI lanes"
                )
                (self.folder / f"run-{run}-{policy}-8-4.log").write_text(
                    "\n".join(rows) + "\n", encoding="utf-8")

    def edit_row(self, operation, policy="immutable", row_index=2):
        path = self.folder / f"run-0-{policy}-8-4.log"
        lines = path.read_text(encoding="utf-8").splitlines()
        row = lines[row_index].split(",")
        operation(row)
        lines[row_index] = ",".join(row)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_complete(self):
        roi, packets, proc, result = module.audit(self.folder)
        self.assertEqual(len(proc), 4)
        self.assertEqual(len(packets), 16)
        self.assertEqual(len(roi), 64)
        self.assertEqual(result["per_packet_gc_allocation_bytes"], 0)

    def test_end_to_end_serialization(self):
        proc = subprocess.run(
            [sys.executable, str(HERE / "analyze_metadata_source.py"),
             str(self.folder)], capture_output=True, text=True, check=True
        )
        self.assertIn("PASS: 4 isolated sources", proc.stdout)
        for name, count in (
            ("metadata-source-rois.csv", 64),
            ("metadata-source-packets.csv", 16),
            ("metadata-source-processes.csv", 4),
        ):
            with (self.folder / name).open(newline="") as handle:
                self.assertEqual(len(list(csv.DictReader(handle))), count)
        summary = json.loads(
            (self.folder / "metadata-source-summary.json").read_text())
        self.assertEqual(summary["ordered_roi_records"], 64)

    def test_missing_process(self):
        (self.folder / "run-1-immutable-8-4.log").unlink()
        with self.assertRaisesRegex(ValueError, "Missing/extra"):
            module.audit(self.folder)

    def test_swapped_roi_rows(self):
        path = self.folder / "run-0-immutable-8-4.log"
        lines = path.read_text().splitlines()
        lines[2], lines[3] = lines[3], lines[2]
        path.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(ValueError, "Reordered"):
            module.audit(self.folder)

    def test_missing_roi_row(self):
        path = self.folder / "run-0-immutable-8-4.log"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:3] + lines[4:]) + "\n")
        with self.assertRaises(ValueError):
            module.audit(self.folder)

    def test_duplicated_roi_row(self):
        path = self.folder / "run-0-immutable-8-4.log"
        lines = path.read_text().splitlines()
        path.write_text("\n".join(lines[:3] + [lines[2]] + lines[3:]) + "\n")
        with self.assertRaises(ValueError):
            module.audit(self.folder)

    def test_forged_component(self):
        self.edit_row(lambda r: r.__setitem__(10, str(float(r[10]) + 15)))
        with self.assertRaisesRegex(ValueError, "Forged/wrong"):
            module.audit(self.folder)

    def test_wrong_position_with_recomputed_pixel(self):
        self.edit_row(lambda r: r.__setitem__(7, "29"))
        with self.assertRaisesRegex(ValueError, "Reordered"):
            module.audit(self.folder)

    def test_forged_validity_mask(self):
        self.edit_row(lambda r: r.__setitem__(9, "888"))
        with self.assertRaisesRegex(ValueError, "Forged/wrong"):
            module.audit(self.folder)

    def test_hot_gc_allocation(self):
        # First packet summary is after the first four ROI rows:
        self.edit_row(lambda r: r.__setitem__(7, "17744"), row_index=6)
        with self.assertRaisesRegex(ValueError, "@nogc"):
            module.audit(self.folder)

    def test_refresh_not_observable(self):
        path = self.folder / "run-0-immutable-8-4.log"
        lines = path.read_text().splitlines()
        for line_idx, line in enumerate(lines):
            if line.startswith("metadata_source_roi,immutable,refreshed"):
                cells = line.split(",")
                p, roi = int(cells[3]), int(cells[4])
                k = (p + roi) % 4
                x, y = module.XS[k], module.YS[k]
                for i in range(3):
                    cells[9 + i] = f"{module.physical('original', i, x, y):.6g}"
                    cells[12 + i] = (
                        f"{module.physical('original', i, x + 7, y + 7):.6g}")
                lines[line_idx] = ",".join(cells)
        path.write_text("\n".join(lines) + "\n")
        with self.assertRaises(ValueError):
            module.audit(self.folder)

    def test_duplicate_pass_marker(self):
        path = self.folder / "run-0-immutable-8-4.log"
        with path.open("a") as output:
            output.write(
                "M3.2.18 PASS: immutable source lifetime "
                "and all ordered ROI lanes\n")
        with self.assertRaisesRegex(ValueError, "Missing/duplicate"):
            module.audit(self.folder)


if __name__ == "__main__":
    unittest.main()
