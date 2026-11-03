import hashlib
import json
import plistlib
import sys

KEY = 'SelectiveRemote.connectionProfiles.v2'


def read(path):
    with open(path, 'rb') as stream:
        data = plistlib.load(stream)[KEY]
    if not isinstance(data, bytes):
        raise ValueError('expected JSON data')
    value = json.loads(data)
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ValueError('expected profile array')
    return data, value


if len(sys.argv) != 3:
    raise SystemExit('two snapshots required')
first_bytes, first = read(sys.argv[1])
second_bytes, second = read(sys.argv[2])
print(json.dumps({'bytesEqual': first_bytes == second_bytes, 'semanticEqual': first == second,
                  'beforeSHA256': hashlib.sha256(first_bytes).hexdigest(),
                  'afterSHA256': hashlib.sha256(second_bytes).hexdigest(),
                  'beforeCount': len(first), 'afterCount': len(second)}, sort_keys=True))
