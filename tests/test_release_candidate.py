#!/usr/bin/env python3
"""Deterministic tests for tools/release_candidate.py; GitHub is always mocked."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import release_candidate as rc  # noqa: E402

TAG = rc.release_tag()
REPO = "ChrisLauinger77/mpris-miniplayer"
COMMIT = "a" * 40
RUN_ID = 4242
WORKFLOW_ID = 77
TAG_SHA = "b" * 40
ENV = {
    "RELEASE_TAG": TAG,
    "GH_REPO": REPO,
    "GITHUB_SHA": COMMIT,
    "GITHUB_RUN_ID": "9999",
    "DEFAULT_BRANCH": "main",
}


def good_run():
    return {
        "id": RUN_ID,
        "event": "workflow_dispatch",
        "status": "completed",
        "conclusion": "success",
        "head_sha": COMMIT,
        "head_branch": "main",
        "path": rc.WORKFLOW_PATH,
        "workflow_id": WORKFLOW_ID,
        "run_attempt": 1,
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
    }


def good_artifact(**changes):
    artifact = {
        "id": 555,
        "name": rc.ARTIFACT_NAME,
        "expired": False,
        "size_in_bytes": 1234,
        "workflow_run": {"id": RUN_ID, "head_sha": COMMIT},
    }
    artifact.update(changes)
    return artifact


class FakeGitHub:
    """Answers the REST endpoints used by resolve() and publish()."""

    def __init__(self, message=f"MPRIS MiniPlayer {TAG[1:]}\n\nCandidate-Run: {RUN_ID}\n"):
        self.ref = {"object": {"type": "tag", "sha": TAG_SHA}}
        self.tag = {"tag": TAG, "message": message, "object": {"type": "commit", "sha": COMMIT}}
        self.run = good_run()
        self.artifacts = [good_artifact()]
        self.release = None
        self.calls = []

    def __call__(self, endpoint, *args):
        self.calls.append((endpoint, args))
        if endpoint == f"repos/{REPO}/git/ref/tags/{TAG}":
            return self.ref
        if endpoint == f"repos/{REPO}/git/tags/{TAG_SHA}":
            return self.tag
        if endpoint == f"repos/{REPO}/actions/runs/{ENV['GITHUB_RUN_ID']}":
            return {"workflow_id": WORKFLOW_ID}
        if endpoint == f"repos/{REPO}/actions/runs/{RUN_ID}":
            return self.run
        if endpoint.startswith(f"repos/{REPO}/actions/runs/{RUN_ID}/artifacts"):
            return [{"artifacts": self.artifacts}]
        if endpoint == f"repos/{REPO}/releases/1":
            return None if args else self.release
        raise subprocess.CalledProcessError(1, ["gh", "api", endpoint])


class CandidateDirectory(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dist = Path(self.tmp.name)
        for index, name in enumerate(rc.package_names(TAG)):
            (self.dist / name).write_bytes(f"package {index}".encode())


class VersionTests(unittest.TestCase):
    def test_candidate_version_comes_from_project_metadata(self):
        self.assertRegex(TAG, r"^v[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertEqual(rc.release_tag(TAG), TAG)

    def test_tag_version_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "disagree"):
            rc.release_tag("v0.0.0")

    def test_malformed_tag_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Invalid release tag"):
            rc.release_tag(TAG[1:])

    def test_package_names_are_unchanged(self):
        self.assertEqual(rc.package_names("v1.2.3"), [
            "MPRIS-MiniPlayer-v1.2.3-x86_64.flatpak",
            "mpris-miniplayer_v1.2.3_amd64.deb",
            "mpris-miniplayer-v1.2.3.x86_64.rpm",
        ])


class TrailerTests(unittest.TestCase):
    def test_valid_trailer(self):
        self.assertEqual(rc.candidate_run_id("Title\n\nCandidate-Run: 123\n"), 123)

    def test_missing_trailer(self):
        with self.assertRaisesRegex(ValueError, "Candidate-Run"):
            rc.candidate_run_id("MPRIS MiniPlayer 1.0.0\n")

    def test_invalid_run_ids(self):
        for value in ("0", "-1", "12a", "", "1 2", "0123"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                rc.candidate_run_id(f"Title\n\nCandidate-Run: {value}\n")

    def test_duplicate_trailer(self):
        with self.assertRaises(ValueError):
            rc.candidate_run_id("Candidate-Run: 1\nCandidate-Run: 2\n")


class AggregateTests(CandidateDirectory):
    def test_aggregate_records_checksums_for_complete_set(self):
        rc.aggregate(self.dist, TAG)
        digests = rc.verify_assets(self.dist, TAG)
        self.assertEqual(sorted(digests), sorted(rc.package_names(TAG)))

    def test_aggregate_rejects_missing_package(self):
        (self.dist / rc.package_names(TAG)[2]).unlink()
        with self.assertRaisesRegex(ValueError, "exactly"):
            rc.aggregate(self.dist, TAG)

    def test_aggregate_rejects_unexpected_file(self):
        (self.dist / "extra.zip").write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "exactly"):
            rc.aggregate(self.dist, TAG)

    def test_aggregate_rejects_empty_package(self):
        (self.dist / rc.package_names(TAG)[0]).write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "empty"):
            rc.aggregate(self.dist, TAG)


class VerifyAssetTests(CandidateDirectory):
    def setUp(self):
        super().setUp()
        rc.aggregate(self.dist, TAG)

    def test_modified_package_is_rejected(self):
        (self.dist / rc.package_names(TAG)[1]).write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            rc.verify_assets(self.dist, TAG)

    def test_modified_checksum_file_is_rejected(self):
        sums = self.dist / rc.CHECKSUMS
        text = sums.read_text()
        sums.write_text(("1" if text[0] == "0" else "0") + text[1:])
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            rc.verify_assets(self.dist, TAG)

    def test_checksum_entry_missing_is_rejected(self):
        sums = self.dist / rc.CHECKSUMS
        sums.write_text("".join(sums.read_text().splitlines(keepends=True)[:2]))
        with self.assertRaisesRegex(ValueError, "must list exactly"):
            rc.verify_assets(self.dist, TAG)

    def test_missing_required_package_is_rejected(self):
        (self.dist / rc.package_names(TAG)[0]).unlink()
        with self.assertRaisesRegex(ValueError, "must contain exactly"):
            rc.verify_assets(self.dist, TAG)

    def test_missing_checksum_file_is_rejected(self):
        (self.dist / rc.CHECKSUMS).unlink()
        with self.assertRaisesRegex(ValueError, "must contain exactly"):
            rc.verify_assets(self.dist, TAG)

    def test_missing_download_directory_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "must contain exactly"):
            rc.verify_assets(self.dist / "absent", TAG)


class ResolveTests(unittest.TestCase):
    def resolve(self, github):
        with mock.patch.object(rc, "gh_api", github):
            return rc.resolve(ENV)

    def test_successful_candidate_resolution(self):
        self.assertEqual(self.resolve(FakeGitHub()), (RUN_ID, 555))

    def test_lightweight_tag_is_rejected(self):
        github = FakeGitHub()
        github.ref["object"]["type"] = "commit"
        with self.assertRaisesRegex(ValueError, "annotated"):
            self.resolve(github)

    def test_tag_on_other_commit_is_rejected(self):
        github = FakeGitHub()
        github.tag["object"]["sha"] = "c" * 40
        with self.assertRaisesRegex(ValueError, "Tag points at"):
            self.resolve(github)

    def test_missing_trailer_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Candidate-Run"):
            self.resolve(FakeGitHub(message="MPRIS MiniPlayer\n"))

    def test_unknown_run_is_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.resolve(FakeGitHub(message="Candidate-Run: 31337\n"))

    def test_version_mismatch_is_rejected(self):
        with mock.patch.object(rc, "gh_api", FakeGitHub()), self.assertRaisesRegex(ValueError, "disagree"):
            rc.resolve(dict(ENV, RELEASE_TAG="v0.0.0"))

    def test_run_field_mismatches_are_rejected(self):
        cases = {
            "wrong workflow path": ("path", ".github/workflows/ci.yml"),
            "wrong workflow id": ("workflow_id", WORKFLOW_ID + 1),
            "wrong event": ("event", "push"),
            "wrong source commit": ("head_sha", "d" * 40),
            "wrong branch": ("head_branch", "feature"),
            "failed candidate": ("conclusion", "failure"),
            "cancelled candidate": ("conclusion", "cancelled"),
            "incomplete candidate": ("status", "in_progress"),
            "rerun candidate": ("run_attempt", 2),
        }
        for label, (key, value) in cases.items():
            with self.subTest(label):
                github = FakeGitHub()
                github.run[key] = value
                with self.assertRaisesRegex(ValueError, key):
                    self.resolve(github)

    def test_wrong_repository_is_rejected(self):
        for key in ("repository", "head_repository"):
            with self.subTest(key):
                github = FakeGitHub()
                github.run[key] = {"full_name": "someone/fork"}
                with self.assertRaisesRegex(ValueError, "this repository"):
                    self.resolve(github)

    def test_artifact_problems_are_rejected(self):
        cases = {
            "missing": ([], "exactly one"),
            "duplicate": ([good_artifact(), good_artifact(id=556)], "exactly one"),
            "expired": ([good_artifact(expired=True)], "expired"),
            "empty": ([good_artifact(size_in_bytes=0)], "empty"),
            "other run": ([good_artifact(workflow_run={"id": 1, "head_sha": COMMIT})], "does not belong"),
            "other commit": ([good_artifact(workflow_run={"id": RUN_ID, "head_sha": "e" * 40})], "does not belong"),
            "wrong name": ([good_artifact(name="package-rpm")], "exactly one"),
        }
        for label, (artifacts, error) in cases.items():
            with self.subTest(label):
                github = FakeGitHub()
                github.artifacts = artifacts
                with self.assertRaisesRegex(ValueError, error):
                    self.resolve(github)


class PublishTests(CandidateDirectory):
    def setUp(self):
        super().setUp()
        rc.aggregate(self.dist, TAG)
        self.names = rc.package_names(TAG) + [rc.CHECKSUMS]
        self.github = FakeGitHub()
        self.github.release = {
            "id": 1,
            "tag_name": TAG,
            "draft": True,
            "assets": [
                {"name": name, "size": (self.dist / name).stat().st_size,
                 "digest": "sha256:" + rc.sha256(self.dist / name)}
                for name in self.names
            ],
        }
        self.commands = []

    def fake_run(self, *args, **kwargs):
        self.commands.append([str(arg) for arg in args])
        stdout = json.dumps({"databaseId": 1}) if args[:3] == ("gh", "release", "view") else ""
        return subprocess.CompletedProcess(args, 0, stdout=stdout)

    def publish(self):
        with mock.patch.object(rc, "gh_api", self.github), mock.patch.object(rc, "run", self.fake_run):
            rc.publish(ENV, self.dist)

    def published(self):
        return any(endpoint.endswith("/releases/1") and "PATCH" in args for endpoint, args in self.github.calls)

    def test_exact_artifacts_are_uploaded_then_published(self):
        before = {name: (self.dist / name).read_bytes() for name in self.names}
        self.publish()
        create = self.commands[0]
        self.assertEqual(create[:3], ["gh", "release", "create"])
        self.assertIn("--draft", create)
        self.assertIn("--verify-tag", create)
        self.assertEqual(create[-len(self.names):], [str(self.dist / name) for name in self.names])
        self.assertTrue(self.published())
        self.assertEqual(before, {name: (self.dist / name).read_bytes() for name in self.names})

    def test_publish_does_not_regenerate_changed_checksums(self):
        (self.dist / rc.package_names(TAG)[0]).write_bytes(b"rebuilt")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.publish()
        self.assertEqual(self.commands, [])

    def test_stored_asset_digest_mismatch_leaves_draft(self):
        self.github.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.publish()
        self.assertFalse(self.published())

    def test_incomplete_draft_is_not_published(self):
        self.github.release["assets"].pop()
        with self.assertRaisesRegex(ValueError, "differ"):
            self.publish()
        self.assertFalse(self.published())

    def test_non_draft_release_is_rejected(self):
        self.github.release = dict(copy.deepcopy(self.github.release), draft=False)
        with self.assertRaisesRegex(ValueError, "expected draft"):
            self.publish()
        self.assertFalse(self.published())


class SummaryTests(unittest.TestCase):
    def test_summary_contains_real_values(self):
        text = rc.summary({"GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": COMMIT, "GITHUB_RUN_ID": str(RUN_ID)})
        self.assertIn("### Candidate ready for verification", text)
        self.assertIn(f"git tag -a {TAG} {COMMIT} \\", text)
        self.assertIn(f'-m "MPRIS MiniPlayer {TAG[1:]}"', text)
        self.assertIn(f'-m "Candidate-Run: {RUN_ID}"', text)
        self.assertIn(f"git push origin {TAG}", text)
        self.assertNotIn("<", text)

    def test_summary_rejects_rerun(self):
        with self.assertRaisesRegex(ValueError, "Reruns"):
            rc.summary({"GITHUB_RUN_ATTEMPT": "2", "GITHUB_SHA": COMMIT, "GITHUB_RUN_ID": str(RUN_ID)})


if __name__ == "__main__":
    unittest.main()
