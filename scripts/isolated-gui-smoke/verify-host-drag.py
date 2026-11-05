import json,plistlib,sys
key='SelectiveRemote.native032.connectionProfiles.v2'
def load(p):
 d=plistlib.loads(open(p,'rb').read()); return {x['id']:x for x in json.loads(d[key])}
a,b=map(load,sys.argv[1:]); assert a.keys()==b.keys()
ids=[k for k,v in a.items() if v.get('friendlyName')=='TEST-ONLY-CODEX-LIVE-NEW'];assert len(ids)==1
x,y=a[ids[0]].copy(),b[ids[0]].copy();assert x.pop('group')=='TEST-ONLY-CODEX-MIXED-FOLDER'; assert y.pop('group') in ('',None);assert x==y
assert all(a[k]==b[k] for k in a if k!=ids[0]); print(json.dumps({'host_id':ids[0],'group_move':'PASS','other_fields_preserved':True}))
