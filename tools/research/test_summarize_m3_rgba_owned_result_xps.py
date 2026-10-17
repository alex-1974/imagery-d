#!/usr/bin/env python3
"""Regression controls for checked native owned-result benchmark evidence."""
import csv
import hashlib
import tempfile
import unittest
from pathlib import Path

from summarize_m3_rgba_owned_result_xps import HEADER, STAGES, summarize


class OwnedBenchmarkCsvTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "environment.txt").write_text(
            "mode=smoke\nsource_mode=pinned-v0.2.0\n"
            "imagery_measured_commit=abcdef012345\n"
        )
        self.names = {}
        for layout in ("interleaved", "planar"):
            for side in (16, 64):
                name = f"192x192-mixed-{layout}-square{side}.csv"
                rows = [HEADER]
                for round_index in range(2):
                    for index, stage in enumerate(STAGES):
                        rows.append((
                            "mixed", layout, f"square{side}",
                            192, 192, side * side, round_index, 2,
                            stage, 100 + 10 * index + round_index,
                            0, 101000 + side,
                        ))
                rows.append((
                    "OWNED-BENCH PASS: three independently timed stages",
                    " four moving ROI positions",
                    " all pixels exact",
                    " prepared_init_us=19",
                ))
                self.names[(layout, side)] = name
                self.write_rows(name, rows)
        self.write_manifest()

    def write_rows(self, name, rows):
        with (self.root / name).open("w", newline="") as stream:
            csv.writer(stream).writerows(rows)

    def read_rows(self, name):
        with (self.root / name).open(newline="") as stream:
            return list(csv.reader(stream))

    def write_manifest(self):
        text = ""
        for name in sorted(self.names.values()):
            digest = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
            text += f"{digest}  ./{name}\n"
        (self.root / "CHECKSUMS.sha256").write_text(text)

    def test_valid_comma_separated_pass_trailer_and_ratios(self):
        results = summarize(self.root)
        self.assertEqual(len(results), 4)
        for row in results:
            self.assertEqual(row[0], "mixed")
            self.assertEqual(row[6:8], (2, 2))
            self.assertEqual(row[-1], 19)
            self.assertEqual(row[-4:], (0, 0, 0, 19))

    def test_redirect_created_empty_derived_csv_is_ignored(self):
        # Exact failure mode from native XPS and pinned LDC CI: the shell
        # creates the destination file before Python validates raw cases.
        (self.root / "OWNED_COMPARISON.csv").touch()
        self.assertEqual(len(summarize(self.root)), 4)

    def test_existing_derived_csv_contents_do_not_affect_raw_cases(self):
        (self.root / "OWNED_COMPARISON.csv").write_text(
            "pattern,layout,roi\\nfrom,earlier,analysis\\n")
        self.assertEqual(len(summarize(self.root)), 4)

    def test_unexpected_raw_csv_is_rejected(self):
        (self.root / "surprise.csv").write_text("")
        with self.assertRaisesRegex(ValueError, "unexpected/missing raw CSV"):
            summarize(self.root)

    def test_derived_csv_must_not_be_in_checksum_manifest(self):
        path = self.root / "OWNED_COMPARISON.csv"
        path.touch()
        with (self.root / "CHECKSUMS.sha256").open("a") as manifest:
            manifest.write(f"{hashlib.sha256(path.read_bytes()).hexdigest()}"
                           f"  ./OWNED_COMPARISON.csv\\n")
        with self.assertRaisesRegex(ValueError, "unexpected checksum manifest path"):
            summarize(self.root)

    def test_missing_pass_marker_rejected_even_with_updated_hash(self):
        name = self.names[("planar", 16)]
        rows = self.read_rows(name)
        rows[-1] = ["OWNED-BENCH FAIL: no correct results"]
        self.write_rows(name, rows)
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "PASS marker"):
            summarize(self.root)

    def test_duplicate_stage_rejected_even_with_valid_manifest(self):
        name = self.names[("interleaved", 64)]
        rows = self.read_rows(name)
        rows[2] = rows[1]
        self.write_rows(name, rows)
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "duplicate round/stage"):
            summarize(self.root)

    def test_checksum_violation_detected(self):
        name = self.names[("planar", 64)]
        rows = self.read_rows(name)
        rows[3][11] = "987654"
        self.write_rows(name, rows)
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            summarize(self.root)
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "checksum disagreement"):
            summarize(self.root)

    def test_cross_layout_checksum_violation(self):
        name = self.names[("planar", 64)]
        rows = self.read_rows(name)
        for row in rows[1:-1]:
            row[11] = "99887766"
        self.write_rows(name, rows)
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "differs between source layouts"):
            summarize(self.root)


if __name__ == "__main__":
    unittest.main()
