import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
