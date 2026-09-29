#!/usr/bin/env python3
"""Upload an authenticated candidate DMG to an existing draft; never publish it."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from candidate import REPOSITORY, api, download, verify_run
from release import ROOT, atomic_json, file_digest, output


def draft_asset(release, tag, name, digest):
    if not release["draft"] or release["tag_name"] != tag:
        raise ValueError("Upload requires the existing draft for the signed candidate tag")
    matches = [asset for asset in release["assets"] if asset["name"] == name]
    if len(matches) > 1:
        raise ValueError("Ambiguous draft asset identity")
    if matches and (matches[0]["state"] != "uploaded" or matches[0].get("digest") != "sha256:" + digest):
        raise ValueError("Existing draft asset differs or is incomplete; it cannot be overwritten")
    return matches[0] if matches else None


def upload(run_id, commit, digest, receipt):
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Explicit source commit and DMG SHA-256 are required")
    run = api(f"actions/runs/{run_id}")
    verify_run(run, commit)
    if run["status"] != "completed" or run["conclusion"] != "success":
        raise ValueError("Candidate workflow has not succeeded")
    with tempfile.TemporaryDirectory(prefix="computer-mcp-draft-upload-") as temporary:
        work = Path(temporary)
        download(run, work, commit)
        candidate = json.loads((work / "candidate.json").read_text())
        version = candidate["version"]["version"]
        tag = "v" + version
        subprocess.run(["git", "merge-base", "--is-ancestor", commit, "origin/master"], cwd=ROOT, check=True)
        if output(["git", "cat-file", "-t", "refs/tags/" + tag], ROOT) != "tag":
            raise ValueError("The formal tag must be annotated and signed")
        subprocess.run(["git", "-c", "gpg.format=ssh", "-c",
                        "gpg.ssh.allowedSignersFile=" + str(ROOT / ".github/signing-allowed-signers"),
                        "verify-tag", tag], cwd=ROOT, check=True)
        if output(["git", "rev-parse", "refs/tags/" + tag + "^{commit}"], ROOT) != commit:
            raise ValueError("Formal tag differs from the candidate source")
        dmg = work / "dist" / f"Computer-MCP-{version}-universal.dmg"
        if file_digest(dmg) != digest:
            raise ValueError("Candidate DMG differs from the approved upload digest")
        pages = api("releases?per_page=100", "--paginate", "--slurp")
        matches = [release for page in pages for release in page if release["tag_name"] == tag]
        if len(matches) != 1:
            raise ValueError("A unique pre-existing draft is required")
        release = api(f"releases/{matches[0]['id']}")
        existing = draft_asset(release, tag, dmg.name, digest)
        if existing is None:
            # A failed upload is reconciled on the next invocation; no overwrite or automatic replay.
            subprocess.run(["gh", "release", "upload", tag, "--repo", REPOSITORY, str(dmg)],
                           cwd=ROOT, check=True, timeout=300)
        remote = draft_asset(api(f"releases/{release['id']}"), tag, dmg.name, digest)
        if remote is None:
            raise ValueError("Uploaded asset is missing from draft readback")
        verified = work / "verified"
        verified.mkdir()
        subprocess.run(["gh", "release", "download", tag, "--repo", REPOSITORY,
                        "--pattern", dmg.name, "--dir", str(verified)], cwd=ROOT, check=True, timeout=300)
        if file_digest(verified / dmg.name) != digest:
            raise ValueError("Draft download differs from the authenticated candidate")
        atomic_json(receipt, {"status": "draft-asset-verified", "candidate": candidate["candidate"],
                              "source_commit": commit, "release_id": release["id"], "tag": tag,
                              "asset_id": remote["id"], "asset": dmg.name, "sha256": digest,
                              "uploaded": existing is None, "published": False})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-run", type=int, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--dmg-sha256", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    arguments = parser.parse_args()
    upload(arguments.candidate_run, arguments.source_commit, arguments.dmg_sha256, arguments.receipt)
