import json
import plistlib
import sys
import uuid

LEGACY = 'SelectiveRemote.connectionProfiles.v2'
CURRENT = 'SelectiveRemote.native032.connectionProfiles.v2'
LATE = {'friendlyName': 'TEST-ONLY-CODEX-LATE-HOST', 'group': 'TEST-ONLY-CODEX-MIXED-FOLDER',
        'host': '192.0.2.11', 'username': 'test'}
NEW = {'friendlyName': 'TEST-ONLY-CODEX-CURRENT-HOST', 'group': 'TEST-ONLY-CODEX-MIXED-FOLDER',
       'host': '192.0.2.12', 'username': 'test'}


def profiles(domain, key):
    value = json.loads(domain[key])
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ValueError('invalid profiles')
    result = {}
    for item in value:
        identity = str(uuid.UUID(item['id'])).upper()
        if identity in result:
            raise ValueError('duplicate profile id')
        result[identity] = item
    return result


def find(values, expected):
    found = [(identity, item) for identity, item in values.items()
             if item.get('friendlyName') == expected['friendlyName']]
    if len(found) != 1 or any(found[0][1].get(k) != v for k, v in expected.items()):
        raise ValueError('synthetic profile absent, duplicated or mismatched')
    return found[0][0]


if len(sys.argv) != 4 or sys.argv[1] not in ('late', 'current'):
    raise SystemExit('usage: verify-mixed-writes.py late|current BEFORE AFTER')
with open(sys.argv[2], 'rb') as stream:
    before = plistlib.load(stream)
with open(sys.argv[3], 'rb') as stream:
    after = plistlib.load(stream)
old_before, old_after = profiles(before, LEGACY), profiles(after, LEGACY)
new_before, new_after = profiles(before, CURRENT), profiles(after, CURRENT)
if sys.argv[1] == 'late':
    late_id = find(old_after, LATE)
    if late_id in old_before or {k: v for k, v in old_after.items() if k != late_id} != old_before:
        raise SystemExit('legacy mutation was not one synthetic addition')
    if new_after != new_before:
        raise SystemExit('new-version profiles changed during downgrade write')
    print(json.dumps({'baselineHost': {'id': late_id, **LATE}, 'lateLegacyWritePersisted': True,
                      'currentCollectionUnchanged': True}))
else:
    late_id = find(old_after, LATE)
    current_id = find(new_after, NEW)
    if old_after != old_before:
        raise SystemExit('current write modified the legacy collection')
    if current_id in new_before or {k: v for k, v in new_after.items() if k != current_id} != new_before:
        raise SystemExit('current mutation was not one synthetic addition')
    print(json.dumps({'baselineHost': {'id': current_id, **NEW}, 'lateLegacyProfileStillRetained': True, 'currentWritePersisted': True,
                      'lateLegacyProfilePresentInCurrent': late_id in new_after,
                      'legacyCollectionUnchangedByCurrent': True, 'mixedVersionSafetyVerified': False}))
