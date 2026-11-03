import json, plistlib, sys
key = 'SelectiveRemote.connectionProfiles.v2'
mode, path, output = sys.argv[1:]
with open(path, 'rb') as f:
    first = plistlib.load(f)[key]
if mode == 'prepare':
    encoded = json.dumps(json.loads(first), sort_keys=True, indent=2).encode()
    if encoded == first:
        raise SystemExit('re-encoding did not change bytes')
    with open(output, 'w') as f:
        f.write(encoded.hex())
elif mode == 'verify':
    with open(output, 'rb') as f:
        second = plistlib.load(f)[key]
    if first == second or json.loads(first) != json.loads(second):
        raise SystemExit('re-encoding was not semantically equivalent with different bytes')
    print('LEGACY_REENCODE=DIFFERENT_BYTES_EQUAL_JSON')
else:
    raise SystemExit('unknown mode')
