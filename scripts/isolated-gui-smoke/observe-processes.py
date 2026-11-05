import json,subprocess,sys,time
from pathlib import Path
root=int(sys.argv[1]); seen=set(); end=time.monotonic()+100
with open(sys.argv[2],'w') as out:
 while time.monotonic()<end:
  rows=subprocess.run(['ps','-axo','pid=,ppid=,comm='],capture_output=True,text=True).stdout.splitlines()
  entries={}
  for row in rows:
   parts=row.strip().split(None,2)
   if len(parts)==3 and parts[0].isdigit() and parts[1].isdigit(): entries[int(parts[0])]=(int(parts[1]),Path(parts[2]).name)
  descendants={root}; changed=True
  while changed:
   old=len(descendants); descendants.update(pid for pid,(ppid,_) in entries.items() if ppid in descendants); changed=len(descendants)>old
  for pid in sorted(descendants):
   if pid in entries and (pid,entries[pid]) not in seen:
    seen.add((pid,entries[pid])); out.write(json.dumps({'pid':pid,'ppid':entries[pid][0],'comm':entries[pid][1]})+'\n'); out.flush()
  time.sleep(.2)
