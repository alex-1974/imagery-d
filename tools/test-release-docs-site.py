#!/usr/bin/env python3
"""Check artifact integrity, extraction and immutable version preservation."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from release_artifacts import extract_archive, verify_checksum, verify_dependencies
import doc_static_assets

spec = importlib.util.spec_from_file_location(
    "docs_site", Path(__file__).with_name("build-release-docs-site.py"))
docs_site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docs_site)


def archive(path, entries):
    with tarfile.open(path, "w:gz") as output:
        for name, content in entries:
            member = tarfile.TarInfo(name)
            if isinstance(content, bytes):
                member.size = len(content)
                output.addfile(member, io.BytesIO(content))
            else:
                member.type = content[0]
                member.linkname = "index.html"
                output.addfile(member)


class ArtifactContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="imagery-docs-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_dependency_snapshot_matches_and_ignores_only_consumer_roots(self):
        baseline = {"configurations": {"default": {"raster-d": "0.5.5"}}}
        description = {"packages": [{"name": "imagery-d", "version": "~master"},
                                    {"name": "raster-d", "version": "0.5.5"}]}
        self.assertEqual(verify_dependencies(description, baseline, "default"), {"raster-d": "0.5.5"})
        with self.assertRaises(ValueError):
            verify_dependencies(description, baseline, "no-io")

    def test_dependency_upgrade_missing_or_additional_package_requires_requalification(self):
        baseline = {"configurations": {"default": {"raster-d": "0.5.5"}}}
        for packages in ([{"name": "raster-d", "version": "0.5.6"}], [],
                         [{"name": "raster-d", "version": "0.5.5"},
                          {"name": "extra", "version": "1.0.0"}]):
            with self.assertRaisesRegex(ValueError, "requalify"):
                verify_dependencies({"packages": packages}, baseline, "default")

    def test_conflicting_resolved_package_versions_are_rejected(self):
        packages = [{"name": "raster-d", "version": version} for version in ("0.5.5", "0.5.6")]
        with self.assertRaisesRegex(ValueError, "multiple resolved"):
            verify_dependencies({"packages": packages}, {"configurations": {}}, "default")

    def test_checksum_rejects_missing_duplicate_and_corrupted_entries(self):
        source = self.root / "docs.tar.gz"
        source.write_bytes(b"approved bytes")
        manifest = self.root / "checksums"
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        manifest.write_text(digest + "  docs.tar.gz\n")
        verify_checksum(source, manifest)
        for text in (digest + "  other.tar.gz\n", (digest + "  docs.tar.gz\n") * 2,
                     "0" * 64 + "  docs.tar.gz\n"):
            manifest.write_text(text)
            with self.assertRaises(ValueError):
                verify_checksum(source, manifest)

    def test_extract_rejects_traversal_absolute_links_and_devices(self):
        source = self.root / "bad.tar.gz"
        for name, value in (("../outside", b"bad"), ("/absolute", b"bad"),
                            ("link", (tarfile.SYMTYPE,)), ("hard", (tarfile.LNKTYPE,)),
                            ("device", (tarfile.CHRTYPE,))):
            archive(source, [(name, value)])
            with self.assertRaises(ValueError):
                extract_archive(source, self.root / "unpacked")
        self.assertFalse((self.root / "outside").exists())

    def test_published_versions_preserve_bytes_and_stable_uses_latest(self):
        releases = []
        assets = {}
        for version, old_checksum_name in (("v0.4.0", False), ("v0.2.0", True)):
            name = f"imagery-d-{version}-ddox.tar.gz"
            checksum = f"imagery-d-{version}" + ("-ddox" if old_checksum_name else "") + ".sha256"
            source = self.root / name
            archive(source, [("index.html", (f"<body>{version}</body>").encode()),
                             ("imagery/Levels.html", b"reference")])
            manifest = self.root / checksum
            manifest.write_text(hashlib.sha256(source.read_bytes()).hexdigest() + "  " + name + "\n")
            assets[version] = (source, manifest)
            releases.append({"tag_name": version, "assets": [{"name": name}, {"name": checksum}]})

        def fetch(route):
            return {"tag_name": "v0.4.0"} if route.endswith("/latest") else releases

        def download(args, check):
            self.assertTrue(check)
            target = Path(args[args.index("--dir") + 1])
            target.mkdir()
            for source in assets[args[3]]:
                shutil.copy2(source, target / source.name)

        output = self.root / "site"
        with patch.object(docs_site, "gh_json", side_effect=fetch), \
                patch.object(docs_site.subprocess, "run", side_effect=download):
            docs_site.build("example/repo", "v0.4.0", output)
        self.assertEqual((output / "v0.2.0/index.html").read_text(), "<body>v0.2.0</body>")
        self.assertEqual((output / "v0.4.0/index.html").read_text(), "<body>v0.4.0</body>")
        self.assertIn('href="v0.4.0/index.html"', (output / "index.html").read_text())
        self.assertEqual(json.loads((output / "versions.json").read_text())["versions"],
                         ["v0.4.0", "v0.2.0"])
        for prefix in ("", "v0.4.0/", "v0.2.0/"):
            for resource in doc_static_assets.REQUIRED:
                self.assertTrue((output / prefix / resource).is_file())
        doc_static_assets.verify(output)

    def static_site(self):
        site = self.root / "static"
        doc_static_assets.install(site)
        (site / "symbols.js").write_text("var symbols = [];")
        (site / "index.html").write_text(
            '<link rel="stylesheet" href="styles/ddox.css">'
            '<script src="scripts/ddox.js"></script><script src="symbols.js"></script>')
        nested = site / "imagery/analysis/Example.html"
        nested.parent.mkdir(parents=True)
        nested.write_text('<link rel="stylesheet" href="../../styles/ddox.css">'
                          '<script src="../../scripts/jquery.js"></script>')
        return site

    def test_nested_pages_and_stylesheet_images_resolve(self):
        self.assertEqual(doc_static_assets.verify(self.static_site()), 2)

    def test_missing_styles_scripts_and_css_images_are_rejected(self):
        site = self.static_site()
        for name in ("styles/ddox.css", "scripts/jquery.js", "symbols.js",
                     "images/ddox/module.png"):
            with self.subTest(name=name):
                target = site / name
                content = target.read_bytes()
                target.unlink()
                with self.assertRaisesRegex(ValueError, "missing local resource"):
                    doc_static_assets.verify(site)
                target.write_bytes(content)

    def test_unbundled_and_escaping_resource_links_are_rejected(self):
        site = self.static_site()
        for target in ("styles/missing.css", "../outside.css"):
            (site / "index.html").write_text(f'<link rel="stylesheet" href="{target}">')
            with self.assertRaisesRegex(ValueError, "missing local resource"):
                doc_static_assets.verify(site)

    def test_repair_preserves_existing_assets_and_license_notices(self):
        site = self.static_site()
        css = site / "styles/ddox.css"
        css.write_text("/* Previously published custom styling */")
        doc_static_assets.install(site)
        self.assertEqual(css.read_text(), "/* Previously published custom styling */")
        self.assertIn("Permission is hereby granted", (site / "LICENSE-DDOX.txt").read_text())
        self.assertIn("Permission is hereby granted", (site / "LICENSE-JQUERY.txt").read_text())

    def test_corrupted_bundle_is_rejected_before_installation(self):
        bundle = self.root / "bundle"
        shutil.copytree(doc_static_assets.BUNDLE, bundle)
        (bundle / "public/styles/ddox.css").write_text("corrupt")
        target = self.root / "unpublished"
        with patch.object(doc_static_assets, "BUNDLE", bundle):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                doc_static_assets.install(target)
        self.assertFalse(target.exists())

    def test_future_incomplete_release_is_not_silently_repaired(self):
        tag = "v0.4.1"
        name = f"imagery-d-{tag}-ddox.tar.gz"
        checksum = f"imagery-d-{tag}.sha256"
        source = self.root / name
        archive(source, [("index.html", b"<body>New release without resources</body>")])
        manifest = self.root / checksum
        manifest.write_text(hashlib.sha256(source.read_bytes()).hexdigest() + "  " + name + "\n")
        release = {"tag_name": tag, "assets": [{"name": name}, {"name": checksum}]}

        def fetch(route):
            return release if route.endswith("/latest") else [release]

        def download(args, check):
            target = Path(args[args.index("--dir") + 1])
            target.mkdir()
            for path in (source, manifest):
                shutil.copy2(path, target / path.name)

        with patch.object(docs_site, "gh_json", side_effect=fetch), \
                patch.object(docs_site.subprocess, "run", side_effect=download):
            with self.assertRaisesRegex(ValueError, "missing local resource"):
                docs_site.build("example/repo", tag, self.root / "site")

    def test_outdated_release_cannot_replace_stable_docs(self):
        with patch.object(docs_site, "gh_json", return_value={"tag_name": "v0.4.1"}):
            with self.assertRaisesRegex(ValueError, "non-latest"):
                docs_site.build("example/repo", "v0.4.0", self.root / "site")


if __name__ == "__main__":
    unittest.main()
