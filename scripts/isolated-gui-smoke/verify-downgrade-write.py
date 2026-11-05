import hashlib,json,plistlib,sys,uuid
from pathlib import Path
keys=['SelectiveRemote.connectionProfiles.v2','SelectiveRemote.native032.connectionProfiles.v2']
states=[]
for filename in sys.argv[1:5]:
 d=plistlib.loads(Path(filename).read_bytes()); values=[]
 for key in keys:
  rows=json.loads(d[key]); values.append({str(uuid.UUID(x['id'])):x for x in rows})
 states.append(values)
before,current,down,restarted=states
assert before[0]==current[0], 'new write changed old collection'
assert current[1].keys() >= before[1].keys(), 'new write removed existing current IDs'
def unique(d,name,host):
 rows=[(k,v) for k,v in d.items() if v.get('friendlyName')==name and v.get('host')==host]
 assert len(rows)==1, f'{name} missing or duplicated'; return rows[0]
newid,new=unique(current[1],'TEST-ONLY-CODEX-CURRENT-HOST','192.0.2.12')
assert newid not in before[1]
assert current[1]==down[1], 'downgrade write changed current collection'
oldid,old=unique(down[0],'TEST-ONLY-CODEX-LATE-HOST','192.0.2.11')
assert oldid not in current[0] and {k:v for k,v in down[0].items() if k!=oldid}==current[0]
assert down==restarted, 'relaunch changed either profile collection'
out=Path(sys.argv[5]); (out/'late-persistence.json').write_text(json.dumps({'baselineHost':{'id':oldid,'friendlyName':old['friendlyName']}})); (out/'mixed-persistence.json').write_text(json.dumps({'baselineHost':{'id':newid,'friendlyName':new['friendlyName']}}))
summary={'downgradeHostID':oldid,'currentHostID':newid,'oldLateVisibleInCurrent':oldid in restarted[1], 'old_collection_sha256':hashlib.sha256(json.dumps(restarted[0],sort_keys=True).encode()).hexdigest(),'current_collection_sha256':hashlib.sha256(json.dumps(restarted[1],sort_keys=True).encode()).hexdigest(),'both_collections_preserved':True}
(out/'downgrade-result.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
