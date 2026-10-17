#!/usr/bin/env python3
"""Regression tests for the CSV-parsed hotpath PASS trailer."""

import csv
import unittest

from summarize_m3_rgba_buffered_micro import require_pass_trailer


class HotpathPassTrailerTests(unittest.TestCase):
    @staticmethod
    def parsed(line):
        return next(csv.reader([line]))

    def test_comma_separated_real_trailer(self):
        fields = self.parsed(
            "HOTPATH-STAGES PASS: all pixels match canonical RGBA, "
            "all timed stages zero current-thread GC bytes, "
            "prepared_init_us=18"
        )
        self.assertEqual(len(fields), 3)
        require_pass_trailer(fields, "synthetic.csv")

    def test_single_field_trailer_is_supported(self):
        require_pass_trailer(
            self.parsed("HOTPATH-STAGES PASS: prepared_init_us=0"),
            "synthetic.csv",
        )

    def test_missing_trailer_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing or malformed PASS"):
            require_pass_trailer([], "synthetic.csv")

    def test_wrong_marker_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing or malformed PASS"):
            require_pass_trailer(
                self.parsed("HOTPATH-STAGES FAIL: incorrect output, "
                            "prepared_init_us=18"),
                "synthetic.csv",
            )

    def test_missing_preparation_field_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing or malformed PASS"):
            require_pass_trailer(
                self.parsed("HOTPATH-STAGES PASS: all pixels match canonical RGBA, "
                            "all timed stages zero current-thread GC bytes"),
                "synthetic.csv",
            )


if __name__ == "__main__":
    unittest.main()
