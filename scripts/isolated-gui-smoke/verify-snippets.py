import json
import plistlib
import sys

if len(sys.argv) != 3:
    raise SystemExit('baseline and upgraded snapshots required')
with open(sys.argv[1], 'rb') as source:
    before = plistlib.load(source)
with open(sys.argv[2], 'rb') as source:
    after = plistlib.load(source)
try:
    old_groups = json.loads(before['SelectiveRemote.terminal.snippetGroups.v1'])
    old_snippets = json.loads(before['SelectiveRemote.terminal.commandTemplates.v1'])
    legacy_groups = json.loads(after['SelectiveRemote.terminal.snippetGroups.v1'])
    legacy_snippets = json.loads(after['SelectiveRemote.terminal.commandTemplates.v1'])
    new_groups = json.loads(after['SelectiveRemote.native032.terminal.snippetGroups.v1'])
    new_snippets = json.loads(after['SelectiveRemote.native032.terminal.commandTemplates.v1'])
    groups = [g for g in old_groups if g['name'] == 'TEST-ONLY-CODEX-SNIPPET-GROUP']
    snippets = [s for s in old_snippets if s['title'] == 'TEST-ONLY-CODEX-SNIPPET']
    if len(groups) != 1 or len(snippets) != 1 or snippets[0]['command'] != 'TEST-ONLY-CODEX-COMMAND' or snippets[0]['groupID'] != groups[0]['id']:
        raise ValueError('synthetic group/snippet or relationship missing')
    for name, expected, actual in (
        ('legacy groups', old_groups, legacy_groups), ('legacy snippets', old_snippets, legacy_snippets),
        ('new groups', old_groups, new_groups), ('new snippets', old_snippets, new_snippets),
    ):
        if expected == actual:
            continue
        old_by_id = {entry['id']: entry for entry in expected}
        new_by_id = {entry['id']: entry for entry in actual}
        fields = sorted({key for item in old_by_id.keys() & new_by_id.keys()
                         for key in old_by_id[item].keys() | new_by_id[item].keys()
                         if old_by_id[item].get(key) != new_by_id[item].get(key)})
        print(json.dumps({'collection': name, 'beforeCount': len(expected), 'afterCount': len(actual),
                          'identitySetChanged': set(old_by_id) != set(new_by_id), 'changedFields': fields}))
        raise ValueError('snippet collections changed')
except (KeyError, TypeError, ValueError) as error:
    raise SystemExit(f'SNIPPET_UPGRADE_FAILED: {error}')
print(json.dumps({'syntheticSnippetUpgrade': 'PASS', 'groupRelationshipPreserved': True, 'concurrentWritesVerified': False}))
