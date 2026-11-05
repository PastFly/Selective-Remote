import json,plistlib,sys
from pathlib import Path
d=plistlib.loads(Path(sys.argv[1]).read_bytes()); p=json.loads(d['SelectiveRemote.native032.connectionProfiles.v2']);m=[x for x in p if x.get('friendlyName')=='TEST-ONLY-CODEX-LIVE-NEW'];assert len(m)==1
Path(sys.argv[2]).write_text(json.dumps({'baselineHost':{'id':m[0]['id'],'friendlyName':m[0]['friendlyName']}}))
