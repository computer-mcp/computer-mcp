#!/usr/bin/env python3
"""Assemble, publish and verify releases in the protected GitHub Actions job."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import quote

from candidate import REPOSITORY
from release import ROOT, atomic_json, file_digest, inventory, output

WORK = ROOT / ".agent/publication"
TAG_SIGNING_KEY = os.environ.pop("RELEASE_TAG_SIGNING_KEY", None)


def run(arguments, **kwargs):
    return subprocess.run(arguments, cwd=ROOT, check=True, timeout=300, **kwargs)


def require_cloud():
    run(["Scripts/verify-publisher-ref.sh"])


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



def candidate_identity():
    directory = ROOT / ".agent/candidate"
    record = json.loads((directory / "candidate.json").read_text())
    if (record["source_commit"] != os.environ["GITHUB_SHA"]
            or record["repository"] != REPOSITORY
            or record["workflow"] != ".github/workflows/release-gate.yml"
            or record["version"] != json.loads((ROOT / "Version.json").read_text())
            or record["archive_sha256"] != file_digest(directory / "candidate.tar.gz")):
        raise ValueError("Candidate does not match the protected source and immutable archive")
    for name, expected in record["outputs"].items():
        if Path(name).name != name or inventory(ROOT / "dist" / name) != expected:
            raise ValueError("Candidate output changed: " + name)
    return record


def verify_assembly(work):
    record = json.loads((work / "publication-assets.json").read_text())
    if record["source_commit"] != os.environ["GITHUB_SHA"]:
        raise ValueError("Publication assembly belongs to another source commit")
    assets = []
    for name, digest in record["assets"].items():
        path = work / "dist" / name
        if (Path(name).name != name or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or path.is_symlink() or not path.is_file() or file_digest(path) != digest):
            raise ValueError("Publication asset changed: " + name)
        assets.append(path)
    if {path.name for path in (work / "dist").iterdir()} != set(record["assets"]):
        raise ValueError("Publication has unexpected assets")
    if output(["git", "rev-parse", record["tag"]], ROOT) != record["tag_object"]:
        raise ValueError("Publication tag identity changed")
    return record, assets


def sign_tag(tag, commit, message):
    key = WORK / "tag-signing-key"
    identity = os.environ["RELEASE_TAG_SIGNING_IDENTITY"]
    if not re.fullmatch(r"[^\s<>]+@[^\s<>]+", identity):
        raise ValueError("Invalid release signing identity")
    try:
        if TAG_SIGNING_KEY is None:
            raise ValueError("Protected tag signing key is required")
        key.write_text(TAG_SIGNING_KEY)
        key.chmod(0o600)
        run(["git", "-c", "user.name=Computer MCP Release", "-c", "user.email=" + identity,
             "-c", "gpg.format=ssh", "-c", "user.signingkey=" + str(key),
             "tag", "-s", tag, commit, "--file", str(message)])
    finally:
        key.unlink(missing_ok=True)


def assemble():
    require_cloud()
    WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
    if (WORK / "publication-assets.json").exists():
        verify_assembly(WORK)
        return
    candidate = candidate_identity()
    version, commit = candidate["version"]["version"], candidate["source_commit"]
    tag = "v" + version
    dmg_name = f"Computer-MCP-{version}-universal.dmg"
    dmg_hash = candidate["outputs"][dmg_name]["."]["sha256"]
    if output(["git", "ls-remote", "--tags", "origin", "refs/tags/" + tag], ROOT):
        run(["git", "fetch", "origin", "refs/tags/" + tag + ":refs/tags/" + tag])
    if not output(["git", "tag", "--list", tag], ROOT):
        message = WORK / "tag-message.txt"
        message.write_text(f"Computer MCP {version}\n\nProtected candidate {candidate['candidate']}\nDMG SHA-256 {dmg_hash}\n")
        sign_tag(tag, commit, message)
    run(["Scripts/verify-release-ref.sh"], env=dict(os.environ, RELEASE_TAG=tag,
        RELEASE_COMMIT=commit, REQUIRE_REMOTE_BRANCH="1"))
    run(["gh", "auth", "setup-git"])
    run(["git", "push", "origin", "refs/tags/" + tag])
    environment = dict(os.environ, OUTPUT_DIR=str(ROOT / "dist"), RELEASE_COMMIT=commit,
                       GITHUB_RUN_ID=str(candidate["run_id"]), GITHUB_RUN_ATTEMPT=str(candidate["run_attempt"]))
    run(["Scripts/assemble-release-assets.sh"], env=environment)
    source = ROOT / "dist"
    website = source / "release.json"
    atomic_json(website, {"schema_version":1, "product":"Computer MCP", "version":version,
        "main_repository":"https://github.com/" + REPOSITORY, "source_commit":commit,
        "release_tag":tag, "release_url":f"https://github.com/{REPOSITORY}/releases/tag/{tag}"})
    assets = []
    for line in (source / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split()
        if Path(name).name != name or file_digest(source / name) != digest:
            raise ValueError("Invalid assembled checksum")
        assets.append(source / name)
    assets.append(website)
    run(["Scripts/write-release-checksums.sh", str(source), str(source / "SHA256SUMS"),
         *[str(path) for path in assets]])
    assets.append(source / "SHA256SUMS")
    if file_digest(source / dmg_name) != dmg_hash:
        raise ValueError("Release assembly changed the notarized DMG")
    destination = WORK / "dist"
    destination.mkdir()
    for path in assets:
        shutil.copy2(path, destination / path.name)
    atomic_json(WORK / "publication-assets.json", {"candidate":candidate["candidate"],
        "source_commit":commit, "archive_sha256":candidate["archive_sha256"], "tag":tag,
        "tag_object":output(["git", "rev-parse", tag], ROOT), "dmg_sha256":dmg_hash,
        "assets":{path.name:file_digest(path) for path in assets}})
    verify_assembly(WORK)


def publish():
    require_cloud()
    record, assets = verify_assembly(WORK)
    synchronize_assets(record["tag"], assets, WORK)
    atomic_json(WORK / "delivery.json", {"status":"published", "source_commit":record["source_commit"],
        "tag":record["tag"], "dmg_sha256":record["dmg_sha256"],
        "release_url":f"https://github.com/{REPOSITORY}/releases/tag/{record['tag']}"})
    print(json.dumps({"status":"published", "tag":record["tag"]}))


def verify_public(tag):
    require_cloud()
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag):
        raise ValueError("A stable release tag is required")
    remote = release_view(tag)
    if remote is None or remote["draft"] or remote["prerelease"]:
        raise ValueError("A public stable release is required")
    work = ROOT / ".agent/public-release-verification"
    work.mkdir(parents=True, exist_ok=True)
    run(["gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", str(work)])
    checksums = {}
    for line in (work / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split()
        if (Path(name).name != name or name in checksums or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or file_digest(work / name) != digest):
            raise ValueError("Public release checksum mismatch")
        checksums[name] = digest
    checksums["SHA256SUMS"] = file_digest(work / "SHA256SUMS")
    record = json.loads((work / "release.json").read_text())
    if record["release_tag"] != tag or record["main_repository"] != "https://github.com/" + REPOSITORY:
        raise ValueError("Public delivery record identity differs")
    run(["git", "fetch", "origin", "refs/tags/" + tag + ":refs/tags/" + tag])
    run(["Scripts/verify-release-ref.sh"], env=dict(os.environ, RELEASE_TAG=tag,
        RELEASE_COMMIT=record["source_commit"], REQUIRE_REMOTE_BRANCH="1"))
    if {asset["name"] for asset in remote["assets"]} != set(checksums):
        raise ValueError("Public release asset inventory differs")
    public = work / "public"
    public.mkdir()
    for asset in remote["assets"]:
        if asset["digest"] != "sha256:" + checksums[asset["name"]]:
            raise ValueError("GitHub public asset digest differs")
        target = public / asset["name"]
        run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "120",
             "--output", str(target), asset["browser_download_url"]])
        if file_digest(target) != checksums[asset["name"]]:
            raise ValueError("Unauthenticated public download differs")
    version = record["version"]
    for kind in ("App", "DMG"):
        if json.loads((work / f"Computer-MCP-{version}-{kind}Notary.json").read_text())["status"] != "Accepted":
            raise ValueError("Published notarization was not accepted")
    dmg = work / f"Computer-MCP-{version}-universal.dmg"
    run(["/usr/bin/codesign", "--verify", "--strict", str(dmg)])
    run(["xcrun", "stapler", "validate", str(dmg)])
    mount = work / "mount"
    mount.mkdir()
    run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)])
    try:
        app = mount / "Computer MCP.app"
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
        run(["xcrun", "stapler", "validate", str(app)])
        identity = plistlib.loads((app / "Contents/Resources/ComputerMCPBuildIdentity.plist").read_bytes())
        authority = json.loads(output(["git", "show", record["source_commit"] + ":Version.json"], ROOT))
        if (identity["source_commit"] != record["source_commit"] or identity["version"] != authority["version"]
                or str(identity["build"]) != str(authority["build"])
                or identity["team_identifier"] != os.environ["EXPECTED_TEAM_ID"]
                or identity["embedded_cli_sha256"] != file_digest(app / "Contents/Resources/computer-mcp")):
            raise ValueError("Published App build identity differs from the signed release source")
    finally:
        run(["/usr/bin/hdiutil", "detach", str(mount)])
    message = work / "signing-check.txt"
    message.write_text("Release automation signing check\n")
    WORK.mkdir(parents=True, exist_ok=True)
    scratch_tag = "release-signing-check-" + os.environ["GITHUB_RUN_ID"]
    sign_tag(scratch_tag, os.environ["GITHUB_SHA"], message)
    try:
        run(["git", "-c", "gpg.format=ssh", "-c",
             "gpg.ssh.allowedSignersFile=" + str(ROOT / ".github/signing-allowed-signers"), "verify-tag", scratch_tag])
    finally:
        run(["git", "tag", "-d", scratch_tag])
    print(json.dumps({"status":"verified", "tag":tag, "tag_signing":"passed"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("assemble", "publish", "verify-public"))
    parser.add_argument("--tag")
    args = parser.parse_args()
    if args.operation == "assemble":
        assemble()
    elif args.operation == "publish":
        publish()
    else:
        verify_public(args.tag or "v" + json.loads((ROOT / "Version.json").read_text())["version"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("Cloud publication failed: " + str(error), file=sys.stderr)
        sys.exit(1)
