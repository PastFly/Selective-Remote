import json
import os
import plistlib
import re
import stat
import sys
import uuid
from pathlib import Path

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('USER') != 'runner':
    raise SystemExit('synthetic runner identity required')
temp = os.environ.get('RUNNER_TEMP', '')
fixture = Path(temp) / 'ssh-key-fixture'
if not temp or len(sys.argv) != 3 or sys.argv[2] != str(fixture / 'seed.plist') or not re.fullmatch(r'SHA256:[A-Za-z0-9+/]{40,48}', sys.argv[1]):
    raise SystemExit('synthetic key fixture required')
for item in (fixture / 'key', fixture / 'key.pub'):
    info = item.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise SystemExit('synthetic key file identity')
record = {'id': str(uuid.uuid4()).upper(), 'name': 'TEST-ONLY-CODEX-SSH-KEY',
          'privateKeyPath': str(fixture / 'key'), 'publicKeyPath': str(fixture / 'key.pub'),
          'fingerprint': sys.argv[1], 'algorithm': 'ED25519', 'createdAt': 0}
with open(sys.argv[2], 'xb') as output:
    plistlib.dump({'SelectiveRemote.sshKeys.v1': json.dumps([record]).encode()}, output)
print('SYNTHETIC_SSH_KEY_METADATA_SEEDED=YES')
