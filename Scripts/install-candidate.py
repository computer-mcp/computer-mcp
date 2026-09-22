#!/usr/bin/env python3
"""Install an authenticated candidate after explicit production-cutover authorization."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

from release import ROOT, Runner, atomic_json, file_digest, inventory, output


def run(arguments, timeout=90):
    return subprocess.check_output(arguments, cwd=ROOT, timeout=timeout)


def quit_app(app):
    pids = json.loads(run(["xcrun", "swift", str(ROOT / "Scripts/quit-installed-app.swift"), str(app)]))
    deadline = time.monotonic() + 30
    while pids and time.monotonic() < deadline:
        alive = []
        for pid in pids:
            try:
                os.kill(pid, 0)
                alive.append(pid)
            except ProcessLookupError:
                pass
        pids = alive
        if pids:
            time.sleep(0.25)
    if pids:
        raise ValueError("Normal App shutdown did not finish; current installation is preserved")


def launch(app, expected):
    run(["/usr/bin/open", "-a", str(app)], timeout=10)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            status = json.loads(run([str(app / "Contents/Resources/computer-mcp"), "app", "status"], timeout=5))
            if status["version"] == expected["version"] and str(status["build"]) == str(expected["build"]):
                return status["pid"]
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            pass
        time.sleep(0.5)
    raise TimeoutError("Installed candidate did not report its expected identity within 45 seconds")


def install(runner, approved):
    if not approved:
        print("Required action: authorize production App replacement, then rerun with --approve-cutover. No App was changed.")
        return 75
    with runner.lock():
        if any(row["status"] != "passed" for row in runner.status("candidate")):
            raise ValueError("Installation requires an authenticated matching candidate checkpoint")
        candidate_dir = runner.run_dir / "work/candidate"
        candidate = json.loads((candidate_dir / "candidate.json").read_text())
        expected = candidate["outputs"]["Computer MCP.app"]
        app = Path("/Applications/Computer MCP.app")
        record_dir = runner.run_dir / "installation"
        record_dir.mkdir(mode=0o700, exist_ok=True)
        if app.exists() and inventory(app) == expected:
            print("The exact candidate is already installed; resume acceptance.")
            return 0
        backup = record_dir / "previous/Computer MCP.app"
        if backup.exists() or (record_dir / "cutover.json").exists():
            raise ValueError("An earlier cutover requires inspection; the previous App and journal are retained")
        old_plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        previous_version = {"version": old_plist["CFBundleShortVersionString"], "build": old_plist["CFBundleVersion"]}
        old_identity = inventory(app)
        version = candidate["version"]["version"]
        dmg = candidate_dir / "dist" / f"Computer-MCP-{version}-universal.dmg"
        if file_digest(dmg) != candidate["outputs"][dmg.name]["."]["sha256"]:
            raise ValueError("Candidate DMG changed")
        stage = Path("/Applications") / (".Computer MCP.candidate-" + candidate["candidate"] + ".app")
        if stage.exists():
            raise ValueError("Candidate staging path already exists; inspect the previous interrupted installation")
        with tempfile.TemporaryDirectory(prefix="computer-mcp-mount-") as temporary:
            mount = Path(temporary) / "volume"
            mount.mkdir()
            run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)])
            try:
                mounted_app = mount / "Computer MCP.app"
                if inventory(mounted_app) != expected:
                    raise ValueError("Mounted DMG App differs from the accepted candidate manifest")
                run(["/usr/bin/ditto", str(mounted_app), str(stage)])
            finally:
                run(["/usr/bin/hdiutil", "detach", str(mount)])
        if inventory(stage) != expected:
            raise ValueError("Staged App changed while copying")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(stage)])
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(stage)])
        run(["xcrun", "stapler", "validate", str(stage)])
        backup.parent.mkdir(exist_ok=True)
        journal = {"candidate": candidate["candidate"], "archive_sha256": candidate["archive_sha256"],
                   "previous_version": previous_version, "previous_files": old_identity,
                   "previous_app": str(backup), "candidate_staging": str(stage), "state": "prepared"}
        atomic_json(record_dir / "cutover.json", journal)
        quit_app(app)
        if inventory(app) != old_identity:
            raise ValueError("Current App changed before replacement")
        app.rename(backup)
        try:
            stage.rename(app)
            journal.update(state="installed", pid=launch(app, candidate["version"]))
        except Exception:
            # Preserve data and plugin directory identities. Rollback replaces only the App.
            quit_app(app)
            if app.exists():
                app.rename(record_dir / "failed-candidate.app")
            backup.rename(app)
            launch(app, previous_version)
            journal["state"] = "rolled_back"
            atomic_json(record_dir / "cutover.json", journal)
            raise
        atomic_json(record_dir / "cutover.json", journal)
        print(json.dumps({"status": "installed", "candidate": candidate["candidate"], "previous_app": str(backup)}))
        return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    parser.add_argument("--approve-cutover", action="store_true", help="Use only after explicit authorization for this replacement")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.run):
        parser.error("Invalid run identifier")
    try:
        git_dir = Path(output(["git", "rev-parse", "--git-common-dir"], ROOT))
        if not git_dir.is_absolute():
            git_dir = ROOT / git_dir
        runner = Runner(ROOT, ROOT / ".agent/releases" / args.run,
                        json.loads((ROOT / "Scripts/release-checks.json").read_text()), git_dir / "computer-mcp-release.key")
        sys.exit(install(runner, args.approve_cutover))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("Candidate installation stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
