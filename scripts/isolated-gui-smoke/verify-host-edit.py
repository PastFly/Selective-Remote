import json
import plistlib
import sys
import uuid

OLD = 'SelectiveRemote.connectionProfiles.v2'
NEW = 'SelectiveRemote.native032.connectionProfiles.v2'


def read(path):
    with open(path, 'rb') as f:
        data = plistlib.load(f)
    entries = json.loads(data[NEW])
    if not isinstance(entries, list):
        raise ValueError('invalid profile list')
    profiles = {str(uuid.UUID(p['id'])).upper(): p for p in entries}
    if len(profiles) != len(entries):
        raise ValueError('duplicate profile ID')
    return data.get(OLD), profiles


def check(before, after):
    old_before, before_profiles = before
    old_after, after_profiles = after
    if old_before != old_after or set(before_profiles) != set(after_profiles):
        raise ValueError('legacy collection or identities changed')
    ids = [key for key, profile in before_profiles.items() if profile.get('friendlyName') == 'TEST-ONLY-CODEX-LIVE-NEW']
    if len(ids) != 1:
        raise ValueError('synthetic Host not unique')
    target = ids[0]
    for key in before_profiles:
        left, right = before_profiles[key].copy(), after_profiles[key].copy()
        if key == target:
            if left.pop('group', None) != 'TEST-ONLY-CODEX-MIXED-FOLDER' or right.pop('group', None) != 'TEST-ONLY-CODEX-NEW-FOLDER':
                raise ValueError('folder move not saved')
            if left.pop('friendlyName', None) != 'TEST-ONLY-CODEX-LIVE-NEW' or right.pop('friendlyName', None) != 'TEST-ONLY-CODEX-EDITED':
                raise ValueError('name edit not saved')
        if left != right:
            raise ValueError('unrelated Host field changed')
    return {'test_id': 'HOST_EDIT_AND_MOVE', 'status': 'PASS', 'unrelated_data_preserved': True}


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: BEFORE AFTER')
    print(json.dumps(check(read(sys.argv[1]), read(sys.argv[2]))))
