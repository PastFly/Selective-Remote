import json,plistlib,sys
with open(sys.argv[1],'rb') as f: values=plistlib.load(f)
groups=json.loads(values['SelectiveRemote.native032.terminal.snippetGroups.v1'])
assert len([x for x in groups if x['name']=='TEST-ONLY-CODEX-WARNING'])==1
assert values.get('SelectiveRemote.native032.snippets.pending.v1') is None
print('WARNING_FAILURE_RECOVERY=PASS')
