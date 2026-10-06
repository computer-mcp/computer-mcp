import importlib.util
import json
import os
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
    def test_assembly_rejects_source_asset_and_tag_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / "dist").mkdir()
            asset = work / "dist/Product.dmg"
            asset.write_text("notarized package")
            record = {"source_commit":"a" * 40, "tag":"v1.2.3", "tag_object":"b" * 40,
                      "assets":{asset.name:release.file_digest(asset)}}
            release.atomic_json(work / "publication-assets.json", record)
            with patch.dict(os.environ, {"GITHUB_SHA":"a" * 40}), patch.object(publisher, "output", return_value="b" * 40):
                publisher.verify_assembly(work)
                asset.write_text("changed")
                with self.assertRaisesRegex(ValueError, "asset changed"):
                    publisher.verify_assembly(work)
                asset.write_text("notarized package")
                (work / "dist/unexpected").write_text("other bytes")
                with self.assertRaisesRegex(ValueError, "unexpected assets"):
                    publisher.verify_assembly(work)
                (work / "dist/unexpected").unlink()
                with patch.object(publisher, "output", return_value="c" * 40), self.assertRaisesRegex(ValueError, "tag identity"):
                    publisher.verify_assembly(work)
                with patch.dict(os.environ, {"GITHUB_SHA":"d" * 40}), self.assertRaisesRegex(ValueError, "another source"):
                    publisher.verify_assembly(work)

    def test_temporary_tag_key_is_removed_when_signing_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            with patch.object(publisher, "WORK", work), patch.object(publisher, "TAG_SIGNING_KEY", "fixture key"), \
                    patch.dict(os.environ, {"RELEASE_TAG_SIGNING_IDENTITY":"release@example.test"}), \
                    patch.object(publisher, "run", side_effect=subprocess.CalledProcessError(1, ["git"])):
                with self.assertRaises(subprocess.CalledProcessError):
                    publisher.sign_tag("v1.2.3", "a" * 40, work / "message")
                self.assertFalse((work / "tag-signing-key").exists())

    def test_secret_without_final_newline_can_sign_and_verify_a_git_tag(self):
        fixtures = Path(__file__).parents[2] / ".agent/test-signing"
        fixtures.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=fixtures) as temporary:
            root = Path(temporary)
            signing = root / "fixture-key"
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(signing)], check=True)
            secret = signing.read_text().rstrip("\r\n")
            trust = root / "allowed-signers"
            trust.write_text("release@example.test " + signing.with_suffix(".pub").read_text())
            signing.unlink()
            signing.with_suffix(".pub").unlink()
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"],
                           check=True, capture_output=True)
            message = root / "message"
            message.write_text("Fixture release\n")
            with patch.object(publisher, "ROOT", root), patch.object(publisher, "WORK", root), \
                    patch.object(publisher, "TAG_SIGNING_KEY", secret), \
                    patch.dict(os.environ, {"RELEASE_TAG_SIGNING_IDENTITY":"release@example.test"}):
                publisher.sign_tag("v1.2.3", "HEAD", message)
            subprocess.run(["git", "-C", str(root), "-c", "gpg.format=ssh", "-c",
                            "gpg.ssh.allowedSignersFile=" + str(trust), "verify-tag", "v1.2.3"], check=True)
            self.assertFalse((root / "tag-signing-key").exists())

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

    def test_draft_missing_from_tag_endpoint_is_found_without_creating_another_release(self):
        missing = subprocess.CompletedProcess([], 1, "", "HTTP 404: Not Found")
        draft = {"id": 123, "tag_name": "v1.2.3", "draft": True, "assets": []}
        with patch.object(publisher.subprocess, "run", return_value=missing), \
                patch.object(publisher.subprocess, "check_output", return_value=json.dumps([[], [draft]]).encode()):
            self.assertEqual(publisher.release_view("v1.2.3"), draft)
            self.assertIsNone(publisher.release_view("v1.2.4"))


if __name__ == "__main__":
    unittest.main()
