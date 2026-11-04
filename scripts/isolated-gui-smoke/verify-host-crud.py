import json
import plistlib
import sys
import uuid

OLD = 'SelectiveRemote.connectionProfiles.v2'
NEW = 'SelectiveRemote.native032.connectionProfiles.v2'
HOST = 'TEST-ONLY-CODEX-LIVE-NEW'


def read(path):
    with open(path, 'rb') as stream:
        data = plistlib.load(stream)
    result = {}
    for key in (OLD, NEW):
        entries = json.loads(data[key])
        result[key] = {str(uuid.UUID(p['id'])).upper(): p for p in entries}
        if len(result[key]) != len(entries):
            raise ValueError('duplicate IDs')
    return result


def check(before, duplicated, after=None):
    if before[OLD] != duplicated[OLD]:
        raise ValueError('legacy collection changed')
    added = set(duplicated[NEW]) - set(before[NEW])
    if len(added) != 1 or {k: v for k, v in duplicated[NEW].items() if k not in added} != before[NEW]:
        raise ValueError('duplicate changed preexisting data or did not add exactly one Host')
    originals = [v for v in before[NEW].values() if v.get('friendlyName') == HOST]
    if len(originals) != 1:
        raise ValueError('expected one synthetic original')
    copy = duplicated[NEW][next(iter(added))]
    if copy.get('friendlyName') != HOST + ' — копия' or any(copy.get(k) != originals[0].get(k) for k in ('host', 'username', 'group')):
        raise ValueError('copy fields mismatch')
    if after is not None and after != before:
        raise ValueError('delete did not return both collections to their original state')
    return {'syntheticHostDuplicate': True, 'deleteRestoredCollections': after is not None}


if __name__ == '__main__':
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in ('duplicate', 'delete') or (sys.argv[1] == 'delete') != (len(sys.argv) == 5):
        raise SystemExit('usage: duplicate BEFORE DUPLICATED | delete BEFORE DUPLICATED AFTER')
    print(json.dumps(check(read(sys.argv[2]), read(sys.argv[3]), read(sys.argv[4]) if len(sys.argv) == 5 else None)))
