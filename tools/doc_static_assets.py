#!/usr/bin/env python3
"""Install pinned DDox resources and reject broken local HTML/CSS assets."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import shutil
from urllib.parse import unquote, urlsplit

BUNDLE = Path(__file__).resolve().parent / "ddox-static"
REQUIRED = ("styles/ddox.css", "prettify/prettify.css",
            "scripts/jquery.js", "scripts/ddox.js")


def install(site: Path) -> None:
    """Add missing resources without replacing any released file."""
    manifest = json.loads((BUNDLE / "manifest.json").read_text())
    sources = []
    for name, digest in manifest["files"].items():
        source = BUNDLE / "public" / name
        if not source.resolve().is_relative_to((BUNDLE / "public").resolve()):
            raise ValueError("resource escapes bundle: " + name)
        if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise ValueError("DDox resource checksum mismatch: " + name)
        target = site / name
        if not target.resolve().is_relative_to(site.resolve()):
            raise ValueError("resource escapes site: " + name)
        sources.append((source, target))
    for source, target in sources:
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)


class Resources(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and "stylesheet" in attrs.get("rel", "").split():
            self.urls.append(attrs.get("href", ""))
        elif tag in {"script", "img"} and "src" in attrs:
            self.urls.append(attrs["src"])


def verify(site: Path) -> int:
    site = site.resolve()

    def resource(owner, url):
        parsed = urlsplit(url)
        if parsed.scheme or parsed.netloc:
            return  # External/data resources are not local file requests.
        target = (owner.parent / unquote(parsed.path)).resolve()
        if (not parsed.path or not target.is_relative_to(site)
                or not target.is_file() or not target.stat().st_size):
            raise ValueError(f"missing local resource: {owner.relative_to(site)} -> {url}")

    for name in REQUIRED:
        resource(site / "index.html", name)
    pages = list(site.rglob("*.html"))
    if not (site / "index.html").is_file():
        raise ValueError("documentation has no index.html")
    for page in pages:
        parser = Resources()
        parser.feed(page.read_text())
        for url in parser.urls:
            resource(page, url)
    for css in site.rglob("*.css"):
        # CSS image references resolve relative to the stylesheet, not the page.
        for match in re.finditer(r"url\(\s*(['\"]?)(.*?)\1\s*\)", css.read_text()):
            resource(css, match[2])
    return len(pages)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("site", type=Path)
    args = parser.parse_args()
    if args.install:
        install(args.site)
    print(f"DOC_STATIC_ASSETS=PASS; pages={verify(args.site)}")
