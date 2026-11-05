import hashlib,json,os,plistlib,sys
from pathlib import Path
with open(sys.argv[1],'rb') as f: before=plistlib.load(f)
with open(sys.argv[2],'rb') as f: after=plistlib.load(f)
oldkey='SelectiveRemote.connectionProfiles.v2';newkey='SelectiveRemote.native032.connectionProfiles.v2';snapkey='SelectiveRemote.native032.migration.snapshot.v1';markerkey='SelectiveRemote.native032.migration.complete.v1'
assert after[oldkey]==before[oldkey], 'legacy Hosts changed'
old=json.loads(before[oldkey]);new=json.loads(after[newkey]);name='TEST-ONLY-CODEX-LIVE-OLD';a=[x for x in old if x.get('friendlyName')==name];b=[x for x in new if x.get('friendlyName')==name]
diagnostic={'oldCount':len(a),'newCount':len(b)}
if len(a)==len(b)==1:
 diagnostic['oldId']=a[0].get('id');diagnostic['newId']=b[0].get('id')
 diagnostic['missingKeys']=sorted(set(a[0])-set(b[0]));diagnostic['addedKeys']=sorted(set(b[0])-set(a[0]))
 diagnostic['changedKeys']=sorted(k for k in set(a[0]) & set(b[0]) if a[0][k]!=b[0][k])
 diagnostic['addedValues']={k:b[0][k] for k in diagnostic['addedKeys'] if not any(t in k.lower() for t in ('password','secret','token','passphrase'))}
 diagnostic['changedValues']={k:{'old':a[0][k],'new':b[0][k]} for k in diagnostic['changedKeys'] if not any(t in k.lower() for t in ('password','secret','token','passphrase'))}
Path(sys.argv[3]).joinpath('synthetic-host-schema-diff.json').write_text(json.dumps(diagnostic,indent=2)+'\n');print(json.dumps(diagnostic))
assert len(a)==len(b)==1 and diagnostic['oldId']==diagnostic['newId'] and not diagnostic['missingKeys'] and not diagnostic['changedKeys'] and diagnostic['addedValues']=={'folderOrderPath': [], 'sortIndex': 0} and set(diagnostic['addedKeys'])=={'folderOrderPath','sortIndex'}, 'migrated Host identity or contents changed unexpectedly'
snapshot=after[snapkey];digest=hashlib.sha256(snapshot).hexdigest();assert after[markerkey]=='complete:'+digest, 'inconsistent migration checkpoint'
result={'phase':os.environ['SR_GUI_FAULT_PHASE'],'actualAppSIGKILL':True,'legacyUnchanged':True,'migratedHostIDAndContentPreserved':True,'expectedNewSchemaDefaults':True,'checkpointHashValid':True,'legacyHostSHA256':hashlib.sha256(before[oldkey]).hexdigest(),'checkpointSHA256':digest}
Path(sys.argv[3]).joinpath('real-migration-crash.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
