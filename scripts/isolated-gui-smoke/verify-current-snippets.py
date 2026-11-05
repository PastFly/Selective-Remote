import json,plistlib,sys
with open(sys.argv[1],'rb') as f: before=plistlib.load(f)
with open(sys.argv[2],'rb') as f: after=plistlib.load(f)
groupkey='SelectiveRemote.native032.terminal.snippetGroups.v1';templatekey='SelectiveRemote.native032.terminal.commandTemplates.v1'
bg=json.loads(before[groupkey]);bt=json.loads(before[templatekey]);ag=json.loads(after[groupkey]);at=json.loads(after[templatekey])
groups=[x for x in bg if x['name']=='TEST-ONLY-CODEX-SNIPPET-GROUP'];templates=[x for x in bt if x['title']=='TEST-ONLY-CODEX-SNIPPET']
if len(groups)!=1 or len(templates)!=1 or templates[0]['command']!='TEST-ONLY-CODEX-COMMAND' or templates[0]['groupID']!=groups[0]['id']:raise SystemExit('synthetic current snippet missing')
if bg!=ag or bt!=at:raise SystemExit('current Snippet or folder changed after restart')
if after.get('SelectiveRemote.native032.snippets.pending.v1') is not None:raise SystemExit('journal not cleared')
print(json.dumps({'currentSnippetRestart':'PASS','sameIdsAndContent':True,'journalCleared':True}))
