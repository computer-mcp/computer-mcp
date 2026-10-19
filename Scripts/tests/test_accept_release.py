import copy
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
SPEC = importlib.util.spec_from_file_location("accept_release", Path(__file__).parents[1] / "accept-release.py")
accept_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(accept_release)


class InstalledPluginAcceptance(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "computer-mcp-plugin.toml").write_text("fixture")
        self.snapshot = {"state": {"revision": 4, "selected_installations": {}, "installations": []},
                         "bundled": [{"manifest": {"id": "fixture"}}]}
        self.report = {"plugin_id": "fixture", "revision": 4, "status": "passed", "version": "1.0.0",
                       "source": {"kind": "bundled", "root": self.root.as_uri()},
                       "scope": "configuration_and_files", "checks": [], "not_checked": ["connection"],
                       "checked_at": "2026-10-19T00:00:00Z"}

    def inspect(self, responses):
        with patch.object(accept_release, "command", side_effect=[json.dumps(value) for value in responses]) as command:
            result = accept_release.inspect_installed_plugin(Path("/fixture/computer-mcp"))
        self.assertEqual([call.args[0][1:] for call in command.call_args_list],
                         [["plugins", "list"], ["plugins", "doctor", "fixture"],
                          ["plugins", "doctor", "fixture"], ["plugins", "list"]])
        return result

    def test_bundled_package_is_checked_without_launching_a_vendor(self):
        later = dict(self.report, checked_at="2026-10-19T00:00:01Z")
        result = self.inspect([self.snapshot, self.report, later, self.snapshot])
        self.assertEqual(result["plugin_id"], "fixture")
        self.assertEqual(result["scope"], "configuration_and_files")
        self.assertEqual(result["not_checked"], ["connection"])

    def test_selected_artifact_uses_the_same_contract(self):
        self.snapshot["bundled"] = []
        self.snapshot["state"]["selected_installations"] = {"fixture": "installation"}
        self.snapshot["state"]["installations"] = [
            {"id": "installation", "plugin_id": "fixture", "source": {"kind": "artifact"}}]
        self.report["source"]["kind"] = "artifact"
        self.assertEqual(self.inspect([self.snapshot, self.report, self.report, self.snapshot])["status"], "passed")

    def test_unavailable_bundled_package_falls_back_to_a_healthy_installed_package(self):
        self.snapshot["bundled"] = [{"manifest": {"id": "optional"}}]
        self.snapshot["state"]["selected_installations"] = {"fixture": "installation"}
        self.snapshot["state"]["installations"] = [
            {"id": "installation", "plugin_id": "fixture", "source": {"kind": "artifact"}}]
        self.report["source"]["kind"] = "artifact"
        for status in ("failed", "unverified"):
            with self.subTest(status=status):
                report = dict(self.report, plugin_id="optional", status=status, checks=[{"status": status}])
                result = json.dumps(report)
                if status == "failed":
                    result = subprocess.CalledProcessError(1, "doctor", output=result.encode())
                responses = [json.dumps(self.snapshot), result,
                             json.dumps(self.report), json.dumps(self.report), json.dumps(self.snapshot)]
                with patch.object(accept_release, "command", side_effect=responses) as command:
                    result = accept_release.inspect_installed_plugin(Path("/fixture/computer-mcp"))
                self.assertEqual(result["plugin_id"], "fixture")
                self.assertEqual(result["unavailable_plugins"],
                                 [{"plugin_id": "optional", "status": status, "checks": report["checks"]}])
                self.assertEqual([call.args[0][1:] for call in command.call_args_list],
                                 [["plugins", "list"], ["plugins", "doctor", "optional"],
                                  ["plugins", "doctor", "fixture"], ["plugins", "doctor", "fixture"],
                                  ["plugins", "list"]])

    def test_missing_package_or_failed_doctor_cannot_pass(self):
        for snapshot, report in [(dict(self.snapshot, bundled=[]), self.report),
                                 (self.snapshot, dict(self.report, status="failed")),
                                 (self.snapshot, dict(self.report, status="unknown")),
                                 (self.snapshot, dict(self.report, revision=3))]:
            with self.subTest(snapshot=snapshot, report=report), self.assertRaises(ValueError):
                self.inspect([snapshot, report])

    def test_host_state_change_during_inspection_cannot_pass(self):
        changed = copy.deepcopy(self.snapshot)
        changed["state"]["revision"] += 1
        with self.assertRaisesRegex(ValueError, "changed during acceptance"):
            self.inspect([self.snapshot, self.report, self.report, changed])

    def test_file_change_during_inspection_cannot_pass(self):
        responses = iter([self.snapshot, self.report, self.report, self.snapshot])

        def command(arguments):
            value = next(responses)
            if value is self.snapshot and arguments[1:] == ["plugins", "list"]:
                marker = self.root / "changed"
                marker.write_text(marker.read_text() + "x" if marker.exists() else "x")
            return json.dumps(value)

        with patch.object(accept_release, "command", side_effect=command):
            with self.assertRaisesRegex(ValueError, "changed during acceptance"):
                accept_release.inspect_installed_plugin(Path("/fixture/computer-mcp"))
