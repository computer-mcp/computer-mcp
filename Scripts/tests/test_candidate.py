import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate
import release


class CandidateTrust(unittest.TestCase):
    def test_interrupted_request_resumes_official_run_without_redispatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            previous, work = root / "previous", root / "work"
            previous.mkdir()
            work.mkdir()
            commit = "a" * 40
            record = {"source_commit": commit, "request_id": "original", "requested_at": time.time()}
            release.atomic_json(previous / "request.json", record)
            run = {"id": 42, "display_title": "Computer MCP candidate original", "head_sha": commit,
                   "head_branch": "master", "event": "workflow_dispatch", "path": candidate.WORKFLOW,
                   "head_repository": {"full_name": candidate.REPOSITORY}, "status": "waiting", "html_url": "fixture"}
            with patch.dict(os.environ, {"RELEASE_WORK_DIR": str(work), "RELEASE_INTERRUPTED_WORK_DIR": str(previous)}, clear=True), \
                    patch.object(candidate, "output", side_effect=[commit, "", commit + " refs/heads/master"]), \
                    patch.object(candidate, "api", return_value={"workflow_runs": [run]}) as api:
                self.assertEqual(candidate.request(), 75)
                self.assertEqual(api.call_count, 1)
                self.assertNotIn("dispatches", api.call_args.args[0])
                self.assertEqual(json.loads((work / "request.json").read_text()), dict(record, run_id=42))
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
            run = {"id": 1, "run_attempt": 1, "head_sha": "a" * 40, "path": ".github/workflows/ci.yml",
                   "head_branch": "master", "event": "push",
                   "head_repository": {"full_name": candidate.REPOSITORY}, "status": "completed", "conclusion": "success"}
            artifact = {"id": 2, "name": "check-report-1-1", "expired": False,
                        "digest": "sha256:" + release.file_digest(evidence)}

            def api(path):
                return {"workflow_runs": [run]} if "workflows" in path else {"artifacts": [artifact]}

            def download(*args, **kwargs):
                kwargs["stdout"].write(evidence.read_bytes())

            def target(name, environment):
                return release.Runner(root, root / name, definition, root / (name + "-key"),
                                      source={"commit": "a" * 40}, environment=environment)

            with patch.object(candidate, "api", side_effect=api), patch.object(candidate.subprocess, "run", side_effect=download):
                matching = target("matching", {"swift": "one"})
                candidate.reuse_ci(matching, "source")
                self.assertEqual(matching.status("source")[0]["status"], "passed")
                changed = target("changed", {"swift": "two"})
                candidate.reuse_ci(changed, "source")
                self.assertEqual(changed.status("source")[0]["status"], "invalidated")
                artifact["digest"] = "sha256:" + "0" * 64
                with self.assertRaisesRegex(ValueError, "immutable digest"):
                    candidate.reuse_ci(target("forged", {"swift": "one"}), "source")


if __name__ == "__main__":
    unittest.main()
