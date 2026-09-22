#!/usr/bin/env python3
"""Tag and publish the accepted candidate without rebuilding its binaries."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from urllib.parse import quote

from candidate import REPOSITORY, extract_bundle
from release import ROOT, Runner, atomic_json, canonical, file_digest, inventory, output


def assembly_identity(candidate):
    return {name: candidate[name] for name in ("candidate", "source_commit", "archive_sha256")}


def checkpoint_assembly(work, candidate, key):
    """Seal assembled bytes before the first upload can have a remote effect."""
    payload = {"identity": assembly_identity(candidate),
               "record": json.loads((work / "publication-assets.json").read_text()),
               "dist": inventory(work / "dist")}
    atomic_json(work / "assembly-checkpoint.json", {
        "payload": payload, "mac": hmac.new(key, canonical(payload), hashlib.sha256).hexdigest()})


def restore_assembly(previous, work, candidate, key):
    checkpoint = previous / "assembly-checkpoint.json"
    if not checkpoint.exists():
        # No upload starts before this checkpoint; reconstruct from the accepted
        # archive instead of trusting partially assembled recovery files.
        return False
    envelope = json.loads(checkpoint.read_text())
    payload = envelope["payload"]
    expected = hmac.new(key, canonical(payload), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, envelope["mac"]):
        raise ValueError("Unauthenticated publication recovery checkpoint")
    if payload["identity"] != assembly_identity(candidate):
        raise ValueError("Prior publication belongs to a different candidate")
    if (payload["record"] != json.loads((previous / "publication-assets.json").read_text())
            or payload["dist"] != inventory(previous / "dist")):
        raise ValueError("Prior assembled assets changed")
    shutil.copytree(previous / "dist", work / "dist", symlinks=True)
    atomic_json(work / "publication-assets.json", payload["record"])
    return True


def run(arguments, **kwargs):
    return subprocess.run(arguments, cwd=ROOT, check=True, timeout=300, **kwargs)


def verify_acceptance(candidate, acceptance, directory):
    files = {"installed_runtime": "installed-runtime.json", "navigation": "navigation.json",
             "workspace_operations": "workspace-operations.json", "plugin_integration": "plugin-integration.json"}
    assertions = {"artifact_identity", "signature_and_notarization", "native_permissions"}
    if (acceptance["status"] != "passed" or set(acceptance["checks"]) != assertions | set(files)
            or any(acceptance[key] != candidate[key] for key in
                   ("candidate", "source_commit", "archive_sha256", "version"))):
        raise ValueError("Missing or mismatched required installed acceptance evidence")
    for name in assertions:
        if acceptance["checks"][name] != "passed":
            raise ValueError("A required acceptance check did not pass: " + name)
    for name, filename in files.items():
        if acceptance["checks"][name] != file_digest(directory / filename):
            raise ValueError("A required acceptance result differs from its evidence: " + name)
    if inventory(Path(acceptance["installed_path"])) != candidate["outputs"]["Computer MCP.app"]:
        raise ValueError("The accepted installed App changed before publication")
    plugin = json.loads((directory / files["plugin_integration"]).read_text())
    if inventory(Path(plugin["installed_path"])) != plugin["files"]:
        raise ValueError("The accepted installed plugin changed before publication")


def release_view(tag):
    response = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}"],
                              cwd=ROOT, capture_output=True, text=True, timeout=60)
    if response.returncode:
        if "HTTP 404" in response.stderr:
            # GitHub's tag endpoint omits drafts; the authenticated list includes them.
            pages = subprocess.check_output(
                ["gh", "api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases?per_page=100"],
                cwd=ROOT, timeout=60)
            matches = [release for page in json.loads(pages) for release in page if release["tag_name"] == tag]
            if len(matches) > 1:
                raise ValueError("Multiple releases have the same tag")
            return matches[0] if matches else None
        response.check_returncode()
    return json.loads(response.stdout)


def synchronize_assets(tag, assets, work):
    """Resume missing draft uploads while refusing replacement of any existing bytes."""
    remote = release_view(tag)
    if remote is None:
        run(["gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag", "--draft",
             "--title", "Computer MCP " + tag[1:], "--notes-file",
             str(next(asset for asset in assets if asset.name.endswith("-ReleaseNotes.md")))])
        remote = release_view(tag)
    names = [asset["name"] for asset in remote["assets"]]
    expected = {asset.name for asset in assets}
    if len(set(names)) != len(names) or not set(names) <= expected:
        raise ValueError("Remote release has duplicate or unexpected assets")
    downloaded = work / "downloaded"
    downloaded.mkdir(exist_ok=True)
    for asset in assets:
        if asset.name not in names:
            if not remote["draft"]:
                raise ValueError("A public release is incomplete; its immutable assets cannot be repaired in place")
            run(["gh", "release", "upload", tag, "--repo", REPOSITORY, str(asset)])
        run(["gh", "release", "download", tag, "--repo", REPOSITORY, "--pattern", asset.name,
             "--dir", str(downloaded), "--clobber"])
        if file_digest(downloaded / asset.name) != file_digest(asset):
            raise ValueError("Existing remote asset differs; immutable releases are never overwritten")
    if remote["draft"]:
        run(["gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false"])
    public = work / "public"
    public.mkdir(exist_ok=True)
    for asset in assets:
        url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{quote(asset.name)}"
        run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
             "--max-time", "120", "--output", str(public / asset.name), url])
        if file_digest(public / asset.name) != file_digest(asset):
            raise ValueError("Public unauthenticated download differs from the accepted delivery")


def publish(run_dir, work):
    definition = json.loads((ROOT / "Scripts/release-checks.json").read_text())
    git_dir = Path(output(["git", "rev-parse", "--git-common-dir"], ROOT))
    if not git_dir.is_absolute():
        git_dir = ROOT / git_dir
    checker = Runner(ROOT, run_dir, definition, git_dir / "computer-mcp-release.key")
    if any(stage["status"] != "passed" for stage in checker.status("acceptance")):
        raise ValueError("Publication requires authenticated, matching candidate and acceptance checkpoints")
    if output(["git", "status", "--porcelain"], ROOT):
        raise ValueError("Publication requires committed source")
    candidate_dir = run_dir / "work/candidate"
    candidate = json.loads((candidate_dir / "candidate.json").read_text())
    acceptance = json.loads((run_dir / "work/acceptance/acceptance.json").read_text())
    verify_acceptance(candidate, acceptance, run_dir / "work/acceptance")
    version = candidate["version"]["version"]
    tag = "v" + version
    commit = (checker.candidate_source or checker.source)["commit"]
    if candidate["source_commit"] != commit:
        raise ValueError("Candidate commit differs from the source being tagged")
    if file_digest(candidate_dir / "candidate.tar.gz") != candidate["archive_sha256"]:
        raise ValueError("Candidate archive changed after acceptance")
    previous = os.environ.get("RELEASE_PREVIOUS_WORK_DIR") or os.environ.get("RELEASE_INTERRUPTED_WORK_DIR")
    if previous:
        restore_assembly(Path(previous), work, candidate, checker.key())
    if not (work / "dist").exists():
        extract_bundle(candidate_dir / "candidate.tar.gz", work)
    dist = work / "dist"
    dmg = dist / f"Computer-MCP-{version}-universal.dmg"
    expected_dmg = candidate["outputs"][dmg.name]["."]["sha256"]
    if file_digest(dmg) != expected_dmg:
        raise ValueError("Distribution bytes differ from the accepted artifact")
    run(["Scripts/verify-release-readiness.sh"])
    run(["Scripts/verify-release-record-rendering.sh"])
    remote_tag = output(["git", "ls-remote", "--tags", "origin", "refs/tags/" + tag], ROOT)
    if remote_tag:
        run(["git", "fetch", "origin", "refs/tags/" + tag + ":refs/tags/" + tag])
    existing = output(["git", "tag", "--list", tag], ROOT)
    if not existing:
        message = work / "tag-message.txt"
        message.write_text(f"Computer MCP {version}\n\nAccepted candidate {candidate['candidate']}\nDMG SHA-256 {expected_dmg}\n")
        run(["git", "tag", "-s", tag, commit, "--file", str(message)])
    run(["git", "fetch", "origin", "master"])
    run(["Scripts/verify-release-ref.sh"],
        env=dict(os.environ, RELEASE_TAG=tag, RELEASE_COMMIT=commit, REQUIRE_REMOTE_BRANCH="1"))
    run(["git", "push", "origin", "refs/tags/" + tag])
    identity = plistlib.loads((dist / "Computer MCP.app/Contents/Resources/ComputerMCPBuildIdentity.plist").read_bytes())
    environment = dict(os.environ, OUTPUT_DIR=str(dist), EXPECTED_TEAM_ID=identity["team_identifier"],
                       GITHUB_SERVER_URL="https://github.com", GITHUB_REPOSITORY=REPOSITORY,
                       GITHUB_RUN_ID=str(candidate["run_id"]), RELEASE_COMMIT=commit)
    if not (work / "publication-assets.json").exists():
        run(["Scripts/assemble-release-assets.sh"], env=environment)
    if file_digest(dmg) != expected_dmg:
        raise ValueError("Release assembly changed the accepted DMG")
    assets = []
    for line in (dist / "SHA256SUMS").read_text().splitlines():
        checksum, name = line.split()
        if not re.fullmatch(r"[0-9a-f]{64}", checksum) or Path(name).name != name or file_digest(dist / name) != checksum:
            raise ValueError("Invalid final asset checksum")
        assets.append(dist / name)
    website_record = dist / "release.json"
    atomic_json(website_record, {"schema_version": 1, "product": "Computer MCP", "version": version,
                                "main_repository": "https://github.com/" + REPOSITORY, "source_commit": commit,
                                "release_tag": tag, "release_url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}"})
    assets.extend([dist / "SHA256SUMS", website_record])
    atomic_json(work / "publication-assets.json", {"candidate": candidate["candidate"],
                "assets": {asset.name: file_digest(asset) for asset in assets}})
    checkpoint_assembly(work, candidate, checker.key())
    synchronize_assets(tag, assets, work)
    atomic_json(work / "delivery.json", {"status": "published", "version": version, "source_commit": commit,
                                        "candidate": candidate["candidate"], "dmg_sha256": expected_dmg,
                                        "release_url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}"})
    print(json.dumps({"status": "published", "version": version, "dmg_sha256": expected_dmg}))


if __name__ == "__main__":
    try:
        publish(Path(os.environ["RELEASE_RUN_DIR"]), Path(os.environ["RELEASE_WORK_DIR"]))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("Publication failed: " + str(error), file=sys.stderr)
        sys.exit(1)
