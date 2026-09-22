import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import release

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).parents[1] / "publish-release.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublicationEvidence(unittest.TestCase):
    def test_installed_bytes_and_each_evidence_file_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, plugin = root / "App", root / "Plugin"
            app.mkdir()
            plugin.mkdir()
            (app / "binary").write_text("accepted-app")
            (plugin / "binary").write_text("accepted-plugin")
            plugin_record = {"installed_path": str(plugin), "files": release.inventory(plugin)}
            records = {"installed_runtime": "installed-runtime.json", "navigation": "navigation.json",
                       "workspace_operations": "workspace-operations.json", "plugin_integration": "plugin-integration.json"}
            for key, name in records.items():
                release.atomic_json(root / name, plugin_record if key == "plugin_integration" else {"status": "passed"})
            candidate = {"candidate": "123.1", "source_commit": "a" * 40, "archive_sha256": "b" * 64,
                         "version": {"version": "1.2.3", "build": 9},
                         "outputs": {"Computer MCP.app": release.inventory(app)}}
            acceptance = {**candidate, "status": "passed", "installed_path": str(app), "checks": {
                "artifact_identity": "passed", "signature_and_notarization": "passed", "native_permissions": "passed",
                **{key: release.file_digest(root / value) for key, value in records.items()}}}
            publisher.verify_acceptance(candidate, acceptance, root)
            for key in ("candidate", "source_commit", "archive_sha256", "version"):
                wrong = copy.deepcopy(acceptance)
                wrong[key] = "wrong"
                with self.subTest(key=key), self.assertRaises(ValueError):
                    publisher.verify_acceptance(candidate, wrong, root)
            for target in [root / name for name in records.values()] + [app / "binary", plugin / "binary"]:
                original = target.read_bytes()
                target.write_bytes(b"changed")
                with self.subTest(path=target.name), self.assertRaises(ValueError):
                    publisher.verify_acceptance(candidate, acceptance, root)
                target.write_bytes(original)
            (root / "navigation.json").unlink()
            with self.assertRaises(FileNotFoundError):
                publisher.verify_acceptance(candidate, acceptance, root)

    def test_partial_upload_resumes_without_replacing_bytes_and_publication_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = [root / "Product-ReleaseNotes.md", root / "Product.dmg"]
            for asset in assets:
                asset.write_text(asset.name)
            remote = {"draft": True, "assets": []}
            stored, uploads, edits = {}, [], []
            interrupt = True

            def command(arguments, **kwargs):
                nonlocal interrupt
                if arguments[:3] == ["gh", "release", "upload"]:
                    asset = Path(arguments[-1])
                    if asset.suffix == ".dmg" and interrupt:
                        interrupt = False
                        raise subprocess.CalledProcessError(1, arguments)
                    self.assertNotIn(asset.name, stored, "Existing assets must never be replaced")
                    uploads.append(asset.name)
                    stored[asset.name] = asset.read_bytes()
                    remote["assets"].append({"name": asset.name})
                elif arguments[:3] == ["gh", "release", "download"]:
                    name = arguments[arguments.index("--pattern") + 1]
                    (Path(arguments[arguments.index("--dir") + 1]) / name).write_bytes(stored[name])
                elif arguments[:3] == ["gh", "release", "edit"]:
                    edits.append(True)
                    remote["draft"] = False
                elif arguments[0] == "/usr/bin/curl":
                    target = Path(arguments[arguments.index("--output") + 1])
                    target.write_bytes(stored[target.name])
                else:
                    self.fail("Unexpected mutation or rebuild command: " + repr(arguments))

            with patch.object(publisher, "release_view", side_effect=lambda tag: remote), patch.object(publisher, "run", side_effect=command):
                with self.assertRaises(subprocess.CalledProcessError):
                    publisher.synchronize_assets("v1.2.3", assets, root)
                self.assertTrue(remote["draft"])
                publisher.synchronize_assets("v1.2.3", assets, root)
                publisher.synchronize_assets("v1.2.3", assets, root)
                self.assertEqual(uploads, [a.name for a in assets])
                self.assertEqual(len(edits), 1)
                stored[assets[0].name] = b"tampered"
                with self.assertRaisesRegex(ValueError, "differs"):
                    publisher.synchronize_assets("v1.2.3", assets, root)
                self.assertEqual(len(edits), 1)

    def test_public_release_missing_assets_fails_without_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "Product.dmg"
            asset.write_text("bytes")
            with patch.object(publisher, "release_view", return_value={"draft": False, "assets": []}), patch.object(publisher, "run") as command:
                with self.assertRaisesRegex(ValueError, "public release is incomplete"):
                    publisher.synchronize_assets("v1.2.3", [asset], root)
                command.assert_not_called()

    def test_authentication_failure_is_not_treated_as_missing_release(self):
        failure = subprocess.CompletedProcess([], 1, "", "HTTP 403: Forbidden")
        with patch.object(publisher.subprocess, "run", return_value=failure):
            with self.assertRaises(subprocess.CalledProcessError):
                publisher.release_view("v1.2.3")


if __name__ == "__main__":
    unittest.main()
