#!/usr/bin/env python3
"""Accept a verified candidate already installed on the production Mac."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse

from release import ROOT, atomic_json, file_digest, inventory, source_identity


def command(arguments, timeout=60):
    return subprocess.check_output(arguments, cwd=ROOT, timeout=timeout).decode()


def inspect_installed_plugin(cli):
    """Verify a selected packaged plugin through the host's read-only contract."""
    snapshot = json.loads(command([str(cli), "plugins", "list"]))
    state = snapshot["state"]
    if snapshot.get("recovery_error"):
        raise ValueError("Plugin storage requires recovery before acceptance")
    selected = state["selected_installations"]
    bundled = sorted(item["manifest"]["id"] for item in snapshot["bundled"]
                     if item["manifest"]["id"] not in selected)
    installed = sorted(item["plugin_id"] for item in state["installations"]
                       if item["source"]["kind"] == "artifact"
                       and selected.get(item["plugin_id"]) == item["id"])
    candidates = bundled + installed
    if not candidates:
        raise ValueError("Acceptance requires a selected bundled or installed plugin package")
    unavailable = []
    for plugin_id in candidates:
        try:
            doctor = json.loads(command([str(cli), "plugins", "doctor", plugin_id]))
        except subprocess.CalledProcessError as error:
            if error.returncode != 1:
                raise
            doctor = json.loads(error.output)
            if doctor.get("status") != "failed":
                raise
        if doctor["plugin_id"] != plugin_id or doctor["revision"] != state["revision"]:
            raise ValueError("Plugin identity or host revision changed before acceptance")
        if doctor["status"] == "passed":
            break
        if doctor["status"] not in ("failed", "unverified"):
            raise ValueError("The plugin doctor returned an unknown status")
        unavailable.append({"plugin_id": plugin_id, "status": doctor["status"], "checks": doctor["checks"]})
    else:
        raise ValueError("No installed plugin passed its host package checks: " + ", ".join(candidates))
    source = doctor.get("source") or {}
    if source.get("kind") not in ("bundled", "artifact"):
        raise ValueError("The selected plugin is not a bundled or installed package")
    location = urlparse(source["root"])
    if location.scheme != "file" or location.netloc not in ("", "localhost"):
        raise ValueError("Installed plugin root must be a local file URL")
    plugin = Path(unquote(location.path)).resolve(strict=True)
    if not plugin.is_dir():
        raise ValueError("Installed plugin root is not a directory")
    identity = inventory(plugin)
    verified = json.loads(command([str(cli), "plugins", "doctor", plugin_id]))
    current = json.loads(command([str(cli), "plugins", "list"]))
    if (inventory(plugin) != identity or current != snapshot
            or {key: value for key, value in verified.items() if key != "checked_at"}
            != {key: value for key, value in doctor.items() if key != "checked_at"}):
        raise ValueError("Installed plugin identity or host settings changed during acceptance")
    return {"status": "passed", "plugin_id": plugin_id, "version": doctor["version"],
            "installed_path": str(plugin), "files": identity, "source": source,
            "scope": doctor["scope"], "checks": doctor["checks"],
            "not_checked": doctor["not_checked"], "unavailable_plugins": unavailable}


def accept(app, candidate_directory, work):
    candidate = json.loads((candidate_directory / "candidate.json").read_text())
    expected = candidate["outputs"]["Computer MCP.app"]
    if not app.is_dir() or inventory(app) != expected:
        print("Required action: authorize this production replacement, run python3 Scripts/install-candidate.py --run "
              + candidate_directory.parents[1].name + " --approve-cutover, then resume. The current App is unchanged.")
        return 75
    cli = app / "Contents/Resources/computer-mcp"
    subprocess.run(["python3", str(ROOT / "Scripts/version.py"), "check", "--app", str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)], check=True)
    subprocess.run(["xcrun", "stapler", "validate", str(app)], check=True)
    status = json.loads(command([str(cli), "app", "status"]))
    version = candidate["version"]
    if status["version"] != version["version"] or str(status["build"]) != str(version["build"]):
        raise ValueError("The running App does not match the installed candidate")
    permissions = json.loads(command([str(cli), "permissions", "status"]))
    missing = [name for name in ("accessibility", "screen_recording") if permissions[name] != "granted"]
    if missing:
        print("Required action: enable " + ", ".join(missing) + " for " + str(app) + " in System Settings, then resume.")
        return 75
    runtime_output = work / "installed-runtime.json"
    subprocess.run(["python3", str(ROOT / "Scripts/verify-installed-runtime.py"), "--cli", str(cli),
                    "--deny-source", str(ROOT), "--output", str(runtime_output)], check=True, timeout=90)
    navigation = work / "navigation.json"
    with navigation.open("wb") as stream:
        result = subprocess.run(["xcrun", "swift", str(ROOT / "Scripts/verify-app-navigation.swift"),
                                 str(status["pid"]), str(app)], stdout=stream, timeout=90)
    if result.returncode == 75:
        return 75
    result.check_returncode()
    subprocess.run([sys.executable, str(ROOT / "Scripts/verify-installed-projects.py"),
                    "--cli", str(cli), "--work", str(work)], check=True, timeout=120)
    plugin_result = work / "plugin-integration.json"
    atomic_json(plugin_result, inspect_installed_plugin(cli))
    if inventory(app) != expected:
        raise ValueError("Installed artifact changed during acceptance")
    receipt = {"schema_version": 1, "status": "passed", "candidate": candidate["candidate"],
               "checker_source": source_identity(ROOT),
               "source_commit": candidate["source_commit"], "version": version,
               "archive_sha256": candidate["archive_sha256"],
               "cli_sha256": file_digest(cli), "installed_path": str(app),
               "checks": {"artifact_identity": "passed", "signature_and_notarization": "passed",
                          "native_permissions": "passed", "installed_runtime": file_digest(runtime_output),
                          "navigation": file_digest(navigation),
                          "project_operations": file_digest(work / "project-operations.json"),
                          "plugin_integration": file_digest(plugin_result)}}
    atomic_json(work / "acceptance.json", receipt)
    print(json.dumps({"status": "passed", "candidate": candidate["candidate"]}))
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Computer MCP.app"))
    args = parser.parse_args()
    try:
        run = Path(os.environ["RELEASE_RUN_DIR"])
        sys.exit(accept(args.app.resolve(), run / "work/candidate", Path(os.environ["RELEASE_WORK_DIR"])))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("Installed candidate acceptance failed: " + str(error), file=sys.stderr)
        sys.exit(1)
