import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).parents[1] / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class Checkpoints(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.definition = {
            "profiles": {"ci": ["build", "accept", "independent"]},
            "stages": [self.stage("build"), self.stage("accept", ["build"]), self.stage("independent")],
        }
        self.runner = self.make_runner()

    def tearDown(self):
        self.temporary.cleanup()

    def stage(self, name, needs=None):
        return {"id": name, "needs": needs or [], "timeout_seconds": 10,
                "commands": [[sys.executable, "-c", "import os; from pathlib import Path; "
                              "Path(os.environ['RELEASE_WORK_DIR'], 'artifact').write_text('accepted bytes')"]]}

    def make_runner(self, **changes):
        return release.Runner(self.root, self.root / "run", changes.get("definition", self.definition),
                              self.root / "trust" / "key", source=changes.get("source", {"commit": "a" * 40}),
                              environment=changes.get("environment", {"toolchain": "one"}))

    def statuses(self, runner=None):
        return {s["stage"]: s["status"] for s in (runner or self.runner).status("ci")}

    def test_matching_success_reuses_without_new_attempts(self):
        self.assertEqual(self.runner.run("ci", enforce_source=False), 0)
        history = list((self.root / "run/history").iterdir())
        self.assertEqual(self.runner.run("ci", enforce_source=False), 0)
        self.assertEqual(history, list((self.root / "run/history").iterdir()))
        self.assertEqual(set(self.statuses().values()), {"passed"})

    def test_source_toolchain_and_check_changes_invalidate(self):
        self.runner.run("ci", enforce_source=False)
        for changes in ({"source": {"commit": "b" * 40}}, {"environment": {"toolchain": "two"}}):
            self.assertEqual(set(self.statuses(self.make_runner(**changes)).values()), {"invalidated"})
        changed = copy.deepcopy(self.definition)
        changed["stages"][0]["timeout_seconds"] = 9
        status = self.statuses(self.make_runner(definition=changed))
        self.assertEqual(status, {"build": "invalidated", "accept": "invalidated", "independent": "passed"})

    def test_missing_forged_and_changed_evidence_cannot_pass(self):
        self.runner.run("ci", enforce_source=False)
        receipt = self.root / "run/receipts/build.json"
        original = receipt.read_bytes()
        forged = json.loads(original)
        forged["result"]["source"] = {"commit": "f" * 40}
        receipt.write_text(json.dumps(forged))
        self.assertEqual(self.statuses()["build"], "invalidated")
        receipt.write_bytes(original)
        (self.root / "run/work/build/artifact").write_text("different bytes")
        self.assertEqual(self.statuses()["accept"], "invalidated")
        receipt.unlink()
        self.assertEqual(self.statuses()["build"], "invalidated")

    def test_failure_preserved_and_only_invalid_stages_resume(self):
        self.definition["stages"][1]["commands"] = [[sys.executable, "-c", "raise SystemExit(1)"]]
        self.assertEqual(self.runner.run("ci", enforce_source=False), 1)
        self.assertEqual(self.statuses()["accept"], "failed")
        self.definition["stages"][1] = self.stage("accept", ["build"])
        self.assertEqual(self.make_runner().run("ci", enforce_source=False), 0)
        results = [json.loads(p.read_text())["result"] for p in (self.root / "run/history").iterdir()]
        self.assertEqual(len([r for r in results if r["stage"] == "build"]), 1)
        self.assertIn("failed", [r["status"] for r in results if r["stage"] == "accept"])

    def test_waiting_for_required_human_action_is_not_pass(self):
        self.definition["stages"][0]["commands"] = [[sys.executable, "-c", "raise SystemExit(75)"]]
        self.assertEqual(self.runner.run("ci", enforce_source=False), 75)
        self.assertEqual(self.statuses()["build"], "waiting_for_human")
        self.assertNotEqual(self.statuses()["accept"], "passed")

    def test_deadline_kills_owned_process_group(self):
        self.definition["stages"][0].update(timeout_seconds=0.2, commands=[[sys.executable, "-c",
            "import os, signal, time; from pathlib import Path; "
            "Path(os.environ['RELEASE_WORK_DIR'], 'pid').write_text(str(os.getpid())); "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"]])
        self.assertEqual(self.runner.run("ci", enforce_source=False), 1)
        pid = int((self.root / "run/work/build/pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual(self.statuses()["build"], "failed")

    def test_cleanup_preserves_changed_content_and_evidence_and_is_idempotent(self):
        self.runner.run("ci", enforce_source=False)
        (self.root / "run/work/build/unique-source").write_text("keep me")
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"")):
            actions = self.runner.cleanup(apply=True)
            self.assertEqual([a["action"] for a in actions], ["retained", "removed", "removed"])
            self.assertEqual(len(self.runner.cleanup(apply=True)), 1)
        self.assertTrue((self.root / "run/work/build/unique-source").exists())
        self.assertTrue((self.root / "run/history").is_dir())

    def test_cleanup_refuses_active_directory(self):
        self.runner.run("ci", enforce_source=False)
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"123\n", b"")):
            self.assertTrue(all(a["action"] == "retained" for a in self.runner.cleanup(apply=True)))

    def test_concurrent_owner_blocks_mutation(self):
        self.runner.key(True)
        with self.runner.lock():
            with self.assertRaisesRegex(ValueError, "owns this repository"):
                self.make_runner().run("ci", enforce_source=False)

    def test_missing_output_directory_invalidates_success(self):
        self.runner.run("ci", enforce_source=False)
        shutil.rmtree(self.root / "run/work/build")
        self.assertEqual(self.statuses(), {"build": "invalidated", "accept": "invalidated", "independent": "passed"})

    def test_untrusted_retained_attempt_cannot_be_blindly_repeated(self):
        self.definition["stages"][0]["retain_outputs"] = True
        self.runner.run("ci", enforce_source=False)
        receipt = self.root / "run/receipts/build.json"
        original = receipt.read_bytes()
        for forged in (None, b'{}'):
            if forged is None:
                receipt.unlink()
            else:
                receipt.write_bytes(forged)
            with self.assertRaisesRegex(ValueError, "lack an authenticated checkpoint"):
                self.runner.run("ci", enforce_source=False)
            self.assertTrue((self.root / "run/work/build/artifact").is_file())
            receipt.write_bytes(original)

    def test_live_status_orphan_ownership_and_interrupted_resume(self):
        stage_script = self.root / "stage.py"
        stage_script.write_text('''import json, os, time
from pathlib import Path
root = Path(__file__).parent
work = Path(os.environ["RELEASE_WORK_DIR"])
(work / "pid").write_text(str(os.getpid()))
previous = os.environ.get("RELEASE_PREVIOUS_WORK_DIR") or os.environ.get("RELEASE_INTERRUPTED_WORK_DIR")
if previous:
    record = json.loads((Path(previous) / "request.json").read_text())
else:
    with (root / "dispatches").open("a") as stream:
        stream.write("dispatch\\n")
    record = {"request_id": "original-request"}
(work / "request.json").write_text(json.dumps(record))
print("Request persisted, operation in progress", flush=True)
while not (root / "finish").exists():
    time.sleep(0.01)
''')
        self.definition = {"profiles": {"ci": ["candidate"]}, "stages": [{
            "id": "candidate", "timeout_seconds": 20, "commands": [[sys.executable, str(stage_script)]]}]}
        self.runner = self.make_runner()
        configuration = self.root / "definition.json"
        configuration.write_text(json.dumps(self.definition))
        helper = self.root / "run.py"
        helper.write_text('''import importlib.util, json, sys
from pathlib import Path
root = Path(__file__).parent
spec = importlib.util.spec_from_file_location("release", sys.argv[1])
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
runner = release.Runner(root, root / "run", json.loads((root / "definition.json").read_text()),
                        root / "trust/key", source={"commit": "a" * 40}, environment={"toolchain": "one"})
raise SystemExit(runner.run("ci", enforce_source=False))
''')
        process = subprocess.Popen([sys.executable, str(helper), str(Path(release.__file__))],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child = None

        def wait_for(predicate):
            deadline = time.monotonic() + 5
            while not predicate():
                self.assertLess(time.monotonic(), deadline, "Fixture did not reach its bounded checkpoint")
                time.sleep(0.01)

        def child_exited():
            try:
                os.kill(child, 0)
                return False
            except ProcessLookupError:
                return True

        try:
            work = self.root / "run/work/candidate"
            wait_for(lambda: (work / "request.json").exists())
            child = int((work / "pid").read_text())
            self.assertEqual(os.getpgid(child), child)
            self.assertEqual(self.statuses()["candidate"], "running")
            process.kill()
            process.wait(timeout=5)
            self.assertEqual(self.statuses()["candidate"], "running")
            with self.assertRaisesRegex(ValueError, "still owns this stage"):
                self.runner.run("ci", enforce_source=False)
            self.assertEqual(self.runner.cleanup(apply=True)[0]["action"], "retained")
            os.killpg(child, signal.SIGTERM)
            wait_for(child_exited)
            self.assertEqual(self.statuses()["candidate"], "invalidated")
            (self.root / "finish").touch()
            self.assertEqual(self.runner.run("ci", enforce_source=False), 0)
            self.assertEqual((self.root / "dispatches").read_text().splitlines(), ["dispatch"])
            self.assertEqual(self.statuses()["candidate"], "passed")
            records = [json.loads(path.read_text())["result"] for path in (self.root / "run/history").iterdir()]
            self.assertEqual(sorted(r["status"] for r in records), ["passed", "running"])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if child is not None and not child_exited():
                os.killpg(child, signal.SIGKILL)


class CandidateReuse(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        self.git("init", "-b", "master")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Release fixture")
        self.git("config", "commit.gpgsign", "false")
        (self.root / ".gitignore").write_text(".agent/\n")
        for name in ("Sources/Product.swift", "Scripts/build-app.sh", "Package.resolved",
                     "Version.json", "Scripts/verify-app-navigation.swift"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("original")
        self.commit()
        self.original = release.source_identity(self.root)
        subprocess.run(["git", "init", "--bare", str(self.base / "remote")], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.git("remote", "add", "origin", str(self.base / "remote"))
        self.git("push", "origin", "master")
        candidate = {"id": "candidate", "timeout_seconds": 10, "retain_outputs": True,
                     "commands": [[sys.executable, "-c", "import os,json; from pathlib import Path; "
                                   "Path(os.environ['RELEASE_WORK_DIR'], 'candidate.json').write_text(json.dumps("
                                   + repr({"source_commit": self.original["commit"]}) + "))"]]}
        accept = {"id": "acceptance", "needs": ["candidate"], "timeout_seconds": 10,
                  "commands": [[sys.executable, "-c", "pass"]]}
        self.definition = {"profiles": {"acceptance": ["acceptance"]}, "stages": [candidate, accept]}
        self.runner = self.make_runner()
        self.assertEqual(self.runner.run("acceptance"), 0)
        self.receipt = self.root / ".agent/run/receipts/candidate.json"
        self.original_receipt = self.receipt.read_bytes()
        (self.root / "Scripts/verify-app-navigation.swift").write_text("correct row selection")
        self.commit()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.root, stderr=subprocess.PIPE).decode().strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-m", "Fixture revision")

    def make_runner(self, **kwargs):
        return release.Runner(self.root, self.root / ".agent/run", self.definition,
                              self.root / ".git/key", environment={"toolchain": "one"}, **kwargs)

    def test_check_revision_reuses_artifact_and_rechecks_acceptance(self):
        runner = self.make_runner()
        runner.bind_candidate()
        self.assertEqual(self.receipt.read_bytes(), self.original_receipt)
        self.assertEqual([s["status"] for s in runner.status("acceptance")], ["passed", "invalidated"])
        self.assertEqual(runner.run("acceptance"), 0)
        restored = self.make_runner()
        self.assertEqual(restored.candidate_source, self.original)
        self.assertEqual([s["status"] for s in restored.status("acceptance")], ["passed", "passed"])
        self.assertEqual(len(list((self.root / ".agent/run/history").glob("candidate-*.json"))), 1)
        self.assertEqual(self.receipt.read_bytes(), self.original_receipt)
        (self.root / ".agent/run/work/candidate/candidate.json").write_text("changed")
        with self.assertRaisesRegex(ValueError, "without dispatching"):
            restored.run("acceptance")
        self.assertEqual(len(list((self.root / ".agent/run/history").glob("candidate-*.json"))), 1)

    def test_product_build_dependency_and_version_changes_refuse_reuse(self):
        for name in ("Sources/Product.swift", "Scripts/build-app.sh", "Package.resolved", "Version.json"):
            with self.subTest(name=name):
                (self.root / name).write_text("changed input")
                self.commit()
                with self.assertRaisesRegex(ValueError, "Candidate build inputs changed"):
                    self.make_runner().bind_candidate()
                self.git("revert", "--no-edit", "HEAD")

    def test_changed_toolchain_definition_dirty_source_and_forged_receipt_refuse_reuse(self):
        (self.root / "Scripts/verify-app-navigation.swift").write_text("uncommitted")
        with self.assertRaisesRegex(ValueError, "clean checks"):
            self.make_runner().bind_candidate()
        self.git("restore", "Scripts/verify-app-navigation.swift")
        runner = self.make_runner()
        runner.environment = {"toolchain": "different"}
        with self.assertRaisesRegex(ValueError, "unchanged authenticated"):
            runner.bind_candidate()
        self.definition["stages"][0]["timeout_seconds"] = 9
        with self.assertRaisesRegex(ValueError, "unchanged authenticated"):
            self.make_runner().bind_candidate()
        self.definition["stages"][0]["timeout_seconds"] = 10
        envelope = json.loads(self.original_receipt)
        envelope["result"]["source"]["commit"] = "f" * 40
        self.receipt.write_text(json.dumps(envelope))
        with self.assertRaisesRegex(ValueError, "Unauthenticated"):
            self.make_runner().bind_candidate()

    def test_reuse_binding_rejects_tampering_and_new_check_identity(self):
        self.make_runner().bind_candidate()
        binding = self.root / ".agent/run/candidate-reuse.json"
        original = binding.read_bytes()
        data = json.loads(original)
        data["payload"]["candidate_source"]["commit"] = "f" * 40
        binding.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "Unauthenticated"):
            self.make_runner()
        binding.write_bytes(original)
        (self.root / "Scripts/verify-app-navigation.swift").write_text("another check revision")
        self.commit()
        with self.assertRaisesRegex(ValueError, "reuse inputs changed"):
            self.make_runner()
        revised = self.make_runner(rebind_candidate=True)
        revised.bind_candidate()
        self.assertEqual(self.receipt.read_bytes(), self.original_receipt)
        self.assertEqual([s["status"] for s in revised.status("acceptance")], ["passed", "invalidated"])


if __name__ == "__main__":
    unittest.main()
