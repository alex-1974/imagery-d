#!/usr/bin/env python3
"""Exercise release rejection paths without GitHub writes or real version tags."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "publication", Path(__file__).with_name("verify-release-publication.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
REPOSITORY = "example/imagery-d"
HEAD = "a" * 40


class Evidence(unittest.TestCase):
    def setUp(self):
        self.review = {"number": 220, "state": "closed", "state_reason": "completed"}
        self.runs = [{"id": i, "path": ".github/workflows/" + name,
                      "head_sha": HEAD, "event": "pull_request",
                      "head_repository": {"full_name": REPOSITORY},
                      "status": "completed", "conclusion": "success"}
                     for i, name in enumerate(sorted(publication.WORKFLOWS), 1)]

    def check(self):
        return publication.verify_checks(self.runs, HEAD, REPOSITORY, self.review)

    def test_all_required_checks(self):
        self.assertEqual(len(self.check()), 7)

    def test_unfinished_or_deferred_review(self):
        for state, reason in (("open", None), ("closed", "not_planned")):
            self.review.update(state=state, state_reason=reason)
            with self.assertRaisesRegex(ValueError, "review #220"):
                self.check()

    def waiver(self):
        return {"tracking_issue": 220, "independent_readability_review": "waived",
                "scope": "pre-1.0", "required_from": "1.0.0",
                "authority": "maintainer fixture", "decision_date": "2026-11-24",
                "decision": "Skip the independent review before 1.0"}

    def test_explicit_pre_1_0_waiver_preserves_open_review_state(self):
        self.review.update(state="open", state_reason=None)
        for version in ("0.4.0", "0.9.99"):
            checks = publication.verify_checks(self.runs, HEAD, REPOSITORY, self.review,
                                               version=version, policy=self.waiver())
            self.assertEqual(len(checks), 7)
            disposition = publication.review_disposition(self.review, version, self.waiver())
            self.assertEqual(disposition["status"], "waived-pre-1.0")
            self.assertEqual(self.review["state"], "open")

    def test_waiver_never_applies_at_or_after_1_0(self):
        self.review.update(state="open", state_reason=None)
        for version in ("1.0.0", "1.0.1", "2.0.0"):
            with self.assertRaisesRegex(ValueError, "review #220"):
                publication.verify_checks(self.runs, HEAD, REPOSITORY, self.review,
                                           version=version, policy=self.waiver())

    def test_pre_1_0_requires_an_explicit_complete_policy(self):
        self.review.update(state="open", state_reason=None)
        for policy in (None, {}, dict(self.waiver(), scope="all releases"),
                       dict(self.waiver(), authority=""), dict(self.waiver(), tracking_issue=1)):
            with self.assertRaises(ValueError):
                publication.verify_checks(self.runs, HEAD, REPOSITORY, self.review,
                                           version="0.4.0", policy=policy)

    def test_waiver_does_not_waive_failed_workflows(self):
        self.review.update(state="open", state_reason=None)
        self.runs[0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "not green"):
            publication.verify_checks(self.runs, HEAD, REPOSITORY, self.review,
                                       version="0.4.0", policy=self.waiver())

    def test_foreign_head_repository_or_event_cannot_fill_a_gate(self):
        for field, value in (("head_sha", "b" * 40),
                             ("head_repository", {"full_name": "fork/imagery-d"}),
                             ("event", "push")):
            with self.subTest(field=field):
                runs = copy.deepcopy(self.runs)
                runs[0][field] = value
                with self.assertRaisesRegex(ValueError, "missing exact-head"):
                    publication.verify_checks(runs, HEAD, REPOSITORY, self.review)

    def test_older_success_does_not_hide_newer_failure_or_pending_run(self):
        for status, conclusion in (("completed", "failure"), ("in_progress", None)):
            newer = dict(self.runs[0], id=100, status=status, conclusion=conclusion)
            with self.assertRaisesRegex(ValueError, "not green"):
                publication.verify_checks(self.runs + [newer], HEAD, REPOSITORY, self.review)

    def test_unmerged_or_wrong_promotion(self):
        correct = {"number": 1, "merged_at": "2026-11-24", "merge_commit_sha": HEAD,
                   "base": {"ref": "main"},
                   "head": {"ref": "release/0.4", "repo": {"full_name": REPOSITORY}}}
        self.assertEqual(publication.select_promotion([correct], HEAD, REPOSITORY, "0.4.0"), correct)
        for field, value in (("merged_at", None), ("merge_commit_sha", "b" * 40),
                             ("base", {"ref": "develop"})):
            with self.assertRaises(ValueError):
                publication.select_promotion([dict(correct, **{field: value})], HEAD,
                                             REPOSITORY, "0.4.0")


class Identity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="imagery-publication-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release gate fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        (self.root / "CHANGELOG.md").write_text("## v0.4.0 — Fixture\n")
        notes = self.root / "docs/release/NOTES-0.4.0.md"
        notes.parent.mkdir(parents=True)
        notes.write_text("# imagery-d v0.4.0\n\nFixture.\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        for name in ("feature", "api", "release"):
            self.git("tag", "-a", name, "-m", name)
        self.git("branch", "main")

    def git(self, *args):
        return publication.git(self.root, *args)

    def check(self):
        return publication.verify_identity(self.root, "0.4.0", "release", "api", "feature", "main")

    def test_annotated_exact_main_with_ordered_checkpoints(self):
        self.assertEqual(self.check(), self.git("rev-parse", "HEAD"))

    def test_dated_changelog_with_unreleased_work(self):
        (self.root / "CHANGELOG.md").write_text(
            "## [Unreleased]\n\n### Changed\n\n- Next work.\n\n"
            "## [0.4.0] - 2026-11-24\n\n### Added\n\n- Fixture.\n")
        self.publish_fixture_change()
        self.assertEqual(self.check(), self.git("rev-parse", "HEAD"))

    def test_duplicate_and_invalid_dated_changelog(self):
        for text in ("## [0.4.0] - 2026-11-24\n## v0.4.0 — Duplicate\n",
                     "## [0.4.0] - 2026-02-30\n",
                     "## [0.4.0] - tomorrow\n"):
            with self.subTest(text=text):
                (self.root / "CHANGELOG.md").write_text(text)
                self.publish_fixture_change()
                with self.assertRaises(ValueError):
                    self.check()

    def test_lightweight_release_or_api_checkpoint(self):
        for name in ("release", "api", "feature"):
            self.git("tag", "-d", name)
            self.git("tag", name)
            with self.assertRaisesRegex(ValueError, "annotated"):
                self.check()
            self.git("tag", "-d", name)
            self.git("tag", "-a", name, "-m", name)

    def test_tag_not_at_current_main(self):
        self.git("commit", "--allow-empty", "-qm", "later main")
        self.git("branch", "-f", "main", "HEAD")
        self.git("checkout", "-q", "release^{commit}")
        with self.assertRaisesRegex(ValueError, "current main"):
            self.check()

    def test_unfinalized_changelog_or_missing_notes(self):
        p = self.root / "CHANGELOG.md"
        p.write_text("## Unreleased — v0.4.0 candidate\n")
        self.publish_fixture_change()
        with self.assertRaisesRegex(ValueError, "finalized"):
            self.check()
        p.write_text("## v0.4.0 — Fixture\n")
        (self.root / "docs/release/NOTES-0.4.0.md").unlink()
        self.publish_fixture_change()
        with self.assertRaisesRegex(ValueError, "release notes"):
            self.check()

    def publish_fixture_change(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture change")
        self.git("branch", "-f", "main", "HEAD")
        self.git("tag", "-f", "-a", "release", "-m", "fixture release")

    def test_dirty_checkout_is_not_the_release_artifact(self):
        (self.root / "CHANGELOG.md").write_text("uncommitted content\n")
        with self.assertRaisesRegex(ValueError, "checkout differs"):
            self.check()

    def test_api_checkpoint_cannot_follow_the_release(self):
        original = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "later API checkpoint")
        self.git("tag", "-f", "-a", "api", "-m", "later API")
        self.git("checkout", "-q", original)
        with self.assertRaisesRegex(ValueError, "ancestry"):
            self.check()


if __name__ == "__main__":
    unittest.main()
