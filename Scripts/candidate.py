#!/usr/bin/env python3
"""Build-side candidate bundle and authenticated GitHub candidate retrieval."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import zipfile

from release import ROOT, atomic_json, file_digest, inventory, output

REPOSITORY = "computer-mcp/computer-mcp"
WORKFLOW = ".github/workflows/release-gate.yml"


def api(path, *arguments):
    response = output(["gh", "api", "repos/" + REPOSITORY + "/" + path, *arguments], ROOT)
    return json.loads(response) if response else None


def bundle():
    subprocess.run([str(ROOT / "Scripts/verify-candidate-ref.sh")], cwd=ROOT, check=True)
    dist = Path(os.environ.get("OUTPUT_DIR", ROOT / "dist")).resolve()
    version = json.loads((ROOT / "Version.json").read_text())
    run, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    destination = ROOT / ".agent/candidate"
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "candidate.tar.gz"
    if archive.exists():
        raise ValueError("Candidate output already exists; candidate bytes are immutable")
    app = dist / "Computer MCP.app"
    identity = plistlib.loads((app / "Contents/Resources/ComputerMCPBuildIdentity.plist").read_bytes())
    paths = [app, dist / "ReleaseMetadata", dist / "SHA256SUMS",
             dist / f"Computer-MCP-{version['version']}-universal.dmg",
             dist / f"Computer-MCP-{version['version']}-universal-ArtifactProvenance.json"]
    expected = {}
    with tarfile.open(archive, "x:gz") as target:
        for path in paths:
            expected[path.name] = inventory(path)
            target.add(path, arcname="dist/" + path.name, recursive=True)
    atomic_json(destination / "candidate.json", {
        "schema_version": 1, "repository": REPOSITORY, "workflow": WORKFLOW,
        "source_commit": os.environ["GITHUB_SHA"], "run_id": int(run), "run_attempt": int(attempt),
        "candidate": f"{run}.{attempt}", "version": version,
        "archive_sha256": file_digest(archive), "outputs": expected,
        "build_identity": identity,
    })
    print(json.dumps({"candidate": f"{run}.{attempt}", "archive": str(archive)}))


def verify_run(run, commit):
    if (run["head_sha"] != commit or run["head_branch"] != "master"
            or run["event"] != "workflow_dispatch" or run["path"] != WORKFLOW
            or run["head_repository"]["full_name"] != REPOSITORY):
        raise ValueError("Candidate run is not the requested trusted master commit/workflow")


def extract_bundle(archive, destination):
    with tarfile.open(archive) as source:
        seen = set()
        for member in source.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != "dist":
                raise ValueError("Unsafe candidate archive path")
            if member.name in seen:
                raise ValueError("Duplicate candidate archive path")
            seen.add(member.name)
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("Unsupported candidate archive member")
            if member.issym() or member.islnk():
                link = PurePosixPath(member.linkname)
                if link.is_absolute() or ".." in link.parts:
                    raise ValueError("Candidate archive links must stay within their bundle without parent traversal")
                target = (destination / member.name).parent / member.linkname if member.issym() else destination / member.linkname
                if not target.resolve().is_relative_to((destination / "dist").resolve()):
                    raise ValueError("Candidate archive link escapes its owned directory")
        # Members and link destinations were checked before any extraction.
        source.extractall(destination)


def request():
    commit = output(["git", "rev-parse", "HEAD"], ROOT)
    if output(["git", "status", "--porcelain"], ROOT):
        raise ValueError("Commit and merge the candidate changes before protected construction")
    current = output(["git", "ls-remote", "https://github.com/" + REPOSITORY + ".git", "refs/heads/master"], ROOT).split()[0]
    if current != commit:
        raise ValueError("The daily checkout must match published master before requesting a candidate")
    work = Path(os.environ["RELEASE_WORK_DIR"])
    previous = Path(os.environ["RELEASE_PREVIOUS_WORK_DIR"]) if os.environ.get("RELEASE_PREVIOUS_WORK_DIR") else None
    request_path = work / "request.json"
    if previous and (previous / "request.json").is_file():
        record = json.loads((previous / "request.json").read_text())
        if record["source_commit"] != commit:
            raise ValueError("Previous candidate request belongs to another commit")
    else:
        record = {"source_commit": commit, "request_id": uuid.uuid4().hex, "requested_at": time.time()}
        atomic_json(request_path, record)
        # Persist the dispatch identity first so an uncertain request is never blindly repeated.
        api("actions/workflows/release-gate.yml/dispatches", "--method", "POST",
            "--field", "ref=master", "--field", "inputs[request_id]=" + record["request_id"])
    atomic_json(request_path, record)
    deadline = time.monotonic() + 7200
    while time.monotonic() < deadline:
        runs = api("actions/workflows/release-gate.yml/runs?branch=master&event=workflow_dispatch&per_page=100")["workflow_runs"]
        matches = [run for run in runs if run["display_title"] == "Computer MCP candidate " + record["request_id"]]
        if not matches:
            if time.time() - record["requested_at"] > 180:
                raise ValueError("Dispatch has no identifiable run; inspect Actions before creating another candidate")
            time.sleep(5)
            continue
        if len(matches) != 1:
            raise ValueError("Ambiguous candidate workflow identity")
        run = matches[0]
        verify_run(run, commit)
        record["run_id"] = run["id"]
        atomic_json(request_path, record)
        if run["status"] == "waiting":
            print("Required action: approve the production environment for " + run["html_url"], flush=True)
            return 75
        if run["status"] == "completed":
            if run["conclusion"] != "success":
                raise ValueError(f"Candidate failed ({run['conclusion']}): {run['html_url']}; preserve this run and use a new candidate after the fix")
            download(run, work, commit)
            return 0
        time.sleep(10)
    raise TimeoutError("Candidate workflow exceeded the two-hour deadline")


def download(run, work, commit):
    verify_run(run, commit)
    artifacts = api(f"actions/runs/{run['id']}/artifacts")["artifacts"]
    name = f"computer-mcp-candidate-{run['id']}-{run['run_attempt']}"
    matches = [item for item in artifacts if item["name"] == name and not item["expired"]]
    if len(matches) != 1:
        raise ValueError("Missing or ambiguous immutable candidate artifact")
    artifact = matches[0]
    checksum = artifact.get("digest", "")
    if not checksum.startswith("sha256:") or len(checksum) != 71:
        raise ValueError("GitHub did not provide a trusted artifact digest")
    zip_path = work / "github-artifact.zip"
    with zip_path.open("wb") as stream:
        subprocess.run(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
                       cwd=ROOT, stdout=stream, check=True, timeout=600)
    if "sha256:" + file_digest(zip_path) != checksum:
        raise ValueError("Downloaded Actions artifact differs from GitHub's immutable digest")
    with zipfile.ZipFile(zip_path) as archive:
        if set(archive.namelist()) != {"candidate.json", "candidate.tar.gz"}:
            raise ValueError("Unexpected candidate artifact contents")
        archive.extractall(work)
    candidate = json.loads((work / "candidate.json").read_text())
    if (candidate["source_commit"] != commit or candidate["repository"] != REPOSITORY
            or candidate["workflow"] != WORKFLOW or candidate["run_id"] != run["id"]
            or candidate["run_attempt"] != run["run_attempt"]
            or candidate["version"] != json.loads((ROOT / "Version.json").read_text())):
        raise ValueError("Candidate manifest is bound to different inputs")
    if file_digest(work / "candidate.tar.gz") != candidate["archive_sha256"]:
        raise ValueError("Candidate bundle digest differs")
    extract_bundle(work / "candidate.tar.gz", work)
    for name, expected in candidate["outputs"].items():
        if Path(name).name != name or inventory(work / "dist" / name) != expected:
            raise ValueError("Extracted candidate differs from its verified manifest")
    atomic_json(work / "github-provenance.json", {"run": run, "artifact": artifact})
    print(json.dumps({"candidate": candidate["candidate"], "source_commit": commit,
                      "artifact_id": artifact["id"], "digest": checksum}))


def reuse_ci(runner, profile):
    """Trust GitHub's immutable artifact, never a caller-supplied receipt/key."""
    commit = runner.source["commit"]
    deadline = time.monotonic() + 5400
    while True:
        runs = api("actions/workflows/ci.yml/runs?branch=master&event=push&per_page=100")["workflow_runs"]
        matching = [r for r in runs if r["head_sha"] == commit]
        if not matching:
            print("No matching master CI evidence; executing checks locally.")
            return
        run = matching[0]
        if (run["path"] != ".github/workflows/ci.yml" or run["head_repository"]["full_name"] != REPOSITORY
                or run["head_branch"] != "master" or run["event"] != "push"):
            raise ValueError("Untrusted CI workflow source")
        if run["status"] == "completed":
            break
        if time.monotonic() >= deadline:
            raise TimeoutError("Matching master CI did not finish before the deadline")
        time.sleep(10)
    if run["conclusion"] != "success":
        raise ValueError("The matching master CI failed; candidate construction cannot bypass it")
    name = f"check-report-{run['id']}-{run['run_attempt']}"
    matches = [a for a in api(f"actions/runs/{run['id']}/artifacts")["artifacts"]
               if a["name"] == name and not a["expired"]]
    if len(matches) != 1 or not matches[0].get("digest", "").startswith("sha256:"):
        print("No immutable CI receipt artifact; executing checks locally.")
        return
    artifact = matches[0]
    runner.key(True)
    with tempfile.TemporaryDirectory(prefix="computer-mcp-ci-evidence-") as temporary:
        archive = Path(temporary) / "evidence.zip"
        with archive.open("wb") as stream:
            subprocess.run(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
                           cwd=ROOT, stdout=stream, check=True, timeout=600)
        if "sha256:" + file_digest(archive) != artifact["digest"]:
            raise ValueError("CI evidence differs from GitHub's immutable digest")
        with zipfile.ZipFile(archive) as bundle, runner.lock():
            results = [json.loads(bundle.read(name))["result"] for name in bundle.namelist()
                       if name.startswith("history/") and name.endswith(".json")]
            for stage in runner.selected(profile):
                state = next(s for s in runner.status(profile) if s["stage"] == stage["id"])
                if state["status"] == "passed":
                    continue
                candidates = [r for r in results if r["stage"] == stage["id"] and r["status"] == "passed"
                              and r["fingerprint"] == state["fingerprint"] and r["outputs"] == {}]
                work = runner.run_dir / "work" / stage["id"]
                if not candidates or work.exists():
                    continue
                result = dict(max(candidates, key=lambda r: r["started_at"]))
                log = bundle.read(result["log"])
                if hashlib.sha256(log).hexdigest() != result["log_sha256"]:
                    raise ValueError("Trusted CI receipt does not match its log")
                result.update(run_dir=str(runner.run_dir), attempt=stage["id"] + "-import-" + uuid.uuid4().hex,
                              imported_from={"run_id": run["id"], "artifact_id": artifact["id"], "digest": artifact["digest"]})
                result["log"] = "logs/" + result["attempt"] + ".log"
                (runner.run_dir / "logs").mkdir(parents=True, exist_ok=True)
                (runner.run_dir / result["log"]).write_bytes(log)
                work.mkdir(parents=True)
                runner.save(result)
                print(json.dumps({"stage": stage["id"], "status": "imported", "ci_run": run["id"]}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("bundle", "request"))
    args = parser.parse_args()
    return bundle() if args.operation == "bundle" else request()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Candidate failed: {error}", file=sys.stderr)
        sys.exit(1)
