import hashlib,json,os,plistlib,sys
from pathlib import Path
with open(sys.argv[1],'rb') as f: before=plistlib.load(f)
with open(sys.argv[2],'rb') as f: after=plistlib.load(f)
gkey='SelectiveRemote.native032.terminal.snippetGroups.v1';tkey='SelectiveRemote.native032.terminal.commandTemplates.v1'
bg=json.loads(before[gkey]);bt=json.loads(before[tkey]);ag=json.loads(after[gkey]);at=json.loads(after[tkey])
orig=[x for x in bg if x['name']=='TEST-ONLY-CODEX-SNIPPET-GROUP'];snips=[x for x in bt if x['title']=='TEST-ONLY-CODEX-SNIPPET'];added=[x for x in ag if x['name']=='TEST-ONLY-CODEX-CRASH-GROUP']
assert len(orig)==len(snips)==1 and snips[0]['groupID']==orig[0]['id'] and snips[0]['command']=='TEST-ONLY-CODEX-COMMAND'
assert bt==at, 'preexisting Snippet content changed'
assert len(added)==1 and [x for x in ag if x['name']!='TEST-ONLY-CODEX-CRASH-GROUP']==bg, 'group transaction incomplete'
assert after.get('SelectiveRemote.native032.snippets.pending.v1') is None, 'journal not cleared'
result={'phase':os.environ['SR_GUI_FAULT_PHASE'],'actualAppSIGKILL':True,'existingSnippetAndGroupPreserved':True,'newGroupCommitted':True,'journalCleared':True,'groupHashes':[hashlib.sha256(before[gkey]).hexdigest(),hashlib.sha256(after[gkey]).hexdigest()],'snippetHashes':[hashlib.sha256(before[tkey]).hexdigest(),hashlib.sha256(after[tkey]).hexdigest()]}
Path(sys.argv[3]).joinpath('real-snippet-crash.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
