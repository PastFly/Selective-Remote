import json
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

crud = SourceFileLoader('crud', str(Path(__file__).with_name('verify-host-crud.py'))).load_module()
if len(sys.argv) != 4 or sys.argv[1] not in ('on', 'off'):
    raise SystemExit('usage: on|off BEFORE AFTER')
before, after = crud.read(sys.argv[2]), crud.read(sys.argv[3])
if before[crud.OLD] != after[crud.OLD] or set(before[crud.NEW]) != set(after[crud.NEW]):
    raise SystemExit('profile identities or legacy collection changed')
ids = [k for k, p in before[crud.NEW].items() if p.get('friendlyName') == crud.HOST]
if len(ids) != 1:
    raise SystemExit('expected one synthetic Host')
identity = ids[0]
for key in before[crud.NEW]:
    a, b = before[crud.NEW][key].copy(), after[crud.NEW][key].copy()
    old, new = a.pop('isFavorite', False), b.pop('isFavorite', False)
    if a != b or (key != identity and old != new):
        raise SystemExit('unrelated profile changed')
    if key == identity and (old is not False or new is not (sys.argv[1] == 'on')):
        raise SystemExit('favorite state mismatch')
print(json.dumps({'syntheticHostFavorite': sys.argv[1], 'unrelatedProfilesPreserved': True}))
