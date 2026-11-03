import json
import plistlib
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-upgrade.py'


class UpgradeReadbackTests(unittest.TestCase):
    def test_requires_same_host_in_old_and_new_storage(self):
        host = {'id': str(uuid.uuid4()), 'friendlyName': 'TEST-ONLY-CODEX-UPGRADE-HOST',
                'group': 'TEST-ONLY-CODEX-UPGRADE-FOLDER', 'host': '192.0.2.10', 'username': 'test', 'sshPort': 22}
        profiles = [{'id': str(uuid.uuid4())}, host]
        with tempfile.TemporaryDirectory() as directory:
            old, new = Path(directory) / 'old.plist', Path(directory) / 'new.plist'
            old.write_bytes(plistlib.dumps({'SelectiveRemote.connectionProfiles.v2': json.dumps(profiles).encode()}))
            new.write_bytes(plistlib.dumps({'SelectiveRemote.connectionProfiles.v2': json.dumps(profiles).encode(),
                                             'SelectiveRemote.native032.connectionProfiles.v2': json.dumps(profiles).encode()}))
            def run():
                return subprocess.run(['python3', str(SCRIPT), str(old), str(new)], capture_output=True, text=True)
            self.assertEqual(run().returncode, 0)
            changed = [profiles[0], {**host, 'host': '192.0.2.11'}]
            new.write_bytes(plistlib.dumps({'SelectiveRemote.connectionProfiles.v2': json.dumps(profiles).encode(),
                                             'SelectiveRemote.native032.connectionProfiles.v2': json.dumps(changed).encode()}))
            self.assertNotEqual(run().returncode, 0)
            changed_port = [profiles[0], {**host, 'sshPort': 2222}]
            new.write_bytes(plistlib.dumps({'SelectiveRemote.connectionProfiles.v2': json.dumps(profiles).encode(),
                                             'SelectiveRemote.native032.connectionProfiles.v2': json.dumps(changed_port).encode()}))
            self.assertNotEqual(run().returncode, 0)
