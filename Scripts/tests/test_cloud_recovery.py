import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1]))
import candidate

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).parents[1] / 'restore-cloud-release.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class CloudRecovery(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.run = {'id':42, 'run_attempt':2, 'head_sha':'a' * 40, 'head_branch':'master',
                    'event':'workflow_dispatch', 'path':candidate.WORKFLOW,
                    'head_repository':{'full_name':candidate.REPOSITORY}}
        self.artifacts = [{'id':1, 'name':'computer-mcp-candidate-42-1', 'expired':False},
                          {'id':2, 'name':'computer-mcp-candidate-42-2', 'expired':False}]
        self.steps = [{'name':name, 'conclusion':'success'} for name in (
            'Build, sign, notarize, and verify release', 'Preserve immutable signed candidate')]
        self.downloads = []
        for patcher in (patch.object(recovery, 'ROOT', self.root),
                        patch.dict(os.environ, {'GITHUB_RUN_ID':'42', 'GITHUB_RUN_ATTEMPT':'2', 'GITHUB_SHA':'a' * 40}),
                        patch.object(recovery.subprocess, 'run'),
                        patch.object(recovery, 'api', side_effect=self.api),
                        patch.object(recovery, 'download', side_effect=self.download)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def api(self, path):
        if path.endswith('/artifacts'):
            return {'artifacts':self.artifacts}
        if path.endswith('/jobs'):
            return {'jobs':[{'steps':self.steps}]}
        return self.run

    def download(self, run, work, commit):
        self.downloads.append(run['run_attempt'])
        (work / 'candidate.json').write_text('{}')
        (work / 'candidate.tar.gz').write_bytes(b'candidate')
        (work / 'dist').mkdir()
        (work / 'dist/Product.dmg').write_bytes(b'signed bytes')

    def test_retry_restores_prior_candidate_without_using_current_attempt(self):
        self.assertEqual(recovery.restore(None), (True, False))
        self.assertEqual(self.downloads, [1])
        self.assertEqual((self.root / 'dist/Product.dmg').read_bytes(), b'signed bytes')

    def test_first_dispatch_needs_no_recovery(self):
        with patch.dict(os.environ, {'GITHUB_RUN_ATTEMPT':'1'}):
            self.assertEqual(recovery.restore(None), (False, False))
        self.assertEqual(self.downloads, [])

    def test_wrong_source_missing_candidate_or_unverified_build_stops_recovery(self):
        self.run['head_sha'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'trusted master'):
            recovery.restore(None)
        self.run['head_sha'] = 'a' * 40
        self.steps[0]['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'protected build'):
            recovery.restore(None)
        self.artifacts.clear()
        with self.assertRaisesRegex(ValueError, 'no preserved'):
            recovery.restore(None)
        self.assertEqual(self.downloads, [])

    def test_publication_archive_must_belong_to_the_same_candidate(self):
        artifact = {'id':3, 'name':'computer-mcp-publication-42-1', 'expired':False}
        self.artifacts.append(artifact)
        archive = self.root / 'publication.zip'
        record = {'source_commit':'a' * 40, 'candidate':'42.1', 'assets':{'Product.dmg':'digest'}}
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr('publication-assets.json', json.dumps(record))
            stream.writestr('dist/Product.dmg', b'signed bytes')
        with patch.object(recovery, 'artifact_download', return_value=archive):
            self.assertEqual(recovery.restore(None), (True, True))
        self.assertEqual((self.root / '.agent/publication/dist/Product.dmg').read_bytes(), b'signed bytes')
        shutil.rmtree(self.root / 'dist')
        record['candidate'] = '42.2'
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr('publication-assets.json', json.dumps(record))
            stream.writestr('dist/Product.dmg', b'signed bytes')
        with patch.object(recovery, 'artifact_download', return_value=archive):
            with self.assertRaisesRegex(ValueError, 'another candidate'):
                recovery.restore(None)


if __name__ == '__main__':
    unittest.main()
