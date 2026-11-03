import json
import plistlib
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-mixed-writes.py'
OLD = 'SelectiveRemote.connectionProfiles.v2'
NEW = 'SelectiveRemote.native032.connectionProfiles.v2'


def host(name, ip):
    return {'id': str(uuid.uuid4()), 'friendlyName': name, 'group': 'TEST-ONLY-CODEX-MIXED-FOLDER',
            'host': ip, 'username': 'test'}


class MixedWrites(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.before, self.after = (Path(self.directory.name) / name for name in ('before.plist', 'after.plist'))

    def check(self, mode, before, after):
        for path, domain in ((self.before, before), (self.after, after)):
            path.write_bytes(plistlib.dumps({key: json.dumps(value).encode() for key, value in domain.items()}))
        return subprocess.run(['python3', str(SCRIPT), mode, str(self.before), str(self.after)], capture_output=True, text=True)

    def test_late_legacy_write_must_preserve_every_existing_profile(self):
        original = host('original', '192.0.2.10')
        late = host('TEST-ONLY-CODEX-LATE-HOST', '192.0.2.11')
        before = {OLD: [original], NEW: [original]}
        result = self.check('late', before, {OLD: [original, late], NEW: [original]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['baselineHost']['id'], late['id'].upper())
        self.assertNotEqual(self.check('late', before, {OLD: [late], NEW: [original]}).returncode, 0)
        self.assertNotEqual(self.check('late', before, {OLD: [original, late], NEW: []}).returncode, 0)

    def test_current_write_keeps_late_legacy_and_reports_visibility(self):
        original = host('original', '192.0.2.10')
        late = host('TEST-ONLY-CODEX-LATE-HOST', '192.0.2.11')
        current = host('TEST-ONLY-CODEX-CURRENT-HOST', '192.0.2.12')
        before = {OLD: [original, late], NEW: [original]}
        result = self.check('current', before, {OLD: [original, late], NEW: [original, current]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['lateLegacyProfilePresentInCurrent'])
        self.assertNotEqual(self.check('current', before, {OLD: [original], NEW: [original, current]}).returncode, 0)

    def test_live_process_writes_preserve_each_separate_collection(self):
        original = host('original', '192.0.2.10')
        old = host('TEST-ONLY-CODEX-LIVE-OLD', '192.0.2.13')
        new = host('TEST-ONLY-CODEX-LIVE-NEW', '192.0.2.14')
        before = {OLD: [original], NEW: [original]}
        after_old = {OLD: [original, old], NEW: [original]}
        after_both = {OLD: [original, old], NEW: [original, new]}
        self.assertEqual(self.check('live-old', before, after_old).returncode, 0)
        result = self.check('live-current', after_old, after_both)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['lateLegacyProfilePresentInCurrent'])
        self.assertNotEqual(self.check('live-current', after_old, {OLD: [original], NEW: [original, new]}).returncode, 0)


if __name__ == '__main__':
    unittest.main()
