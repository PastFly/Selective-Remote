import json
import plistlib
import sys

if len(sys.argv) != 3:
    raise SystemExit('before and after downgrade snapshots required')
with open(sys.argv[1], 'rb') as source:
    before = plistlib.load(source)
with open(sys.argv[2], 'rb') as source:
    after = plistlib.load(source)
for name in ('SelectiveRemote.connectionProfiles.v2', 'SelectiveRemote.native032.connectionProfiles.v2'):
    try:
        old, new = json.loads(before[name]), json.loads(after[name])
    except (KeyError, TypeError, ValueError):
        raise SystemExit('missing or invalid profile collection')
    if old != new:
        raise SystemExit('profile collection changed after older app reopened: ' + name)
print(json.dumps({'downgradeReadOnlyCollectionsPreserved': True, 'downgradeWritesVerified': False, 'mixedVersionVerified': False}))
