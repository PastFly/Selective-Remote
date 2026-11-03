import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-downgrade.py'
LEGACY = 'SelectiveRemote.connectionProfiles.v2'
CURRENT = 'SelectiveRemote.native032.connectionProfiles.v2'

class DowngradeReadbackTests(unittest.TestCase):
    def test_reopen_must_preserve_both_collections(self):
        with tempfile.TemporaryDirectory() as directory:
            before, after = Path(directory) / 'before.plist', Path(directory) / 'after.plist'
            def write(path, legacy, current):
                path.write_bytes(plistlib.dumps({LEGACY: json.dumps(legacy).encode(), CURRENT: json.dumps(current).encode()}))
            original = [{'id': 'x', 'host': '192.0.2.10'}]
            write(before, original, original)
            write(after, original, original)
            def run():
                return subprocess.run(['python3', str(SCRIPT), str(before), str(after)], capture_output=True)
            self.assertEqual(run().returncode, 0)
            write(after, original, [{'id': 'x', 'host': '192.0.2.11'}])
            self.assertNotEqual(run().returncode, 0)
            write(after, [], original)
            self.assertNotEqual(run().returncode, 0)
