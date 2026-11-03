import json
import plistlib
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-baseline.py'


class BaselineReadbackTests(unittest.TestCase):
    def run_fixture(self, profiles):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.plist'
            path.write_bytes(plistlib.dumps({'SelectiveRemote.connectionProfiles.v2': json.dumps(profiles).encode()}))
            return subprocess.run(['python3', str(SCRIPT), str(path), str(path)], capture_output=True, text=True)

    def test_unique_new_host_is_accepted(self):
        host = {'id': str(uuid.uuid4()), 'friendlyName': 'TEST-ONLY-CODEX-UPGRADE-HOST',
                'group': 'TEST-ONLY-CODEX-UPGRADE-FOLDER', 'host': '192.0.2.10', 'username': 'test'}
        self.assertEqual(self.run_fixture([{'id': str(uuid.uuid4())}, host]).returncode, 0)
        self.assertNotEqual(self.run_fixture([host]).returncode, 0)
        self.assertNotEqual(self.run_fixture([host, host]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
