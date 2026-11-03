import json
import plistlib
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-rdp-upgrade.py'
LEGACY = 'SelectiveRemote.connectionProfiles.v2'
CURRENT = 'SelectiveRemote.native032.connectionProfiles.v2'

class RDPCredentialUpgradeTests(unittest.TestCase):
    def test_requires_all_rdp_profile_fields_and_legacy_preservation(self):
        value = {'id': str(uuid.uuid4()), 'friendlyName': 'TEST-ONLY-CODEX-RDP', 'host': '192.0.2.11', 'connectionType': 'rdp', 'gatewayHost': '192.0.2.12'}
        with tempfile.TemporaryDirectory() as directory:
            old, new = Path(directory) / 'old.plist', Path(directory) / 'new.plist'
            old_bytes = json.dumps([value]).encode()
            old.write_bytes(plistlib.dumps({LEGACY: old_bytes}))
            def write(current, legacy=old_bytes): new.write_bytes(plistlib.dumps({LEGACY: legacy, CURRENT: json.dumps(current).encode()}))
            def run(): return subprocess.run(['python3', str(SCRIPT), str(old), str(new)], capture_output=True)
            write([value]); self.assertEqual(run().returncode, 0)
            write([{**value, 'gatewayHost': '192.0.2.13'}]); self.assertNotEqual(run().returncode, 0)
            write([value], json.dumps([]).encode()); self.assertNotEqual(run().returncode, 0)
