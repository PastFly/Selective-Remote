import json
import plistlib
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-rdp-baseline.py'
KEY = 'SelectiveRemote.connectionProfiles.v2'

class RDPBaselineTests(unittest.TestCase):
    def test_requires_exact_one_synthetic_rdp_profile(self):
        host = {'id': str(uuid.uuid4()), 'friendlyName': 'TEST-ONLY-CODEX-RDP', 'host': '192.0.2.11', 'connectionType': 'rdp'}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'baseline.plist'
            def run(): return subprocess.run(['python3', str(SCRIPT), str(path)], capture_output=True, text=True)
            path.write_bytes(plistlib.dumps({KEY: json.dumps([host]).encode()}))
            self.assertEqual(run().returncode, 0)
            path.write_bytes(plistlib.dumps({KEY: json.dumps([{**host, 'host': '192.0.2.12'}]).encode()}))
            self.assertNotEqual(run().returncode, 0)
            path.write_bytes(plistlib.dumps({KEY: json.dumps([host, host]).encode()}))
            self.assertNotEqual(run().returncode, 0)
