import json
import plistlib
import sys
import uuid

if len(sys.argv) != 2:
    raise SystemExit('one baseline snapshot required')
with open(sys.argv[1], 'rb') as source:
    values = plistlib.load(source)
try:
    profiles = json.loads(values['SelectiveRemote.connectionProfiles.v2'])
    found = [p for p in profiles if p['friendlyName'] == 'TEST-ONLY-CODEX-RDP']
    if len(found) != 1 or found[0]['host'] != '192.0.2.11' or found[0]['connectionType'] != 'rdp':
        raise ValueError('synthetic RDP profile not unique or fields changed')
    host_id = str(uuid.UUID(found[0]['id'])).upper()
except (KeyError, TypeError, ValueError) as error:
    raise SystemExit(f'RDP_BASELINE_FAILED: {error}')
print(json.dumps({'baselineHost': {'friendlyName': 'TEST-ONLY-CODEX-RDP', 'id': host_id}, 'keychainVerified': False}))
