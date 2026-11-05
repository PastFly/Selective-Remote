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
  ssh_pids=[str(pid) for pid in descendants if pid in entries and entries[pid][1]=='ssh']
  if ssh_pids:
   raw=subprocess.run(['lsof','-a','-p',','.join(ssh_pids),'-iTCP:52222','-nP','-Fpn'],capture_output=True,text=True).stdout.splitlines()
   current=None
   for line in raw:
    if line.startswith('p') and line[1:].isdigit(): current=int(line[1:])
    elif current and line.startswith('n') and '->127.0.0.1:52222' in line:
     import re
     match=re.search(r':(\d+)->127\.0\.0\.1:52222',line)
     if match:
      record=('socket',current,int(match.group(1)))
      if record not in seen: seen.add(record); out.write(json.dumps({'ssh_pid':current,'client_port':record[2]})+'\n'); out.flush()
  time.sleep(.2)
