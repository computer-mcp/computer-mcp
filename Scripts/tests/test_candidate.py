import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate
import release


class CandidateTrust(unittest.TestCase):
    def test_runner_resumes_interrupted_candidate_through_protected_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "consumer.py"
            helper.write_text('''import json
import os
from pathlib import Path
import sys
import time
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import candidate
import release

root = Path(__file__).parent
commit = "a" * 40
if sys.argv[2] == "worker":
    def api(path, *arguments):
        if path.endswith("/dispatches"):
            with (root / "dispatches").open("a") as stream:
                print(arguments[-1].split("=", 1)[1], file=stream)
            return None
        assert path.startswith("actions/workflows/release-gate.yml/runs?")
        request_id = (root / "dispatches").read_text().strip()
        return {"workflow_runs": [{
            "id": 42, "display_title": "Computer MCP release " + request_id,
            "head_sha": commit, "head_branch": "master", "event": "workflow_dispatch",
            "path": candidate.WORKFLOW, "head_repository": {"full_name": candidate.REPOSITORY},
            "status": "completed" if (root / "finish").exists() else "in_progress",
            "conclusion": "success", "html_url": "fixture",
        }]}

    def download(run, work, source):
        release.atomic_json(work / "candidate.json", {"run_id": run["id"], "source_commit": source})

    clock = iter([0, 13 * 60 * 60])
    with patch.object(candidate, "api", side_effect=api), \\
            patch.object(candidate, "output", side_effect=[commit, "", commit + " refs/heads/master"]), \\
            patch.object(candidate, "download", side_effect=download), \\
            patch.object(candidate, "time", SimpleNamespace(monotonic=lambda: next(clock), time=time.time, sleep=time.sleep)):
        raise SystemExit(candidate.request())

configuration = json.loads((Path(sys.argv[1]) / "release-checks.json").read_text())
stage = next(stage for stage in configuration["stages"] if stage["id"] == "candidate")
stage["commands"] = [[sys.executable, "-B", __file__, sys.argv[1], "worker"]]
definition = {"profiles": {"publish": ["candidate"]}, "stages": [stage]}
runner = release.Runner(root, root / "run", definition, root / "trust" / "key",
                        source={"commit": commit}, environment={})
raise SystemExit(runner.run("publish", enforce_source=False))
''')
            command = [sys.executable, "-B", str(helper), str(Path(candidate.__file__).parent), "runner"]
            work = root / "run" / "work" / "candidate"
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
                try:
                    deadline = time.monotonic() + 5
                    request = {}
                    while time.monotonic() < deadline and process.poll() is None:
                        if (work / "request.json").exists():
                            request = json.loads((work / "request.json").read_text())
                            if request.get("run_id") == 42:
                                break
                        time.sleep(0.01)
                    self.assertEqual(request.get("run_id"), 42)
                    process.send_signal(signal.SIGINT)
                    output, _ = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 1, output)
                    self.assertIn("Interrupted by operator", output)
                finally:
                    if process.poll() is None:
                        process.send_signal(signal.SIGINT)
                        process.wait(timeout=5)
            (root / "finish").touch()
            resumed = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
            self.assertEqual((root / "dispatches").read_text().splitlines(), [request["request_id"]])
            self.assertEqual(json.loads((work / "request.json").read_text()), request)
            self.assertEqual(json.loads((work / "candidate.json").read_text())["run_id"], 42)

    def test_interrupted_and_timed_out_waits_resume_without_redispatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            previous, work = root / "previous", root / "work"
            previous.mkdir()
            work.mkdir()
            commit = "a" * 40
            record = {"source_commit": commit, "request_id": "original", "requested_at": time.time()}
            release.atomic_json(previous / "request.json", record)
            run = {"id": 42, "display_title": "Computer MCP release original", "head_sha": commit,
                   "head_branch": "master", "event": "workflow_dispatch", "path": candidate.WORKFLOW,
                   "head_repository": {"full_name": candidate.REPOSITORY}, "status": "in_progress", "html_url": "fixture"}
            with patch.dict(os.environ, {"RELEASE_WORK_DIR": str(work), "RELEASE_INTERRUPTED_WORK_DIR": str(previous)}, clear=True), \
                    patch.object(candidate, "output", side_effect=[commit, "", commit + " refs/heads/master"]), \
                    patch.object(candidate, "api", return_value={"workflow_runs": [run]}) as api, \
                    patch.object(candidate.time, "monotonic", side_effect=[0, 0, candidate.RELEASE_WAIT_SECONDS]), \
                    patch.object(candidate.time, "sleep"):
                with self.assertRaisesRegex(TimeoutError, r"request original\. Resume with the same --run"):
                    candidate.request()
                api.assert_called_once()
                self.assertNotIn("dispatches", api.call_args.args[0])
                self.assertEqual(json.loads((work / "request.json").read_text()), dict(record, run_id=42))
            resumed = root / "resumed"
            resumed.mkdir()
            run["status"] = "waiting"
            with patch.dict(os.environ, {"RELEASE_WORK_DIR": str(resumed), "RELEASE_PREVIOUS_WORK_DIR": str(work)}, clear=True), \
                    patch.object(candidate, "output", side_effect=[commit, "", commit + " refs/heads/master"]), \
                    patch.object(candidate, "api", return_value={"workflow_runs": [run]}) as api:
                self.assertEqual(candidate.request(), 75)
                self.assertEqual(api.call_count, 1)
                self.assertNotIn("dispatches", api.call_args.args[0])
                self.assertEqual(json.loads((resumed / "request.json").read_text()), dict(record, run_id=42))
            record["source_commit"] = "b" * 40
            release.atomic_json(previous / "request.json", record)
            with patch.dict(os.environ, {"RELEASE_WORK_DIR": str(work), "RELEASE_INTERRUPTED_WORK_DIR": str(previous)}, clear=True), \
                    patch.object(candidate, "output", side_effect=[commit, "", commit + " refs/heads/master"]), \
                    patch.object(candidate, "api") as api:
                with self.assertRaisesRegex(ValueError, "another commit"):
                    candidate.request()
                api.assert_not_called()

    def test_only_matching_master_dispatch_is_trusted(self):
        run = {"head_sha": "a" * 40, "head_branch": "master", "event": "workflow_dispatch",
               "path": candidate.WORKFLOW, "head_repository": {"full_name": candidate.REPOSITORY}}
        candidate.verify_run(run, "a" * 40)
        for key, value in (("head_sha", "b" * 40), ("head_branch", "feature"), ("event", "pull_request"),
                           ("path", ".github/workflows/untrusted.yml"), ("head_repository", {"full_name": "fork/project"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                candidate.verify_run(dict(run, **{key: value}), "a" * 40)

    def test_archive_preserves_modes_and_rejects_traversal_and_external_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, link in (("../escape", None), ("dist/escape", "/tmp")):
                archive = root / "unsafe.tar.gz"
                with tarfile.open(archive, "w:gz") as stream:
                    member = tarfile.TarInfo(name)
                    if link:
                        member.type, member.linkname = tarfile.SYMTYPE, link
                    stream.addfile(member)
                with self.assertRaises(ValueError):
                    candidate.extract_bundle(archive, root / "out")
            archive = root / "safe.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("dist/App/cli")
                member.mode, member.size = 0o755, 4
                stream.addfile(member, io.BytesIO(b"tool"))
            candidate.extract_bundle(archive, root / "out")
            executable = root / "out/dist/App/cli"
            self.assertEqual(executable.read_bytes(), b"tool")
            self.assertEqual(executable.stat().st_mode & 0o777, 0o755)

    def ci_run(self, **changes):
        return dict({"id": 1, "run_attempt": 1, "head_sha": "a" * 40, "path": ".github/workflows/ci.yml",
                     "head_branch": "master", "event": "push", "head_repository": {"full_name": candidate.REPOSITORY},
                     "status": "completed", "conclusion": "success", "html_url": "fixture"}, **changes)

    def test_wait_job_finds_concurrent_ci_and_waits_past_healthy_suite_duration(self):
        run = self.ci_run()
        pending = dict(run, status="in_progress", conclusion=None)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            with patch.dict(os.environ, {"GITHUB_SHA": run["head_sha"], "GITHUB_OUTPUT": str(output)}), \
                    patch.object(candidate, "api", side_effect=[{"workflow_runs": []}, {"workflow_runs": [pending]}, pending, run]) as api, \
                    patch.object(candidate.time, "monotonic", side_effect=[0, 0, 60, 180 * 60, 200 * 60]), \
                    patch.object(candidate.time, "sleep"):
                candidate.write_ci_selection()
            self.assertEqual(output.read_text(), "run=1\n")
            self.assertEqual([call.args[0] for call in api.call_args_list],
                             [candidate.MASTER_CI_RUNS, candidate.MASTER_CI_RUNS, "actions/runs/1", "actions/runs/1"])

    def test_pending_master_ci_expires_without_using_source_fallback(self):
        run = self.ci_run(status="in_progress", conclusion=None)
        with patch.object(candidate, "api", return_value={"workflow_runs": [run]}) as api, \
                patch.object(candidate.time, "monotonic", side_effect=[0, candidate.CI_WAIT_SECONDS]):
            with self.assertRaisesRegex(TimeoutError, "has not completed"):
                candidate.wait_for_ci(run["head_sha"])
            api.assert_called_once()

    def test_missing_run_selects_source_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            with patch.dict(os.environ, {"GITHUB_SHA": "a" * 40, "GITHUB_OUTPUT": str(output)}), \
                    patch.object(candidate, "api", return_value={"workflow_runs": []}) as api, \
                    patch.object(candidate.time, "monotonic", side_effect=[0, 120]):
                candidate.write_ci_selection()
                api.assert_called_once()
                api.reset_mock()
                candidate.reuse_ci(SimpleNamespace(source={"commit": "a" * 40}), "source", "none")
                api.assert_not_called()
            self.assertEqual(output.read_text(), "run=none\n")

    def test_both_jobs_reject_failed_ci_and_import_checks_exact_run_identity(self):
        runner = SimpleNamespace(source={"commit": "a" * 40})
        failed_run = self.ci_run(conclusion="failure")
        with patch.object(candidate, "api", return_value={"workflow_runs": [failed_run]}):
            with self.assertRaisesRegex(ValueError, "CI failed"):
                candidate.wait_for_ci(runner.source["commit"])
        for run, reason in ((failed_run, "CI failed"), (self.ci_run(id=2), "identity changed"),
                            (self.ci_run(head_sha="b" * 40), "Untrusted CI"),
                            (self.ci_run(status="in_progress"), "has not completed")):
            with self.subTest(run=run), patch.object(candidate, "api", return_value=run) as api:
                with self.assertRaisesRegex(ValueError, reason):
                    candidate.reuse_ci(runner, "source", "1")
                api.assert_called_once_with("actions/runs/1")

    def test_ci_reuse_requires_trusted_artifact_and_exact_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            definition = {"profiles": {"source": ["check"]}, "stages": [
                {"id": "check", "commands": [[sys.executable, "-c", "print('checked')"]], "timeout_seconds": 5}]}
            origin = release.Runner(root, root / "origin", definition, root / "origin-key",
                                    source={"commit": "a" * 40}, environment={"swift": "one"})
            self.assertEqual(origin.run("source", enforce_source=False), 0)
            evidence = root / "evidence.zip"
            with zipfile.ZipFile(evidence, "w") as stream:
                for parent in ("history", "logs"):
                    for path in (origin.run_dir / parent).iterdir():
                        stream.write(path, str(path.relative_to(origin.run_dir)))
            run = self.ci_run()
            artifact = {"id": 2, "name": "check-report-1-1", "expired": False,
                        "digest": "sha256:" + release.file_digest(evidence)}

            def api(path):
                if path == "actions/runs/1":
                    return run
                self.assertEqual(path, "actions/runs/1/artifacts")
                return {"artifacts": [artifact]}

            def download(*args, **kwargs):
                kwargs["stdout"].write(evidence.read_bytes())

            def target(name, environment):
                return release.Runner(root, root / name, definition, root / (name + "-key"),
                                      source={"commit": "a" * 40}, environment=environment)

            with patch.object(candidate, "api", side_effect=api), patch.object(candidate.subprocess, "run", side_effect=download):
                matching = target("matching", {"swift": "one"})
                candidate.reuse_ci(matching, "source", "1")
                self.assertEqual(matching.status("source")[0]["status"], "passed")
                changed = target("changed", {"swift": "two"})
                candidate.reuse_ci(changed, "source", "1")
                self.assertEqual(changed.status("source")[0]["status"], "invalidated")
                self.assertEqual(changed.run("source", enforce_source=False), 0)
                artifact["digest"] = "sha256:" + "0" * 64
                with self.assertRaisesRegex(ValueError, "immutable digest"):
                    candidate.reuse_ci(target("forged", {"swift": "one"}), "source", "1")
                artifact["expired"] = True
                missing = target("missing", {"swift": "one"})
                candidate.reuse_ci(missing, "source", "1")
                self.assertEqual(missing.run("source", enforce_source=False), 0)


if __name__ == "__main__":
    unittest.main()
