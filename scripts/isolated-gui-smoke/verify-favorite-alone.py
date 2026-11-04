import json
import plistlib
import sys
import uuid

OLD = 'SelectiveRemote.connectionProfiles.v2'
NEW = 'SelectiveRemote.native032.connectionProfiles.v2'
HOST = 'TEST-ONLY-CODEX-LIVE-NEW'


def read(path):
    with open(path, 'rb') as f:
        data = plistlib.load(f)
    old = data.get(OLD)
    entries = json.loads(data[NEW])
    if not isinstance(entries, list):
        raise ValueError('invalid profiles')
    profiles = {str(uuid.UUID(p['id'])).upper(): p for p in entries}
    if len(profiles) != len(entries):
        raise ValueError('duplicate profile IDs')
    return old, profiles


def check(mode, before, after):
    old_before, profiles_before = before
    old_after, profiles_after = after
    if old_before != old_after or set(profiles_before) != set(profiles_after):
        raise ValueError('legacy collection or profile identities changed')
    ids = [key for key, p in profiles_before.items() if p.get('friendlyName') == HOST]
    if len(ids) != 1:
        raise ValueError('expected one synthetic Host')
    selected = ids[0]
    for key in profiles_before:
        left, right = profiles_before[key].copy(), profiles_after[key].copy()
        previous, current = left.pop('isFavorite', False), right.pop('isFavorite', False)
        if left != right or (key != selected and previous != current):
            raise ValueError('unrelated Host data changed')
        if key == selected and (previous is not False or current is not (mode == 'on')):
            raise ValueError('unexpected favorite state')
    return {'test_id': 'HOST_FAVORITE_' + mode.upper(), 'status': 'PASS', 'unrelated_data_preserved': True}


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] not in ('on', 'off', 'restart'):
        raise SystemExit('usage: on|off|restart BEFORE AFTER')
    print(json.dumps(check(sys.argv[1], read(sys.argv[2]), read(sys.argv[3]))))
