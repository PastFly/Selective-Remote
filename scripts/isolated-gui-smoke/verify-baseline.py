import json
import plistlib
import sys
import uuid


def read(path):
    with open(path, 'rb') as stream:
        domain = plistlib.load(stream)
    raw = domain['SelectiveRemote.connectionProfiles.v2']
    profiles = json.loads(raw)
    if not isinstance(profiles, list) or len(profiles) < 2:
        raise ValueError('expected initial and newly created profiles')
    matches = [profile for profile in profiles if profile.get('friendlyName') == 'TEST-ONLY-CODEX-UPGRADE-HOST']
    if len(matches) != 1:
        raise ValueError('synthetic host missing or duplicated')
    host = matches[0]
    expected = {'friendlyName': 'TEST-ONLY-CODEX-UPGRADE-HOST',
                'group': 'TEST-ONLY-CODEX-UPGRADE-FOLDER',
                'host': '192.0.2.10', 'username': 'test'}
    if any(host.get(key) != value for key, value in expected.items()):
        raise ValueError('synthetic host field mismatch')
    return {'id': str(uuid.UUID(host['id'])).upper(), 'profileCount': len(profiles), **expected}


if len(sys.argv) != 3:
    raise SystemExit('two preference snapshots required')
first, second = read(sys.argv[1]), read(sys.argv[2])
if first != second:
    raise SystemExit('synthetic host changed between snapshots')
print(json.dumps({'baselineHost': first, 'stableReadback': True,
                  'keychainVerified': False, 'upgradeVerified': False}, sort_keys=True))
