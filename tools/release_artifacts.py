"""Verify released documentation/source bytes before extracting them."""
import hashlib
from pathlib import Path, PurePosixPath
import tarfile


def verify_dependencies(description: dict, baseline: dict, configuration: str,
                        excluded=("imagery-d",)) -> dict:
    actual = {}
    for package in description["packages"]:
        name, version = package["name"], package["version"]
        if name in excluded:
            continue
        if name in actual and actual[name] != version:
            raise ValueError("multiple resolved versions: " + name)
        actual[name] = version
    expected = baseline["configurations"].get(configuration)
    if expected is None or actual != expected:
        raise ValueError("resolved dependencies differ from qualified " + configuration +
                         " baseline; requalify before publication")
    return dict(sorted(actual.items()))


def verify_checksum(archive: Path, manifest: Path) -> None:
    matching = []
    for line in manifest.read_text().splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2 and fields[1].lstrip("*") == archive.name:
            matching.append(fields[0])
    if (len(matching) != 1 or
            hashlib.sha256(archive.read_bytes()).hexdigest() != matching[0]):
        raise ValueError("missing, ambiguous or incorrect archive checksum: " + archive.name)


def extract_archive(archive: Path, target: Path) -> None:
    with tarfile.open(archive) as stream:
        for member in stream.getmembers():
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or
                    not (member.isfile() or member.isdir())):
                raise ValueError("unsupported or escaping archive member: " + member.name)
        stream.extractall(target, filter="data")
