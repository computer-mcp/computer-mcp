#!/usr/bin/env python3
"""Run repository release checks with authenticated, input-bound checkpoints."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
WAITING = 75


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def inventory(root):
    """Include modes and symlink targets without following paths out of the run."""
    if root.is_symlink():
        raise ValueError(f"Output root must not be a symlink: {root}")
    if not root.exists():
        raise ValueError(f"Missing output: {root}")
    paths = [root] if not root.is_dir() else sorted(root.rglob("*"))
    result = {}
    for path in paths:
        mode = path.lstat().st_mode
        name = str(path.relative_to(root)) if path != root else "."
        if stat.S_ISLNK(mode):
            value = {"link": os.readlink(path)}
        elif stat.S_ISREG(mode):
            value = {"sha256": file_digest(path), "size": path.stat().st_size}
        elif stat.S_ISDIR(mode):
            value = {"directory": True}
        else:
            raise ValueError(f"Unfinished runtime output cannot be a checkpoint: {path}")
        result[name] = dict(value, mode=stat.S_IMODE(mode))
    return result


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    with temporary.open("xb") as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True).encode() + b"\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def output(command, root):
    return subprocess.check_output(command, cwd=root, timeout=60, stderr=subprocess.PIPE).decode().strip()


def source_identity(root):
    names = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=root, timeout=30
    ).decode().split("\0")
    files = {}
    for name in sorted(set(names) - {""}):
        path = root / name
        if not path.exists() and not path.is_symlink():
            files[name] = {"deleted": True}
        elif path.is_symlink():
            files[name] = {"link": os.readlink(path)}
        elif path.is_file():
            files[name] = {"sha256": file_digest(path), "mode": stat.S_IMODE(path.stat().st_mode)}
        else:
            raise ValueError(f"Unsupported source entry: {name}")
    return {"commit": output(["git", "rev-parse", "HEAD"], root), "files": digest(files)}


def environment_identity(root):
    return {
        "swift": output(["/usr/bin/swift", "--version"], root),
        "xcode": output(["/usr/bin/xcodebuild", "-version"], root),
        "os": platform.platform(),
        "python": platform.python_version(),
        "configuration": {key: os.environ.get(key, "") for key in (
            "DEVELOPER_DIR", "SDKROOT", "ARCHES", "MACOSX_DEPLOYMENT_TARGET",
            "APP_ENVIRONMENT", "ADHOC_SIGNING", "RELEASE_MODE", "EXPECTED_TEAM_ID",
        )},
    }


def validate_definition(definition):
    seen = set()
    for stage in definition["stages"]:
        name = stage["id"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name) or name in seen:
            raise ValueError(f"Invalid or duplicate stage: {name}")
        if not set(stage.get("needs", [])) <= seen:
            raise ValueError(f"Stage dependencies must precede {name}")
        if not stage.get("commands") or not 0 < stage["timeout_seconds"] <= 14400:
            raise ValueError(f"Stage {name} needs commands and a bounded timeout")
        if not all(isinstance(c, list) and c and all(isinstance(a, str) for a in c) for c in stage["commands"]):
            raise ValueError(f"Invalid commands for {name}")
        seen.add(name)
    for profile, names in definition["profiles"].items():
        if not set(names) <= seen:
            raise ValueError(f"Unknown stage in {profile}")


class Runner:
    def __init__(self, root, run_dir, definition, key_path, source=None, environment=None):
        self.root = root.resolve()
        self.run_dir = run_dir.resolve()
        self.definition = definition
        validate_definition(definition)
        self.key_path = key_path
        self.source = source if source is not None else source_identity(self.root)
        self.environment = environment if environment is not None else environment_identity(self.root)
        self.stages = {stage["id"]: stage for stage in definition["stages"]}

    def selected(self, profile):
        required = set()

        def add(name):
            required.add(name)
            for dependency in self.stages[name].get("needs", []):
                add(dependency)

        for name in self.definition["profiles"][profile]:
            add(name)
        return [stage for stage in self.definition["stages"] if stage["id"] in required]

    def key(self, create=False):
        if create and not self.key_path.exists():
            self.key_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                descriptor = os.open(self.key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                pass
            else:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(os.urandom(32))
        info = self.key_path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("The local checkpoint key must be an owner-only regular file")
        key = self.key_path.read_bytes()
        if len(key) != 32:
            raise ValueError("Invalid local checkpoint key")
        return key

    def fingerprint(self, stage, dependencies):
        return digest({"source": self.source, "environment": self.environment,
                       "stage": stage, "dependencies": dependencies})

    def receipt(self, name):
        path = self.run_dir / "receipts" / (name + ".json")
        envelope = json.loads(path.read_text())
        expected = hmac.new(self.key(), canonical(envelope["result"]), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, envelope["mac"]):
            raise ValueError("Unauthenticated checkpoint")
        result = envelope["result"]
        if result["stage"] != name or result["run_dir"] != str(self.run_dir):
            raise ValueError("Checkpoint belongs to another stage or run")
        log = self.run_dir / result["log"]
        if not log.resolve().is_relative_to(self.run_dir) or file_digest(log) != result["log_sha256"]:
            raise ValueError("Missing or modified checkpoint log")
        return result

    def status(self, profile):
        statuses = []
        valid = {}
        for stage in self.selected(profile):
            name = stage["id"]
            dependencies = {dep: valid.get(dep) for dep in stage.get("needs", [])}
            fingerprint = self.fingerprint(stage, dependencies)
            result = None
            reason = "No authenticated checkpoint"
            state = "invalidated"
            try:
                result = self.receipt(name)
                state = result["status"]
                reason = result.get("reason", "")
                if result["fingerprint"] != fingerprint or None in dependencies.values():
                    state, reason = "invalidated", "Inputs or prerequisite evidence changed"
                elif state == "passed":
                    work = self.run_dir / "work" / name
                    if inventory(work) != result["outputs"]:
                        state, reason = "invalidated", "Output identity changed"
                    else:
                        valid[name] = digest({"fingerprint": result["fingerprint"], "outputs": result["outputs"]})
                elif state == "running":
                    state, reason = "invalidated", "Interrupted stage requires a new attempt"
            except (OSError, ValueError, KeyError, TypeError) as error:
                reason = str(error)
            statuses.append({"stage": name, "status": state, "reason": reason,
                             "fingerprint": fingerprint,
                             "duration_seconds": result.get("duration_seconds") if result else None})
        return statuses

    @contextlib.contextmanager
    def lock(self):
        self.run_dir.mkdir(parents=True, exist_ok=True)
        lock_path = self.key_path.parent / "computer-mcp-release.lock"
        with lock_path.open("a+") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another release/check/cleanup operation owns this repository") from None
            yield

    def save(self, result):
        result["log_sha256"] = file_digest(self.run_dir / result["log"])
        envelope = {"result": result, "mac": hmac.new(self.key(True), canonical(result), hashlib.sha256).hexdigest()}
        atomic_json(self.run_dir / "receipts" / (result["stage"] + ".json"), envelope)
        atomic_json(self.run_dir / "history" / (result["attempt"] + ".json"), envelope)

    def run(self, profile, enforce_source=True):
        self.key(True)
        with self.lock():
            for stage in self.selected(profile):
                status = next(item for item in self.status(profile) if item["stage"] == stage["id"])
                if status["status"] == "passed":
                    print(json.dumps({"stage": stage["id"], "status": "reused"}), flush=True)
                    continue
                if enforce_source and source_identity(self.root) != self.source:
                    raise ValueError("Source changed during this run; resume with the current inputs")
                result = self.execute(stage, status["fingerprint"])
                if enforce_source and source_identity(self.root) != self.source:
                    result.update(status="invalidated", reason="Source changed while the stage was running")
                    self.save(result)
                print(json.dumps({key: result.get(key) for key in (
                    "stage", "status", "reason", "duration_seconds", "log")}), flush=True)
                if result["status"] != "passed":
                    return WAITING if result["status"] == "waiting_for_human" else 1
        return 0

    def execute(self, stage, fingerprint):
        name = stage["id"]
        attempt = name + "-" + uuid.uuid4().hex
        work = self.run_dir / "work" / name
        previous = None
        previous_matches = False
        # Prior outputs are retained separately; retries never erase failed evidence.
        if work.exists():
            prior_receipt = None
            try:
                prior_receipt = self.receipt(name)
                previous_matches = prior_receipt["fingerprint"] == fingerprint
            except (OSError, ValueError, KeyError):
                pass
            if previous_matches and inventory(work) != prior_receipt["outputs"]:
                raise ValueError("Modified checkpoint outputs must be investigated before resuming this stage")
            retained = self.run_dir / "retained" / attempt
            retained.parent.mkdir(parents=True, exist_ok=True)
            work.rename(retained)
            previous = retained
        work.mkdir(parents=True)
        log = self.run_dir / "logs" / (attempt + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        log.touch()
        result = {"stage": name, "attempt": attempt, "status": "running", "reason": "",
                  "fingerprint": fingerprint, "source": self.source, "environment": self.environment,
                  "run_dir": str(self.run_dir), "log": str(log.relative_to(self.run_dir)),
                  "started_at": time.time(), "outputs": {}}
        self.save(result)
        started = time.monotonic()
        environment = dict(os.environ, RELEASE_WORK_DIR=str(work), RELEASE_RUN_DIR=str(self.run_dir),
                           OUTPUT_DIR=str(work / "dist"), BUILD_ROOT=str(self.root / ".build/distribution"))
        environment.update(stage.get("environment", {}))
        if previous is not None and previous_matches:
            environment["RELEASE_PREVIOUS_WORK_DIR"] = str(previous)
        else:
            environment.pop("RELEASE_PREVIOUS_WORK_DIR", None)
        try:
            with log.open("ab", buffering=0) as stream:
                for command in stage["commands"]:
                    stream.write(("$ " + json.dumps(command) + "\n").encode())
                    remaining = stage["timeout_seconds"] - (time.monotonic() - started)
                    if remaining <= 0:
                        raise TimeoutError("Stage deadline exceeded")
                    process = subprocess.Popen(command, cwd=self.root, env=environment,
                                               stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        code = process.wait(timeout=remaining)
                    except BaseException:
                        # Killing the owned group also reaps grandchildren that outlive its leader.
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            pass
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        raise
                    if code:
                        result.update(status="waiting_for_human" if code == WAITING else "failed",
                                      reason=f"Command exited {code}; see the recorded log", exit_code=code)
                        break
                else:
                    result.update(status="passed", exit_code=0)
        except KeyboardInterrupt:
            result.update(status="invalidated", reason="Interrupted by operator", exit_code=130)
        except (OSError, TimeoutError, subprocess.TimeoutExpired) as error:
            result.update(status="failed", reason=str(error), exit_code=124)
        result["duration_seconds"] = round(time.monotonic() - started, 3)
        try:
            result["outputs"] = inventory(work)
        except ValueError as error:
            result.update(status="failed", reason=str(error))
        self.save(result)
        return result

    def cleanup(self, apply=False):
        self.key()
        with self.lock():
            actions = []
            for name in self.stages:
                path = self.run_dir / "work" / name
                if not path.exists():
                    continue
                try:
                    if self.stages[name].get("retain_outputs", False):
                        raise ValueError("Required candidate or delivery evidence is retained")
                    receipt = self.receipt(name)
                    if inventory(path) != receipt["outputs"]:
                        raise ValueError("Directory has unique or changed content")
                    check = subprocess.run(["/usr/sbin/lsof", "-t", "+D", str(path)],
                                           capture_output=True, timeout=30)
                    if check.returncode not in (0, 1) or check.stdout:
                        raise ValueError("Directory has running references or could not be checked")
                    size = sum(item.get("size", 0) for item in receipt["outputs"].values())
                    if apply:
                        shutil.rmtree(path)
                    actions.append({"path": str(path), "action": "removed" if apply else "would_remove", "bytes": size})
                except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                    actions.append({"path": str(path), "action": "retained", "reason": str(error)})
            return actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("plan", "run", "status", "resume", "publish", "cleanup"))
    parser.add_argument("--run", default="local", help="Local run identifier; receipts stay in .agent/releases/")
    parser.add_argument("--profile", default="ci")
    parser.add_argument("--apply", action="store_true", help="Apply cleanup; otherwise preview")
    parser.add_argument("--reuse-ci", action="store_true", help="Import matching checks from a trusted successful master CI run")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.run):
        parser.error("Invalid run identifier")
    definition = json.loads((ROOT / "Scripts/release-checks.json").read_text())
    profile = "publish" if args.operation == "publish" else args.profile
    if profile not in definition["profiles"]:
        parser.error("Unknown profile: " + profile)
    git_dir = Path(output(["git", "rev-parse", "--git-common-dir"], ROOT))
    if not git_dir.is_absolute():
        git_dir = ROOT / git_dir
    runner = Runner(ROOT, ROOT / ".agent/releases" / args.run, definition,
                    git_dir / "computer-mcp-release.key")
    if args.operation == "plan":
        print(json.dumps({"source": runner.source, "environment": runner.environment,
                          "stages": runner.selected(profile)}, indent=2))
        return 0
    if args.operation == "status":
        stages = runner.status(profile)
        print(json.dumps({"run": args.run, "stages": stages,
                          "summary": {state: sum(s["status"] == state for s in stages)
                                      for state in ("passed", "failed", "waiting_for_human", "invalidated")}}, indent=2))
        return 0
    if args.operation == "cleanup":
        print(json.dumps(runner.cleanup(args.apply), indent=2))
        return 0
    if args.reuse_ci:
        from candidate import reuse_ci
        reuse_ci(runner, profile)
    return runner.run(profile)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Release operation failed: {error}", file=sys.stderr)
        sys.exit(1)
