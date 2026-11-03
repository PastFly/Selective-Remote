import collections, json, plistlib, sys
key = 'SelectiveRemote.native032.connectionProfiles.v2'
def read(path):
    with open(path, 'rb') as f:
        data = json.loads(plistlib.load(f)[key])
    return {item['id']: item for item in data}
a, b = map(read, sys.argv[1:])
changed = collections.Counter()
for identity in a.keys() & b.keys():
    for field in a[identity].keys() | b[identity].keys():
        if a[identity].get(field) != b[identity].get(field) or (field in a[identity]) != (field in b[identity]):
            changed[field] += 1
print(json.dumps({'before_count': len(a), 'after_count': len(b), 'added_count': len(b.keys()-a.keys()), 'removed_count': len(a.keys()-b.keys()), 'changed_field_names_and_counts': dict(changed)}, sort_keys=True))
