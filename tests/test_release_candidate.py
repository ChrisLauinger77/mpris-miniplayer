#!/usr/bin/env python3
"""Deterministic tests for tools/release_candidate.py; GitHub is always mocked."""
import copy
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
TAG_SHA = "b" * 40
UPLOADS = f"https://uploads.github.com/repos/{REPO}/releases/1/assets"
ENV = {
    "RELEASE_TAG": TAG,
    "GH_REPO": REPO,
    "GITHUB_SHA": COMMIT,
    "GITHUB_RUN_ID": str(RUN_ID),
}


class FakeGitHub:
    """Answers the REST endpoints used by ensure_tag() and publish()."""

    def __init__(self):
        self.ref = {"object": {"type": "tag", "sha": TAG_SHA}}
        self.tag = {"tag": TAG, "message": "Release", "object": {"type": "commit", "sha": COMMIT}}
        self.neighbor_refs = []
        self.releases = []
        self.release = None
        self.calls = []

    def __call__(self, endpoint, *args):
        self.calls.append((endpoint, args))
        if endpoint == f"repos/{REPO}/git/matching-refs/tags/{TAG}":
            return self.neighbor_refs + ([{"ref": f"refs/tags/{TAG}"}] if self.ref else [])
        if endpoint == f"repos/{REPO}/git/ref/tags/{TAG}" and self.ref is not None:
            return self.ref
        if endpoint == f"repos/{REPO}/git/tags/{TAG_SHA}":
            return self.tag
        if endpoint == f"repos/{REPO}/git/tags":
            return {"sha": TAG_SHA}
        if endpoint == f"repos/{REPO}/git/refs":
            self.ref = {"object": {"type": "tag", "sha": TAG_SHA}}
            return {}
        if endpoint == f"repos/{REPO}/releases?per_page=100":
            return [self.releases]
        if endpoint == f"repos/{REPO}/releases":
            return {"id": 1, "upload_url": f"{UPLOADS}{{?name,label}}"}
        if endpoint.startswith(f"{UPLOADS}?name="):
            return {}
        if endpoint == f"repos/{REPO}/releases/1":
            return None if args else self.release
        for release in self.releases:
            if endpoint == f"repos/{REPO}/releases/{release['id']}":
                return None if args else release
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
            "assets": self.stored_assets(),
        }

    def stored_assets(self):
        return [
            {"name": name, "size": (self.dist / name).stat().st_size,
             "digest": "sha256:" + rc.sha256(self.dist / name)}
            for name in self.names
        ]

    def publish(self):
        with mock.patch.object(rc, "gh_api", self.github):
            rc.publish(ENV, self.dist)

    def requests(self, method):
        return [endpoint for endpoint, args in self.github.calls if method in args]

    def published(self):
        return f"repos/{REPO}/releases/1" in self.requests("PATCH")

    def stale_draft(self, release_id=7, **changes):
        release = {"id": release_id, "tag_name": TAG, "draft": True, "author": {"login": rc.WORKFLOW_ACCOUNT}}
        release.update(changes)
        return release

    def test_exact_artifacts_are_uploaded_then_published(self):
        before = {name: (self.dist / name).read_bytes() for name in self.names}
        self.publish()
        create = next(args for endpoint, args in self.github.calls if endpoint == f"repos/{REPO}/releases")
        self.assertIn("draft=true", create)
        self.assertIn(f"tag_name={TAG}", create)
        uploads = [(endpoint, args) for endpoint, args in self.github.calls if endpoint.startswith(UPLOADS)]
        self.assertEqual([endpoint for endpoint, _ in uploads], [f"{UPLOADS}?name={name}" for name in self.names])
        self.assertEqual([args[-1] for _, args in uploads], [self.dist / name for name in self.names])
        self.assertEqual(self.requests("DELETE"), [])
        self.assertTrue(self.published())
        self.assertEqual(before, {name: (self.dist / name).read_bytes() for name in self.names})

    def test_publish_does_not_regenerate_changed_checksums(self):
        (self.dist / rc.package_names(TAG)[0]).write_bytes(b"rebuilt")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            self.publish()
        self.assertEqual(self.github.calls, [])

    def test_missing_tag_is_created_at_the_built_commit(self):
        self.github.ref = None
        self.publish()
        annotation = next(args for endpoint, args in self.github.calls if endpoint == f"repos/{REPO}/git/tags")
        self.assertIn(f"tag={TAG}", annotation)
        self.assertIn(f"object={COMMIT}", annotation)
        self.assertIn("type=commit", annotation)
        self.assertIn(f"message=MPRIS MiniPlayer {TAG[1:]}\n\nCandidate-Run: {RUN_ID}\n", annotation)
        ref = next(args for endpoint, args in self.github.calls if endpoint == f"repos/{REPO}/git/refs")
        self.assertIn(f"ref=refs/tags/{TAG}", ref)
        self.assertIn(f"sha={TAG_SHA}", ref)
        posts = self.requests("POST")
        self.assertLess(posts.index(f"repos/{REPO}/git/refs"), posts.index(f"repos/{REPO}/releases"))
        self.assertTrue(self.published())

    def test_existing_tag_at_built_commit_is_reused(self):
        self.publish()
        self.assertNotIn(f"repos/{REPO}/git/tags", self.requests("POST"))
        self.assertNotIn(f"repos/{REPO}/git/refs", self.requests("POST"))
        self.assertTrue(self.published())

    def test_tag_with_matching_prefix_does_not_hide_missing_tag(self):
        self.github.ref = None
        self.github.neighbor_refs = [{"ref": f"refs/tags/{TAG}-rc1"}]
        self.publish()
        self.assertIn(f"repos/{REPO}/git/refs", self.requests("POST"))

    def test_tag_on_other_commit_is_rejected_before_release_creation(self):
        self.github.tag["object"]["sha"] = "c" * 40
        with self.assertRaisesRegex(ValueError, "Tag points at"):
            self.publish()
        self.assert_nothing_changed()

    def test_lightweight_tag_is_rejected_before_release_creation(self):
        self.github.ref["object"]["type"] = "commit"
        with self.assertRaisesRegex(ValueError, "annotated"):
            self.publish()
        self.assert_nothing_changed()

    def test_nested_tag_is_rejected_before_release_creation(self):
        self.github.tag["object"]["type"] = "tag"
        with self.assertRaisesRegex(ValueError, "directly at a commit"):
            self.publish()
        self.assert_nothing_changed()

    def test_tag_creation_failure_does_not_create_release(self):
        self.github.ref = None

        def fail_creation(endpoint, *args):
            if endpoint == f"repos/{REPO}/git/refs":
                raise subprocess.CalledProcessError(1, ["gh", "api", endpoint])
            return self.github(endpoint, *args)

        with mock.patch.object(rc, "gh_api", fail_creation), self.assertRaises(subprocess.CalledProcessError):
            rc.publish(ENV, self.dist)
        self.assertNotIn(f"repos/{REPO}/releases", self.requests("POST"))

    def test_tag_lookup_failure_does_not_create_tag_or_release(self):
        with mock.patch.object(rc, "gh_api", side_effect=subprocess.CalledProcessError(1, ["gh", "api"])) as api:
            with self.assertRaises(subprocess.CalledProcessError):
                rc.publish(ENV, self.dist)
        api.assert_called_once_with(f"repos/{REPO}/git/matching-refs/tags/{TAG}")

    def test_version_mismatch_is_rejected_before_any_github_call(self):
        with mock.patch.object(rc, "gh_api", self.github), self.assertRaisesRegex(ValueError, "disagree"):
            rc.publish(dict(ENV, RELEASE_TAG="v0.0.0"), self.dist)
        self.assertEqual(self.github.calls, [])

    def test_retry_replaces_draft_left_by_earlier_attempt(self):
        other_tag = self.stale_draft(release_id=8, tag_name="v0.0.1")
        self.github.releases = [self.stale_draft(), other_tag]
        self.publish()
        self.assertEqual(self.requests("DELETE"), [f"repos/{REPO}/releases/7"])
        deleted = self.github.calls.index((f"repos/{REPO}/releases/7", ("--method", "DELETE")))
        created = [endpoint for endpoint, _ in self.github.calls].index(f"repos/{REPO}/releases")
        self.assertLess(deleted, created)
        self.assertTrue(self.published())

    def published_release(self, **changes):
        release = self.stale_draft(release_id=9, draft=False, assets=self.stored_assets())
        release.update(changes)
        return release

    def assert_nothing_changed(self):
        self.assertEqual(self.requests("DELETE") + self.requests("POST") + self.requests("PATCH"), [])

    def test_retry_accepts_release_already_published_with_verified_files(self):
        self.github.releases = [self.published_release(), self.stale_draft()]
        self.publish()
        self.assertIn((f"repos/{REPO}/releases/9", ()), self.github.calls)
        self.assert_nothing_changed()

    def test_retry_rejects_release_published_with_other_files(self):
        assets = self.stored_assets()
        assets[0]["digest"] = "sha256:" + "0" * 64
        self.github.releases = [self.published_release(assets=assets)]
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.publish()
        self.assert_nothing_changed()

    def test_retry_requires_digests_to_accept_published_release(self):
        assets = [dict(asset, digest=None) for asset in self.stored_assets()]
        self.github.releases = [self.published_release(assets=assets)]
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.publish()
        self.assert_nothing_changed()

    def test_retry_does_not_delete_draft_from_someone_else(self):
        self.github.releases = [self.stale_draft(author={"login": "ChrisLauinger77"})]
        with self.assertRaisesRegex(ValueError, "not created by this workflow"):
            self.publish()
        self.assertEqual(self.requests("DELETE") + self.requests("POST"), [])

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
        artifact_url = f"https://github.com/{REPO}/actions/runs/{RUN_ID}/artifacts/555"
        text = rc.summary(dict(ENV, GITHUB_RUN_ATTEMPT="1", RELEASE_ARTIFACT_URL=artifact_url))
        self.assertIn("### Candidate ready for verification", text)
        self.assertIn(f"`{TAG}`", text)
        self.assertIn(f"`{COMMIT}`", text)
        self.assertIn(f"`{RUN_ID}`", text)
        self.assertIn(f"[release-assets]({artifact_url})", text)
        self.assertIn("**Review deployments**", text)
        self.assertIn("**release** environment", text)
        self.assertIn("**Approve and deploy**", text)
        self.assertIn("**Reject**", text)
        self.assertNotIn("git tag", text)
        self.assertNotIn("git push", text)
        self.assertNotIn("<", text)

    def test_summary_rejects_rerun(self):
        with self.assertRaisesRegex(ValueError, "Reruns"):
            rc.summary({"GITHUB_RUN_ATTEMPT": "2", "GITHUB_SHA": COMMIT, "GITHUB_RUN_ID": str(RUN_ID)})


if __name__ == "__main__":
    unittest.main()
