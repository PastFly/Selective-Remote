import hashlib,json,plistlib,re,sys,uuid
from pathlib import Path
key='SelectiveRemote.native032.connectionProfiles.v2'
reports=[]
for path in sys.argv[1:5]:
 data=plistlib.loads(Path(path).read_bytes()); raw=data[key]; hosts=json.loads(raw)
 items=[x for x in hosts if x.get('hostname') == '192.0.2.14']
 if len(items)!=1:
  items=[x for x in hosts if str(x.get('friendlyName','')).startswith('TEST-ONLY-CODEX-')]
 assert len(items)==1, f'synthetic host count {len(items)}'
 host=items[0]
 reports.append({'id':str(uuid.UUID(host['id'])),'name':host.get('friendlyName'),'folder':host.get('group'),'favorite':host.get('isFavorite'),'collection_sha256':hashlib.sha256(raw).hexdigest(),'count':len(hosts)})
logs=[Path(sys.argv[5],f'race{i}.log').read_text() for i in (1,2)]
times=[float(re.search(r'SYNTHETIC_RACE_ACTION_UPTIME=([0-9.]+)',x).group(1)) for x in logs]
result={'snapshots':reports,'action_delta_seconds':abs(times[0]-times[1]),'same_id':len({x['id'] for x in reports})==1,'both_edits_preserved':reports[2]['name']=='TEST-ONLY-CODEX-RACE-NAME' and reports[2]['folder']=='TEST-ONLY-CODEX-RACE-FOLDER'}
Path(sys.argv[5],'concurrent-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
assert result['same_id'] and result['action_delta_seconds']<0.3, 'race or ID validation failed'
assert result['both_edits_preserved'], 'DATA_LOSS: stale writer did not preserve other process edit'
