import json
import plistlib
import sys
import uuid

if len(sys.argv) != 3:
    raise SystemExit('before and after snapshots required')
with open(sys.argv[1], 'rb') as source: before = plistlib.load(source)
with open(sys.argv[2], 'rb') as source: after = plistlib.load(source)
try:
    old_key = 'SelectiveRemote.connectionProfiles.v2'
    new_key = 'SelectiveRemote.native032.connectionProfiles.v2'
    if before[old_key] != after[old_key]: raise ValueError('legacy profile bytes changed')
    old = json.loads(before[old_key]); new = json.loads(after[new_key])
    if not isinstance(old, list) or not isinstance(new, list): raise ValueError('profile collection invalid')
    def index(profiles):
        result = {}
        for profile in profiles:
            identity = str(uuid.UUID(profile['id'])).upper()
            if identity in result: raise ValueError('duplicate profile')
            result[identity] = profile
        return result
    previous, current = index(old), index(new)
    if previous.keys() != current.keys(): raise ValueError('profile IDs changed')
    for identity, value in previous.items():
        for field, old_value in value.items():
            if field != 'id' and current[identity].get(field) != old_value: raise ValueError('profile field changed: ' + field)
    if len([p for p in old if p.get('friendlyName') == 'TEST-ONLY-CODEX-RDP' and p.get('host') == '192.0.2.11']) != 1:
        raise ValueError('synthetic RDP profile missing')
except (KeyError, TypeError, ValueError) as error:
    raise SystemExit(f'RDP_UPGRADE_FAILED: {error}')
print(json.dumps({'syntheticRDPProfileUpgrade': 'PASS', 'legacyBytesPreserved': True, 'allProfileFieldsPreserved': True}))
