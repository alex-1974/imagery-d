#!/usr/bin/env python3
"""Consume downloaded source-release bytes without modifying their manifest."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from release_artifacts import extract_archive, verify_checksum, verify_dependencies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--checksums", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--compiler", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        raise ValueError("expected exact release version")
    verify_checksum(args.archive, args.checksums)
    fixture = Path(__file__).resolve().parent.parent / "tests/archive_consumer/source/app.d"
    baseline = json.loads((Path(__file__).resolve().parent.parent /
                           "docs/release/DEPENDENCIES-0.4.0.json").read_text())
    with tempfile.TemporaryDirectory(prefix="imagery-published-consumer-") as directory:
        scratch = Path(directory)
        sources = scratch / "extracted"
        extract_archive(args.archive, sources)
        package = sources / ("imagery-d-v" + args.version)
        if not (package / "dub.sdl").is_file() or len(list(sources.iterdir())) != 1:
            raise ValueError("unexpected source release root")
        manifest_bytes = (package / "dub.sdl").read_bytes()
        consumer = scratch / "consumer"
        (consumer / "source").mkdir(parents=True)
        shutil.copy2(fixture, consumer / "source/app.d")
        (consumer / "dub.json").write_text(json.dumps({
            "name": "imagery-published-source-consumer", "targetType": "executable",
            "dependencies": {"imagery-d": {"path": str(package)}},
            "configurations": [{"name": config,
                                "subConfigurations": {"imagery-d": config}}
                               for config in ("default", "no-io")],
        }, indent=2))
        for config in ("default", "no-io"):
            result = subprocess.run(["dub", "run", "--root=" + str(consumer),
                                     "--compiler=" + args.compiler, "--build=release",
                                     "--config=" + config, "--force"],
                                    check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True)
            print(result.stdout, flush=True)
            result.check_returncode()
            if "M3_LEVELS_ARCHIVED_EXTERNAL=PASS;" not in result.stdout:
                raise ValueError("missing published-source consumer success receipt")
            if (package / "dub.sdl").read_bytes() != manifest_bytes:
                raise ValueError("consumer changed the shipped dependency manifest")
            description = json.loads(subprocess.check_output([
                "dub", "describe", "--root=" + str(consumer),
                "--compiler=" + args.compiler, "--config=" + config], text=True))
            verify_dependencies(description, baseline, config,
                                excluded=("imagery-d", "imagery-published-source-consumer"))
    print("PUBLISHED_SOURCE_CONSUMER=PASS; default and no-io, unmodified downloaded source")


if __name__ == "__main__":
    main()
