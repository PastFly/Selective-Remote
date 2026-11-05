import hashlib,json,os,plistlib,sys
from pathlib import Path
with open(sys.argv[1],'rb') as f: before=plistlib.load(f)
with open(sys.argv[2],'rb') as f: after=plistlib.load(f)
oldkey='SelectiveRemote.connectionProfiles.v2';newkey='SelectiveRemote.native032.connectionProfiles.v2';snapkey='SelectiveRemote.native032.migration.snapshot.v1';markerkey='SelectiveRemote.native032.migration.complete.v1'
assert after[oldkey]==before[oldkey], 'legacy Hosts changed'
old=json.loads(before[oldkey]);new=json.loads(after[newkey]);name='TEST-ONLY-CODEX-LIVE-OLD';a=[x for x in old if x.get('friendlyName')==name];b=[x for x in new if x.get('friendlyName')==name]
assert len(a)==len(b)==1 and a[0]==b[0], 'migrated Host identity or contents changed'
snapshot=after[snapkey];digest=hashlib.sha256(snapshot).hexdigest();assert after[markerkey]=='complete:'+digest, 'inconsistent migration checkpoint'
result={'phase':os.environ['SR_GUI_FAULT_PHASE'],'actualAppSIGKILL':True,'legacyUnchanged':True,'migratedHostIDAndContentPreserved':True,'checkpointHashValid':True,'legacyHostSHA256':hashlib.sha256(before[oldkey]).hexdigest(),'checkpointSHA256':digest}
Path(sys.argv[3]).joinpath('real-migration-crash.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
