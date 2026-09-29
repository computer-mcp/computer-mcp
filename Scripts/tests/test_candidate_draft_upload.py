import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("draft_upload", SCRIPTS / "upload-candidate-draft.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DraftUploadTests(unittest.TestCase):
    def setUp(self):
        self.digest = "a" * 64
        self.asset = {"name": "app.dmg", "state": "uploaded", "digest": "sha256:" + self.digest}
        self.release = {"draft": True, "tag_name": "v1.3.0", "assets": []}

    def check(self):
        return module.draft_asset(self.release, "v1.3.0", "app.dmg", self.digest)

    def test_missing_draft_asset_may_be_uploaded(self):
        self.assertIsNone(self.check())

    def test_matching_asset_is_reused(self):
        self.release["assets"] = [self.asset]
        self.assertEqual(self.check(), self.asset)

    def test_public_release_is_never_repaired(self):
        self.release["draft"] = False
        with self.assertRaises(ValueError):
            self.check()

    def test_wrong_tag_is_rejected(self):
        self.release["tag_name"] = "v1.2.2"
        with self.assertRaises(ValueError):
            self.check()

    def test_changed_or_partial_asset_is_not_overwritten(self):
        for change in ({"digest": "sha256:" + "b" * 64}, {"state": "starter"}, {"digest": None}):
            with self.subTest(change=change):
                self.release["assets"] = [dict(self.asset, **change)]
                with self.assertRaises(ValueError):
                    self.check()

    def test_duplicate_identity_is_rejected(self):
        self.release["assets"] = [self.asset, self.asset]
        with self.assertRaises(ValueError):
            self.check()
