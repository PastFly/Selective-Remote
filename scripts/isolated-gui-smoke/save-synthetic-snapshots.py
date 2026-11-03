import json, pathlib, plistlib, sys
root, out = map(pathlib.Path, sys.argv[1:])
keys = ('SelectiveRemote.connectionProfiles.v2', 'SelectiveRemote.native032.connectionProfiles.v2')
for stage in ('before-migration', 'migrated', 'reencoded', 'after-new-termination', 'before-late', 'after'):
    path = root / (stage + '.plist')
    if not path.exists():
        continue
    with path.open('rb') as stream:
        data = plistlib.load(stream)
    result = {key: json.loads(data[key]) for key in keys if key in data}
    with (out / ('snapshot-' + stage + '.json')).open('w') as stream:
        json.dump(result, stream, sort_keys=True, indent=2)
