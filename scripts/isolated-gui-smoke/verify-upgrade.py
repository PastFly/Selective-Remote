import json
import plistlib
import sys
import uuid

EXPECTED = {'friendlyName': 'TEST-ONLY-CODEX-UPGRADE-HOST',
            'group': 'TEST-ONLY-CODEX-UPGRADE-FOLDER', 'host': '192.0.2.10', 'username': 'test'}


def read_domain(path):
    with open(path, 'rb') as stream:
        return plistlib.load(stream)


def synthetic_host(raw):
    profiles = json.loads(raw)
    if not isinstance(profiles, list) or len(profiles) < 2:
        raise ValueError('expected initial and newly created profiles')
    found = [p for p in profiles if p.get('friendlyName') == EXPECTED['friendlyName']]
    if len(found) != 1 or any(found[0].get(k) != v for k, v in EXPECTED.items()):
        raise ValueError('synthetic host missing, duplicated or changed')
    return {'id': str(uuid.UUID(found[0]['id'])).upper(), **EXPECTED}


if len(sys.argv) != 3:
    raise SystemExit('baseline and upgraded preference snapshots required')
before, after = map(read_domain, sys.argv[1:])
legacy = 'SelectiveRemote.connectionProfiles.v2'
current = 'SelectiveRemote.native032.connectionProfiles.v2'
if before[legacy] != after[legacy]:
    raise SystemExit('legacy host storage changed')
baseline, migrated = synthetic_host(before[legacy]), synthetic_host(after[current])
if baseline != migrated:
    raise SystemExit('synthetic host changed during upgrade')
print(json.dumps({'hostID': baseline['id'], 'hostFieldsPreserved': True,
                  'legacyBytesPreserved': True, 'keychainVerified': False,
                  'snippetVerified': False, 'mixedVersionVerified': False}, sort_keys=True))
