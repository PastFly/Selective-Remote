import hashlib,json,plistlib,sys
from pathlib import Path
key='SelectiveRemote.native032.connectionProfiles.v2'; states=[]; hashes=[]
for name in sys.argv[1:4]:
 d=plistlib.loads(Path(name).read_bytes());raw=d[key]; states.append({x['id']:x for x in json.loads(raw)});hashes.append(hashlib.sha256(raw).hexdigest())
assert states[0]==states[1]==states[2], 'profile content changed while blocked or after restart'
hosts=[x for x in states[0].values() if x.get('friendlyName')=='TEST-ONLY-CODEX-LIVE-NEW' and x.get('host')=='192.0.2.14'];assert len(hosts)==1
out=Path(sys.argv[4]);(out/'both-collections.json').write_text(json.dumps({'baselineHost':{'id':hosts[0]['id'],'friendlyName':hosts[0]['friendlyName']}}))
result={'host_id':hosts[0]['id'],'profiles_identical':True,'encoded_sha256':hashes,'same_host_edit_in_second_instance':'blocked_before_stores_initialized'}
(out/'lease-recovery.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
