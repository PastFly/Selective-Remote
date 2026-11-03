import json
import plistlib
import sys
import uuid

if len(sys.argv) not in (2, 3): raise SystemExit('baseline and optional upgraded snapshot required')
with open(sys.argv[1], 'rb') as source: before = plistlib.load(source)
old_key = 'SelectiveRemote.independentPortForwards.v1'
new_key = 'SelectiveRemote.native032.independentPortForwards.v1'
try:
    old = json.loads(before[old_key])
    if not isinstance(old, list): raise ValueError('tunnel collection invalid')
    matches = [item for item in old if item['rule']['name'] == 'TEST-ONLY-CODEX-FORWARD']
    if len(matches) != 1: raise ValueError('synthetic tunnel not unique')
    identity = str(uuid.UUID(matches[0]['id'])).upper()
    if str(uuid.UUID(matches[0]['rule']['id'])).upper() != identity: raise ValueError('tunnel identity mismatch')
    if len(sys.argv) == 2:
        print(json.dumps({'baselineHost': {'friendlyName': 'TEST-ONLY-CODEX-FORWARD', 'id': identity}, 'keychainVerified': False}))
    else:
        with open(sys.argv[2], 'rb') as source: after = plistlib.load(source)
        if after[old_key] != before[old_key] or json.loads(after[new_key]) != old: raise ValueError('tunnel collection changed')
        print(json.dumps({'syntheticForwardingUpgrade': 'PASS', 'allTunnelFieldsPreserved': True}))
except (KeyError, TypeError, ValueError) as error:
    raise SystemExit(f'FORWARDING_UPGRADE_FAILED: {error}')
