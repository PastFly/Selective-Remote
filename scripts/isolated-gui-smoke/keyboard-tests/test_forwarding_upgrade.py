import json
import plistlib
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-forwarding.py'
LEGACY = 'SelectiveRemote.independentPortForwards.v1'
CURRENT = 'SelectiveRemote.native032.independentPortForwards.v1'

class ForwardingUpgradeTests(unittest.TestCase):
    def test_checks_synthetic_tunnel_and_all_migrated_fields(self):
        ident = str(uuid.uuid4())
        item = {'id': ident, 'rule': {'id': ident, 'name': 'TEST-ONLY-CODEX-FORWARD', 'kind': 'local'}, 'connection': {'kind': 'custom'}}
        with tempfile.TemporaryDirectory() as directory:
            before, after = Path(directory) / 'before.plist', Path(directory) / 'after.plist'
            old = json.dumps([item]).encode(); before.write_bytes(plistlib.dumps({LEGACY: old}))
            def baseline(): return subprocess.run(['python3', str(SCRIPT), str(before)], capture_output=True)
            def run(): return subprocess.run(['python3', str(SCRIPT), str(before), str(after)], capture_output=True)
            def write(new, legacy=old): after.write_bytes(plistlib.dumps({LEGACY: legacy, CURRENT: json.dumps(new).encode()}))
            self.assertEqual(baseline().returncode, 0)
            write([item]); self.assertEqual(run().returncode, 0)
            write([{**item, 'connection': {'kind': 'profile'}}]); self.assertNotEqual(run().returncode, 0)
            write([item], b'[]'); self.assertNotEqual(run().returncode, 0)
