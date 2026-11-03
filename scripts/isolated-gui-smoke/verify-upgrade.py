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


def profiles_by_id(raw):
    profiles = json.loads(raw)
    if not isinstance(profiles, list):
        raise ValueError('expected profile array')
    result = {}
    for profile in profiles:
        if not isinstance(profile, dict):
            raise ValueError('invalid profile')
        identifier = str(uuid.UUID(profile['id'])).upper()
        if identifier in result:
            raise ValueError('duplicate profile ID')
        result[identifier] = profile
    return result


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
baseline_profiles, current_profiles = profiles_by_id(before[legacy]), profiles_by_id(after[current])
if set(baseline_profiles) != set(current_profiles):
    raise SystemExit('profile identities changed during upgrade')
for identifier, profile in baseline_profiles.items():
    current_profile = current_profiles[identifier]
    changed = [key for key, value in profile.items() if key != 'id' and
               (key not in current_profile or current_profile[key] != value)]
    if changed:
        raise SystemExit('profile fields changed during upgrade: ' + ','.join(sorted(changed)))
print(json.dumps({'hostID': baseline['id'], 'hostFieldsPreserved': True,
                  'allBaselineProfileFieldsPreserved': True, 'legacyBytesPreserved': True, 'keychainVerified': False,
                  'snippetVerified': False, 'mixedVersionVerified': False}, sort_keys=True))
