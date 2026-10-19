#!/usr/bin/env python3
"""Build once, publish the same bytes: connect a release tag to a tested candidate run.

Subcommands:
  version    print the v-prefixed release tag derived from project metadata
  aggregate  require the complete package set and write SHA256SUMS
  summary    print the commands that publish this candidate (Stage 1 only)
  resolve    verify the annotated tag and its Candidate-Run (Stage 2)
  publish    verify downloaded bytes and publish them as the GitHub release
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT_NAME = "MPRIS MiniPlayer"
WORKFLOW_PATH = ".github/workflows/release.yml"
ARTIFACT_NAME = "release-assets"
CHECKSUMS = "SHA256SUMS"
RETENTION_DAYS = 30
# Author of releases created with the workflow's GITHUB_TOKEN.
WORKFLOW_ACCOUNT = "github-actions[bot]"


def _load_check_release():
    spec = importlib.util.spec_from_file_location("check_release", ROOT / "tools/check-release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_tag(tag=None):
    """Return the v-prefixed tag for the agreed project version."""
    return "v" + _load_check_release().release_version(tag)


def package_names(tag):
    """Release package file names, unchanged from the previous release workflow."""
    return [
        f"MPRIS-MiniPlayer-{tag}-x86_64.flatpak",
        f"mpris-miniplayer_{tag}_amd64.deb",
        f"mpris-miniplayer-{tag}.x86_64.rpm",
    ]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def aggregate(dist, tag):
    """Require exactly the expected packages and record their SHA-256 digests."""
    expected = package_names(tag)
    present = sorted(path.name for path in dist.iterdir())
    if present != sorted(expected):
        raise ValueError(f"Candidate must contain exactly {expected}; found {present}")
    for name in expected:
        if (dist / name).stat().st_size == 0:
            raise ValueError(f"Candidate package is empty: {name}")
    lines = [f"{sha256(dist / name)}  {name}\n" for name in expected]
    (dist / CHECKSUMS).write_text("".join(lines), encoding="utf-8")


def verify_assets(dist, tag):
    """Check the downloaded set against its original SHA256SUMS; never regenerate it."""
    expected = package_names(tag)
    present = sorted(path.name for path in dist.iterdir()) if dist.is_dir() else []
    if present != sorted(expected + [CHECKSUMS]):
        raise ValueError(f"Candidate artifact must contain exactly {expected + [CHECKSUMS]}; found {present}")
    recorded = {}
    for line in (dist / CHECKSUMS).read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if match is None or match.group(2) in recorded:
            raise ValueError(f"Malformed {CHECKSUMS} line: {line!r}")
        recorded[match.group(2)] = match.group(1)
    if sorted(recorded) != sorted(expected):
        raise ValueError(f"{CHECKSUMS} must list exactly {expected}; found {sorted(recorded)}")
    for name in expected:
        if sha256(dist / name) != recorded[name]:
            raise ValueError(f"Checksum mismatch for {name}; the candidate bytes changed")
    return recorded


def candidate_run_id(message):
    trailers = [line.strip() for line in message.splitlines() if line.startswith("Candidate-Run:")]
    if len(trailers) != 1 or not re.fullmatch(r"Candidate-Run: [1-9][0-9]*", trailers[0]):
        raise ValueError("Tag message must contain exactly one 'Candidate-Run: <positive run ID>' line")
    return int(trailers[0].split(" ")[1])


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def gh_api(endpoint, *args):
    """Call the GitHub REST API through the gh CLI and decode its JSON response."""
    result = run("gh", "api", *args, endpoint, stdout=subprocess.PIPE, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def tag_message(repository, tag, commit):
    """Return the message of an annotated tag that points directly at commit."""
    ref = gh_api(f"repos/{repository}/git/ref/tags/{tag}")
    if ref["object"]["type"] != "tag":
        raise ValueError("Release requires an annotated tag with a Candidate-Run line")
    tag_object = gh_api(f"repos/{repository}/git/tags/{ref['object']['sha']}")
    if tag_object["tag"] != tag or tag_object["object"]["type"] != "commit":
        raise ValueError("Annotated tag must point directly at a commit")
    if tag_object["object"]["sha"] != commit:
        raise ValueError(f"Tag points at {tag_object['object']['sha']}, but this workflow runs for {commit}")
    return tag_object["message"]


def verify_run(candidate, repository, commit, workflow_id, branch):
    expected = {
        "event": "workflow_dispatch",
        "status": "completed",
        "conclusion": "success",
        "head_sha": commit,
        "head_branch": branch,
        "path": WORKFLOW_PATH,
        "workflow_id": workflow_id,
        # A rerun can replace artifacts under the same run ID. Require a fresh
        # manual run so the run ID unambiguously identifies the tested bytes.
        "run_attempt": 1,
    }
    for key, value in expected.items():
        if candidate.get(key) != value:
            raise ValueError(f"Candidate run requires {key}={value!r}; found {candidate.get(key)!r}")
    for key in ("repository", "head_repository"):
        if (candidate.get(key) or {}).get("full_name") != repository:
            raise ValueError("Candidate run must originate in this repository")


def select_artifact(artifacts, run_id, commit):
    matches = [artifact for artifact in artifacts if artifact["name"] == ARTIFACT_NAME]
    if len(matches) != 1:
        raise ValueError(f"Candidate run must contain exactly one {ARTIFACT_NAME} artifact; found {len(matches)}")
    artifact = matches[0]
    if artifact["expired"]:
        raise ValueError(f"Candidate {ARTIFACT_NAME} artifact has expired; start a new manual candidate run")
    if artifact["size_in_bytes"] <= 0:
        raise ValueError(f"Candidate {ARTIFACT_NAME} artifact is empty; start a new manual candidate run")
    origin = artifact.get("workflow_run") or {}
    if origin.get("id") != run_id or origin.get("head_sha") != commit:
        raise ValueError(f"{ARTIFACT_NAME} artifact does not belong to candidate run {run_id} at {commit}")
    return artifact["id"]


def resolve(env):
    """Return (run_id, artifact_id) for the candidate named by the pushed tag."""
    tag, repository, commit = env["RELEASE_TAG"], env["GH_REPO"], env["GITHUB_SHA"]
    release_tag(tag)
    run_id = candidate_run_id(tag_message(repository, tag, commit))
    current = gh_api(f"repos/{repository}/actions/runs/{env['GITHUB_RUN_ID']}")
    candidate = gh_api(f"repos/{repository}/actions/runs/{run_id}")
    verify_run(candidate, repository, commit, current["workflow_id"], env["DEFAULT_BRANCH"])
    pages = gh_api(f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100", "--paginate", "--slurp")
    artifact_id = select_artifact([artifact for page in pages for artifact in page["artifacts"]], run_id, commit)
    return run_id, artifact_id


def tag_releases(repository, tag):
    pages = gh_api(f"repos/{repository}/releases?per_page=100", "--paginate", "--slurp")
    return [release for page in pages for release in page if release["tag_name"] == tag]


def check_stored_assets(release, dist, names, digests, require_digest=False):
    """Require the release to hold exactly the verified files."""
    assets = {asset["name"]: asset for asset in release["assets"]}
    if sorted(assets) != sorted(names):
        raise ValueError(f"Release assets {sorted(assets)} differ from {sorted(names)}")
    for name in names:
        if assets[name]["size"] != (dist / name).stat().st_size:
            raise ValueError(f"Uploaded asset has an incorrect size: {name}")
        stored = assets[name].get("digest")
        if (stored or require_digest) and stored != "sha256:" + digests[name]:
            raise ValueError(f"Uploaded asset checksum mismatch: {name}")


def discard_stale_drafts(repository, tag, drafts):
    """Delete drafts an earlier failed attempt left for tag, so a rerun starts from scratch."""
    for release in drafts:
        if (release.get("author") or {}).get("login") != WORKFLOW_ACCOUNT:
            raise ValueError(f"Draft release {release['id']} for {tag} was not created by this workflow; "
                             "delete it before retrying")
        print(f"Deleting draft release {release['id']} left by an earlier attempt")
        gh_api(f"repos/{repository}/releases/{release['id']}", "--method", "DELETE")


def create_draft(repository, tag, dist, names):
    """Create a draft and upload to it by ID; a fresh draft is not always found by tag yet."""
    release = gh_api(f"repos/{repository}/releases", "--method", "POST", "-f", f"tag_name={tag}",
                     "-f", f"name={tag}", "-F", "draft=true", "-F", "generate_release_notes=true")
    upload_url = release["upload_url"].split("{", 1)[0]
    for name in names:
        gh_api(f"{upload_url}?name={name}", "--method", "POST",
               "-H", "Content-Type: application/octet-stream", "--input", dist / name)
    return release["id"]


def publish(env, dist):
    """Upload verified bytes to a draft release, check what GitHub stored, then publish it."""
    tag, repository = env["RELEASE_TAG"], env["GH_REPO"]
    release_tag(tag)
    digests = verify_assets(dist, tag)
    digests[CHECKSUMS] = sha256(dist / CHECKSUMS)
    names = package_names(tag) + [CHECKSUMS]
    # Fails if the tag is missing, so creating the release can never create a tag.
    gh_api(f"repos/{repository}/git/ref/tags/{tag}")
    existing = tag_releases(repository, tag)
    published = [release for release in existing if not release["draft"]]
    if published:
        # An earlier attempt's final PATCH can succeed even though its response was lost.
        # Accept that release only if it provably holds the verified bytes.
        check_stored_assets(gh_api(f"repos/{repository}/releases/{published[0]['id']}"),
                            dist, names, digests, require_digest=True)
        print(f"Release {tag} is already published with the verified files")
        return
    discard_stale_drafts(repository, tag, existing)
    endpoint = f"repos/{repository}/releases/{create_draft(repository, tag, dist, names)}"
    release = gh_api(endpoint)
    if release["tag_name"] != tag or release["draft"] is not True:
        raise ValueError("Release lookup did not return the expected draft")
    check_stored_assets(release, dist, names, digests)
    gh_api(endpoint, "--method", "PATCH", "-F", "draft=false")


def summary(env):
    if env["GITHUB_RUN_ATTEMPT"] != "1":
        raise ValueError("Reruns cannot become release candidates; start a new manual workflow run")
    tag = release_tag()
    commit, run_id = env["GITHUB_SHA"], env["GITHUB_RUN_ID"]
    return (
        "### Candidate ready for verification\n\n"
        f"- Version: `{tag[1:]}`\n"
        f"- Source commit: `{commit}`\n"
        f"- Candidate run: `{run_id}`\n\n"
        f"After this run succeeds, download and test its complete `{ARTIFACT_NAME}` artifact.\n\n"
        "When satisfied, run these commands in your local checkout:\n\n"
        "```bash\n"
        f"git tag -a {tag} {commit} \\\n"
        f"  -m \"{PROJECT_NAME} {tag[1:]}\" \\\n"
        f"  -m \"Candidate-Run: {run_id}\"\n\n"
        f"git push origin {tag}\n"
        "```\n\n"
        "The tag-triggered workflow verifies the `Candidate-Run` line against this run and publishes "
        "these exact artifact bytes without rebuilding.\n\n"
        f"- Test and approve the artifacts before tagging.\n"
        f"- Candidate artifacts are kept for {RETENTION_DAYS} days (subject to repository limits); "
        "publish before they expire.\n"
        "- A new candidate requires a new manual workflow run. Do not rerun this run as a substitute; "
        "reruns are rejected.\n"
    )


def write_lines(path, text):
    with Path(path).open("a", encoding="utf-8") as stream:
        stream.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("version", "aggregate", "summary", "resolve", "publish"))
    parser.add_argument("--dist", type=Path, default=ROOT / "release-assets")
    args = parser.parse_args()
    env = os.environ
    if args.command == "version":
        print(release_tag())
    elif args.command == "aggregate":
        aggregate(args.dist, release_tag())
        print((args.dist / CHECKSUMS).read_text(), end="")
    elif args.command == "summary":
        text = summary(env)
        print(text, end="")
        write_lines(env["GITHUB_STEP_SUMMARY"], text)
    elif args.command == "resolve":
        run_id, artifact_id = resolve(env)
        print(f"Verified candidate run {run_id}, artifact {artifact_id}")
        write_lines(env["GITHUB_OUTPUT"], f"run_id={run_id}\nartifact_id={artifact_id}\n")
    else:
        publish(env, args.dist)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
