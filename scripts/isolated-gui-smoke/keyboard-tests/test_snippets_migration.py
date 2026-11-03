import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-snippets.py'
GROUPS = 'terminal.snippetGroups.v1'
TEMPLATES = 'terminal.commandTemplates.v1'
GROUP = {'id': 'group-1', 'name': 'TEST-ONLY-CODEX-SNIPPET-GROUP'}
SNIPPET = {'id': 'snippet-1', 'title': 'TEST-ONLY-CODEX-SNIPPET', 'command': 'TEST-ONLY-CODEX-COMMAND', 'groupID': 'group-1'}

class SnippetUpgradeReadback(unittest.TestCase):
    def test_requires_synthetic_group_snippet_and_unchanged_migrated_values(self):
        with tempfile.TemporaryDirectory() as directory:
            before, after = Path(directory) / 'before.plist', Path(directory) / 'after.plist'
            old = {'SelectiveRemote.' + GROUPS: json.dumps([GROUP]).encode(), 'SelectiveRemote.' + TEMPLATES: json.dumps([SNIPPET]).encode()}
            current = {**old, 'SelectiveRemote.native032.' + GROUPS: json.dumps([GROUP]).encode(), 'SelectiveRemote.native032.' + TEMPLATES: json.dumps([SNIPPET]).encode()}
            before.write_bytes(plistlib.dumps(old)); after.write_bytes(plistlib.dumps(current))
            def run(): return subprocess.run(['python3', str(SCRIPT), str(before), str(after)], capture_output=True)
            self.assertEqual(run().returncode, 0)
            bad = dict(current); bad['SelectiveRemote.native032.' + TEMPLATES] = json.dumps([{**SNIPPET, 'command': 'changed'}]).encode()
            after.write_bytes(plistlib.dumps(bad)); self.assertNotEqual(run().returncode, 0)
            bad = dict(current); bad['SelectiveRemote.native032.' + GROUPS] = json.dumps([]).encode()
            after.write_bytes(plistlib.dumps(bad)); self.assertNotEqual(run().returncode, 0)
            bad = dict(old); bad['SelectiveRemote.' + TEMPLATES] = json.dumps([]).encode()
            before.write_bytes(plistlib.dumps(bad)); after.write_bytes(plistlib.dumps(current)); self.assertNotEqual(run().returncode, 0)
