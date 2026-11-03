import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'compare-legacy.py'
KEY = 'SelectiveRemote.connectionProfiles.v2'


class LegacyComparisonTests(unittest.TestCase):
    def test_detects_reordered_json_and_changed_data(self):
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / 'a.plist', Path(directory) / 'b.plist'
            a.write_bytes(plistlib.dumps({KEY: b'[{"a":1,"b":2}]'}))
            b.write_bytes(plistlib.dumps({KEY: b'[{"b":2,"a":1}]'}))
            def compare():
                result = subprocess.run(['python3', str(SCRIPT), str(a), str(b)], capture_output=True, text=True, check=True)
                return json.loads(result.stdout)
            first = compare()
            self.assertFalse(first['bytesEqual'])
            self.assertTrue(first['semanticEqual'])
            b.write_bytes(plistlib.dumps({KEY: b'[{"a":2,"b":2}]'}))
            self.assertFalse(compare()['semanticEqual'])
