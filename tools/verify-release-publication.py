#!/usr/bin/env python3
"""Fail closed before publishing a version tag; never create or move refs."""
from __future__ import annotations

import argparse
from datetime import date
import json
from pathlib import Path
import re
import subprocess

WORKFLOWS = {
    "ci.yml", "release-gate.yml", "feature-program.yml",
    "m3-levels-candidate.yml", "release-readiness.yml",
    "release-qualification.yml",
    "release-publication-check.yml",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def verify_identity(root: Path, version: str, tag: str, api: str,
                    feature: str, main: str) -> str:
    require(re.fullmatch(r"\d+\.\d+\.\d+", version) is not None,
            "expected an exact release version")
    require(subprocess.run(["git", "diff", "--quiet", "HEAD", "--"],
                           cwd=root, check=False).returncode == 0,
            "tracked checkout differs from the release commit")
    for name, ref in (("release", tag), ("API freeze", api),
                      ("feature freeze", feature)):
        require(git(root, "cat-file", "-t", ref) == "tag",
                f"{name} must be an annotated tag")
    commit = git(root, "rev-parse", tag + "^{commit}")
    require(commit == git(root, "rev-parse", "HEAD"), "tag differs from checkout")
    require(commit == git(root, "rev-parse", main + "^{commit}"),
            "release tag must target the exact current main commit")
    for older, newer in ((feature, api), (api, tag)):
        require(subprocess.run(["git", "merge-base", "--is-ancestor",
                                older + "^{commit}", newer + "^{commit}"],
                               cwd=root, check=False).returncode == 0,
                "feature/API/release checkpoint ancestry is inconsistent")
    changelog = (root / "CHANGELOG.md").read_text()
    legacy = re.findall(r"^## v" + re.escape(version) + r"\s+—\s+.+$",
                        changelog, re.MULTILINE)
    dated = re.findall(r"^## \[" + re.escape(version) + r"\] - (\d{4}-\d{2}-\d{2})$",
                       changelog, re.MULTILINE)
    require(len(legacy) + len(dated) == 1,
            "changelog needs exactly one finalized version section")
    for published in dated:
        date.fromisoformat(published)
    require(not re.search(r"^## Unreleased[^\n]*\bv" + re.escape(version) + r"\b",
                          changelog, re.MULTILINE),
            "candidate changelog is not finalized")
    notes = root / "docs" / "release" / f"NOTES-{version}.md"
    require(notes.is_file() and notes.read_text().startswith(f"# imagery-d v{version}\n"),
            "versioned release notes are missing or inconsistent")
    return commit


def select_promotion(pulls: list[dict], commit: str, repository: str,
                     version: str) -> dict:
    release_branch = "release/" + ".".join(version.split(".")[:2])
    selected = [p for p in pulls if p.get("merged_at")
                and p.get("merge_commit_sha") == commit
                and p.get("base", {}).get("ref") == "main"
                and p.get("head", {}).get("ref") == release_branch
                and p.get("head", {}).get("repo", {}).get("full_name") == repository]
    require(len(selected) == 1, "need one merged promotion PR from the release branch")
    return selected[0]


def review_disposition(review: dict, version: str, policy: dict | None = None) -> dict:
    require(re.fullmatch(r"\d+\.\d+\.\d+", version) is not None,
            "expected an exact release version")
    require(review.get("number") == 220, "missing review #220 tracker")
    if review.get("state") == "closed" and review.get("state_reason") == "completed":
        return {"status": "completed", "tracking_issue": 220}
    if int(version.split(".")[0]) == 0 and policy:
        require(policy.get("tracking_issue") == 220
                and policy.get("independent_readability_review") == "waived"
                and policy.get("scope") == "pre-1.0"
                and policy.get("required_from") == "1.0.0"
                and all(isinstance(policy.get(k), str) and policy[k].strip()
                        for k in ("authority", "decision_date", "decision")),
                "invalid pre-1.0 readability-review waiver")
        return {"status": "waived-pre-1.0", "policy": policy}
    raise ValueError("independent readability review #220 is not completed")


def verify_checks(runs: list[dict], head: str, repository: str,
                  review: dict, *, version: str = "1.0.0", policy: dict | None = None) -> dict:
    review_disposition(review, version, policy)
    latest: dict[str, dict] = {}
    for run in runs:
        if (run.get("head_sha") != head or run.get("event") != "pull_request"
                or run.get("head_repository", {}).get("full_name") != repository):
            continue
        path = run.get("path", "")
        if not path.startswith(".github/workflows/"):
            continue
        name = path.removeprefix(".github/workflows/")
        if name in WORKFLOWS and run["id"] > latest.get(name, {}).get("id", -1):
            latest[name] = run
    require(WORKFLOWS <= latest.keys(),
            "missing exact-head workflows: " + ", ".join(sorted(WORKFLOWS - latest.keys())))
    for name, run in latest.items():
        require(run.get("status") == "completed" and run.get("conclusion") == "success",
                f"latest exact-head workflow is not green: {name}")
    return {name: {k: run.get(k) for k in
                   ("id", "run_attempt", "html_url", "head_sha", "conclusion")}
            for name, run in sorted(latest.items())}


def gh_json(route: str) -> object:
    return json.loads(subprocess.check_output(["gh", "api", route], text=True))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag-ref", required=True)
    parser.add_argument("--api-ref", required=True)
    parser.add_argument("--feature-ref", required=True)
    parser.add_argument("--main-ref", default="refs/remotes/origin/main")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    commit = verify_identity(root, args.version, args.tag_ref, args.api_ref,
                             args.feature_ref, args.main_ref)
    prefix = f"repos/{args.repository}"
    pulls = gh_json(f"{prefix}/commits/{commit}/pulls?per_page=100")
    promotion = select_promotion(pulls, commit, args.repository, args.version)
    head = promotion["head"]["sha"]
    parents = git(root, "rev-list", "--parents", "-n", "1", commit).split()[1:]
    require(len(parents) == 2 and parents[1] == head,
            "release must be a regular promotion merge with the qualified head")
    # Fetch the qualified head if checkout's fetch did not retain that object.
    subprocess.run(["git", "fetch", "--no-tags", "origin", head], cwd=root, check=True)
    require(git(root, "rev-parse", head + "^{tree}") ==
            git(root, "rev-parse", commit + "^{tree}"),
            "main tree differs from the qualified promotion head")
    result = gh_json(f"{prefix}/actions/runs?head_sha={head}&event=pull_request&per_page=100")
    require(result["total_count"] <= len(result["workflow_runs"]),
            "workflow evidence is paginated; collect all pages before publishing")
    review = gh_json(f"{prefix}/issues/220")
    policy = json.loads((root / "docs/release/REVIEW-POLICY.json").read_text())
    checks = verify_checks(result["workflow_runs"], head, args.repository, review,
                           version=args.version, policy=policy)
    # Preserve the actual issue state and the explicit pre-1.0 exception.
    # A waiver is not represented as a performed independent review.
    args.output.write_text(json.dumps({
        "version": args.version, "release_commit": commit,
        "qualified_head": head, "promotion_pr": promotion["number"],
        "review": {k: review.get(k) for k in
                   ("number", "state", "state_reason", "closed_at", "html_url")},
        "review_disposition": review_disposition(review, args.version, policy),
        "workflows": checks,
    }, indent=2) + "\n")
    print("RELEASE_PUBLICATION_PREFLIGHT=PASS")


if __name__ == "__main__":
    main()
