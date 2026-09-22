import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("product_version", Path(__file__).resolve().parents[1] / "version.py")
version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = {"schema_version": 1, "version": "2.3.4", "build": 19}
        (self.root / version.DECLARATION).write_text(json.dumps(self.data))
        info = self.root / version.PLIST
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "old", "CFBundleVersion": "1", "CFBundleIdentifier": "fixture"}))
        (self.root / version.SWIFT).parent.mkdir(parents=True)
        version.generate(self.root, self.data)
        self.options = argparse.Namespace(base=None, tag=None, cli=None, app=None, dependencies=False)

    def test_check_is_read_only_and_rejects_both_forms_of_drift(self):
        paths = [self.root / p for p in (version.DECLARATION, version.PLIST, version.SWIFT)]
        before = [p.read_bytes() for p in paths]
        self.assertEqual(version.check(self.root, self.options)["status"], "passed")
        self.assertEqual(before, [p.read_bytes() for p in paths])
        for path in paths[1:]:
            with self.subTest(path=path):
                original = path.read_text()
                path.write_text(original.replace("2.3.4", "2.3.5"))
                with self.assertRaises(ValueError):
                    version.check(self.root, self.options)
                self.assertIn("2.3.5", path.read_text())
                path.write_text(original)

    def test_source_is_required_and_invalid_versions_are_not_guessed(self):
        for field, value in (("version", "02.3.4"), ("version", "2.3"), ("build", True), ("build", 0)):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                version.declaration({**self.data, field: value})
        (self.root / version.DECLARATION).unlink()
        with self.assertRaises(FileNotFoundError):
            version.read(self.root)

    def test_candidate_revision_does_not_consume_a_patch_version(self):
        proposed = version.check_bump(self.data, "2.3.4", 20, "candidate")
        self.assertEqual(proposed["version"], self.data["version"])
        for target, build, kind in (("2.3.5", 20, "candidate"), ("2.4.0", 20, "fix"), ("2.3.4", 19, "candidate"), ("2.3.3", 20, "fix")):
            with self.subTest(target=target, kind=kind), self.assertRaises(ValueError):
                version.check_bump(self.data, target, build, kind)

    def test_version_and_build_regressions_are_rejected(self):
        for current in ({**self.data, "version": "2.3.3"}, {**self.data, "build": 18}, {**self.data, "version": "2.3.5"}):
            with self.subTest(current=current), self.assertRaises(ValueError):
                version.check_progress(current, self.data)

    def test_actual_cli_and_package_identity_are_checked(self):
        app = self.root / "Fixture.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        cli = resources / "computer-mcp"
        cli.write_text("#!/bin/sh\nprintf '2.3.4 (19)\\n'\n")
        cli.chmod(0o700)
        (app / "Contents/Info.plist").write_bytes((self.root / version.PLIST).read_bytes())
        self.options.app = app
        version.check(self.root, self.options)
        cli.write_text("#!/bin/sh\nprintf '2.3.4 (18)\\n'\n")
        with self.assertRaisesRegex(ValueError, "Embedded CLI"):
            version.check(self.root, self.options)

    def test_dependency_tag_must_identify_the_locked_commit(self):
        url = "https://example.invalid/dependency.git"
        revision = "a" * 40
        pin = {"identity": "dependency", "location": url, "state": {"version": "0.4.0", "revision": revision}}
        (self.root / "Package.resolved").write_text(json.dumps({"pins": [pin]}))
        package = {"dependencies": [{"sourceControl": [{"identity": "dependency", "location": {"remote": [{"urlString": url}]}, "requirement": {"exact": ["0.4.0"]}}]}]}
        for remote, passed in ((revision + "\trefs/tags/0.4", True), ("b" * 40 + "\trefs/tags/v0.4.0", False), (revision + "\trefs/tags/0.4\n" + "b" * 40 + "\trefs/tags/0.4.0", False)):
            with self.subTest(remote=remote), patch.object(version, "run", side_effect=[json.dumps(package), remote]):
                if passed:
                    self.assertEqual(version.check_dependencies(self.root)[0]["revision"], revision)
                else:
                    with self.assertRaisesRegex(ValueError, "locked commit"):
                        version.check_dependencies(self.root)
        package["dependencies"][0]["sourceControl"][0]["requirement"]["exact"] = ["0.5.0"]
        with patch.object(version, "run", return_value=json.dumps(package)):
            with self.assertRaisesRegex(ValueError, "Exact dependency"):
                version.check_dependencies(self.root)

    def test_existing_formal_version_cannot_be_rebuilt_in_place(self):
        run = lambda *args: subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)
        run("init", "--quiet")
        run("add", ".")
        run("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Fixture")
        run("tag", "v2.3.4")
        result = subprocess.run(["python3", str(Path(version.__file__)), "--root", str(self.root), "update", "--version", "2.3.4", "--build", "20", "--kind", "candidate", "--reason", "candidate rebuild"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable", result.stderr)
        self.assertEqual(version.read(self.root), self.data)


if __name__ == "__main__":
    unittest.main()
