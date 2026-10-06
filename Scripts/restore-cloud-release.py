#!/usr/bin/env python3
"""Restore immutable candidate and publication artifacts for a cloud release retry."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

from candidate import api, download, verify_run
from release import ROOT, file_digest


def artifact_download(artifact, destination):
    digest = artifact.get("digest", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Missing immutable GitHub artifact digest")
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "github-artifact.zip"
    with archive.open("wb") as stream:
        subprocess.run(["gh", "api", f"repos/computer-mcp/computer-mcp/actions/artifacts/{artifact['id']}/zip"],
                       cwd=ROOT, stdout=stream, check=True, timeout=600)
    if "sha256:" + file_digest(archive) != digest:
        raise ValueError("GitHub recovery artifact digest differs")
    return archive


def restore(run_id):
    subprocess.run([str(ROOT / "Scripts/verify-publisher-ref.sh")], cwd=ROOT, check=True)
    current_id, current_attempt = int(os.environ["GITHUB_RUN_ID"]), int(os.environ["GITHUB_RUN_ATTEMPT"])
    if not run_id and current_attempt == 1:
        return False, False
    run_id = run_id or current_id
    run = api(f"actions/runs/{run_id}")
    verify_run(run, os.environ["GITHUB_SHA"])
    artifacts = api(f"actions/runs/{run_id}/artifacts")["artifacts"]
    candidates = []
    for item in artifacts:
        match = re.fullmatch(f"computer-mcp-candidate-{run_id}-([0-9]+)", item["name"])
        if match and not item["expired"] and (run_id != current_id or int(match[1]) < current_attempt):
            candidates.append((int(match[1]), item))
    if not candidates:
        raise ValueError("Retry has no preserved signed candidate; investigate without rebuilding")
    attempt, _ = max(candidates, key=lambda item: item[0])
    jobs = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs")["jobs"]
    required = {"Build, sign, notarize, and verify release", "Preserve immutable signed candidate"}
    if not any(required <= {step["name"] for step in job["steps"] if step["conclusion"] == "success"}
               for job in jobs):
        raise ValueError("Recovery candidate was not preserved by the protected build steps")
    run = dict(run, run_attempt=attempt)
    work = ROOT / ".agent/recovery/candidate"
    work.mkdir(parents=True, exist_ok=True)
    download(run, work, os.environ["GITHUB_SHA"])
    (ROOT / ".agent/candidate").mkdir(parents=True, exist_ok=True)
    for name in ("candidate.json", "candidate.tar.gz"):
        shutil.move(str(work / name), str(ROOT / ".agent/candidate" / name))
    shutil.move(str(work / "dist"), str(ROOT / "dist"))
    publications = []
    for item in artifacts:
        match = re.fullmatch(f"computer-mcp-publication-{run_id}-([0-9]+)", item["name"])
        if match and not item["expired"] and (run_id != current_id or int(match[1]) < current_attempt):
            publications.append((int(match[1]), item))
    if not publications:
        return True, False
    _, artifact = max(publications, key=lambda item: item[0])
    archive = artifact_download(artifact, ROOT / ".agent/recovery/publication")
    destination = ROOT / ".agent/publication"
    with zipfile.ZipFile(archive) as bundle:
        record = json.loads(bundle.read("publication-assets.json"))
        expected = {"publication-assets.json"} | {"dist/" + name for name in record["assets"]}
        if (set(bundle.namelist()) != expected or record["source_commit"] != os.environ["GITHUB_SHA"]
                or record["candidate"] != f"{run_id}.{attempt}"):
            raise ValueError("Publication artifact belongs to another candidate or source")
        for name in record["assets"]:
            if Path(name).name != name:
                raise ValueError("Unsafe publication artifact path")
        bundle.extractall(destination)
    return True, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    candidate, publication = restore(args.run_id)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(f"candidate={str(candidate).lower()}\npublication={str(publication).lower()}\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("Cloud release recovery failed: " + str(error), file=sys.stderr)
        sys.exit(1)
