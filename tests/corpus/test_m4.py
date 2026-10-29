"""M4 offline fixture invariants and failure-path regression."""
import copy
import importlib.util
import json
import pathlib
import struct
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "m4_corpus", ROOT / "tools/verify-m4-corpus.py")
m4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m4)
MANIFEST = json.loads((ROOT / "tests/corpus/m4-v1.json").read_text())


class CorpusTests(unittest.TestCase):
    def test_all_fixture_digests_and_seam_law(self):
        self.assertEqual(len(m4.verify_manifest(MANIFEST)), 7)

    def test_corruption_detected(self):
        bad = copy.deepcopy(MANIFEST)
        bad["fixtures"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            m4.verify_manifest(bad)

    def test_unsafe_and_duplicate_ids_rejected(self):
        for name in ("../escape", "abc/def", "abc\\def", "rgb-seam-right"):
            bad = copy.deepcopy(MANIFEST)
            bad["fixtures"][0]["id"] = name
            with self.assertRaises(ValueError):
                m4.verify_manifest(bad)

    def test_seam_geometry_error_rejected(self):
        bad = copy.deepcopy(MANIFEST)
        bad["relations"][0]["right"] = "rgb-roi"
        with self.assertRaisesRegex(ValueError, "geometry"):
            m4.verify_manifest(bad)

    def test_mask_strengths(self):
        self.assertEqual(set(m4.verify_manifest(MANIFEST)["mask-selection"]),
                         {0, 128, 255})

    def test_little_endian_u16(self):
        data = m4.verify_manifest(MANIFEST)["science-u16"]
        self.assertEqual(data[:2], struct.pack("<H",
                         (257 * 11 + 4099 * 7 + 11) % 65536))

    def test_exact_float32_bytes(self):
        data = m4.verify_manifest(MANIFEST)["science-f32"]
        self.assertEqual(data[:4], struct.pack("<f",
                         ((7 * 11 + 11 * 7) % 128) / 128.0))

    def test_fixture_byte_budget(self):
        bad = copy.deepcopy(MANIFEST["fixtures"][0])
        bad["width"], bad["height"] = 4096, 4096
        with self.assertRaisesRegex(ValueError, "16 MiB"):
            m4.fixture_bytes(bad)


if __name__ == "__main__":
    unittest.main()
