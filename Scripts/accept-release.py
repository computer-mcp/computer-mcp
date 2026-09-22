#!/usr/bin/env python3
"""Accept a verified candidate already installed on the production Mac."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlparse

from release import ROOT, atomic_json, file_digest, inventory


def command(arguments, timeout=60):
    return subprocess.check_output(arguments, cwd=ROOT, timeout=timeout).decode()


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
    subprocess.run([sys.executable, str(ROOT / "Scripts/verify-installed-workspaces.py"),
                    "--cli", str(cli), "--work", str(work)], check=True, timeout=120)
    doctor = json.loads(command([str(cli), "plugins", "doctor", "codex"]))
    if doctor["status"] != "passed" or doctor["source"]["kind"] != "artifact":
        raise ValueError("Codex integration requires a healthy installed plugin artifact")
    plugin = Path(unquote(urlparse(doctor["source"]["root"]).path)).resolve()
    adapter = plugin / "bin/codex-mcp-adapter"
    plugin_identity = inventory(plugin)
    if command([str(adapter), "--version"]).strip() != doctor["version"]:
        raise ValueError("Installed plugin runtime and manifest versions differ")
    vendor = shutil.which("codex")
    if not vendor:
        print("Required action: make the vendor Codex executable available on PATH, then resume.")
        return 75
    plugin_log = work / "plugin-integration.log"
    with plugin_log.open("wb") as stream:
        subprocess.run([sys.executable, str(ROOT / "Scripts/verify-codex-gateway-flow.py"),
                        str(cli), str(adapter), vendor,
                        str(ROOT / "Tests/ComputerMCPTests/Fixtures/NativeCodex/ModelServer.py"),
                        "--output-directory", str(work / "plugin-runtime")],
                       stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=240)
    if inventory(plugin) != plugin_identity:
        raise ValueError("Installed plugin changed during acceptance")
    plugin_result = work / "plugin-integration.json"
    atomic_json(plugin_result, {"status": "passed", "plugin_id": "codex", "version": doctor["version"],
                               "installed_path": str(plugin), "files": plugin_identity,
                               "archive_sha256": doctor["source"]["artifact_sha256"],
                               "vendor_version": command([vendor, "--version"]).strip(),
                               "vendor_sha256": file_digest(Path(vendor)), "log_sha256": file_digest(plugin_log),
                               "model_backend": "fixed-loopback-fixture", "real_model_verified": False})
    if inventory(app) != expected:
        raise ValueError("Installed artifact changed during acceptance")
    receipt = {"schema_version": 1, "status": "passed", "candidate": candidate["candidate"],
               "source_commit": candidate["source_commit"], "version": version,
               "archive_sha256": candidate["archive_sha256"],
               "cli_sha256": file_digest(cli), "installed_path": str(app),
               "checks": {"artifact_identity": "passed", "signature_and_notarization": "passed",
                          "native_permissions": "passed", "installed_runtime": file_digest(runtime_output),
                          "navigation": file_digest(navigation),
                          "workspace_operations": file_digest(work / "workspace-operations.json"),
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
