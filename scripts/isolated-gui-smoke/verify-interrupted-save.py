import hashlib,json,os,plistlib,sys
from pathlib import Path
key='SelectiveRemote.native032.connectionProfiles.v2';values=[];hashes=[]
for filename in sys.argv[1:3]:
 d=plistlib.loads(Path(filename).read_bytes());raw=d[key];rows=json.loads(raw);values.append({x['id']:x for x in rows});hashes.append(hashlib.sha256(raw).hexdigest())
a,b=values;assert a.keys()==b.keys(), 'host IDs changed';ids=[k for k,v in a.items() if v.get('friendlyName')=='TEST-ONLY-CODEX-LIVE-NEW'];assert len(ids)==1
old=a[ids[0]].copy();new=b[ids[0]].copy();oldname=old.pop('friendlyName');newname=new.pop('friendlyName');assert old==new and newname in (oldname,'TEST-ONLY-CODEX-CRASH-REPLACEMENT'), 'unexpected partial edit or other field mutation'
assert all(a[k]==b[k] for k in a if k!=ids[0]), 'unrelated hosts changed'
phase=os.environ['SR_GUI_FAULT_PHASE'];assert phase in ('before','after');assert phase != 'before' or newname==oldname, 'before-set crash changed committed host'
out=Path(sys.argv[3]);out.joinpath('both-collections.json').write_text(json.dumps({'baselineHost':{'id':ids[0],'friendlyName':'TEST-ONLY-CODEX-LIVE-NEW'}}))
result={'host_id':ids[0],'name_outcome':'old' if newname==oldname else 'new','other_fields_preserved':True,'encoded_sha256':hashes,'actual_write_phase_observed':True,'phase':phase}
out.joinpath('interrupted-save.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
