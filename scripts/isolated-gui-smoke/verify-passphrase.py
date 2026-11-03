import json
import os
import plistlib
import sys
from pathlib import Path

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('USER') != 'runner':
    raise SystemExit('synthetic runner identity required')
temp = Path(os.environ['RUNNER_TEMP'])
if sys.argv[1:] != [str(temp / 'passphrase-before.plist'), str(temp / 'passphrase-after.plist')]:
    raise SystemExit('synthetic fixture paths required')
with open(sys.argv[1], 'rb') as file:
    before = plistlib.load(file)
with open(sys.argv[2], 'rb') as file:
    after = plistlib.load(file)
legacy_records = 'SelectiveRemote.sshKeys.v1'
legacy_ids = 'SelectiveRemote.storedSSHKeyPassphrases.v1'
new_records = 'SelectiveRemote.native032.sshKeys.v1'
new_ids = 'SelectiveRemote.native032.storedSSHKeyPassphrases.v1'
records = json.loads(before[legacy_records])
assert len(records) == 1 and records[0]['name'] == 'TEST-ONLY-CODEX-SSH-KEY'
assert records[0]['privateKeyPath'] == str(temp / 'ssh-key-fixture' / 'key')
assert before[legacy_ids] == [records[0]['id']]
assert json.loads(after[legacy_records]) == records
assert after[legacy_ids] == before[legacy_ids]
assert json.loads(after[new_records]) == records
assert after[new_ids] == before[legacy_ids]
print('SYNTHETIC_PASSPHRASE_METADATA_UPGRADE=PASS')
