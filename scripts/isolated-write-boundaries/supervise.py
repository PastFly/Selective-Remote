import json,os,signal,subprocess,sys,time
from pathlib import Path
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
root=Path(os.environ['SR_FAULT_ROOT']); root.mkdir(mode=0o700,exist_ok=False)
exe=Path(sys.argv[1]); out=Path(sys.argv[2]); out.mkdir(exist_ok=True)
points=['before_snapshot_set','after_snapshot_set','after_snapshot_sync','before_host_set','after_host_set','after_snippets_set','after_groups_set','before_marker_set','after_marker_set','after_marker_sync']
results=[]
def call(mode,point):
 p=subprocess.run([str(exe),mode,point,'synthetic'],capture_output=True,text=True,timeout=25)
 if p.returncode: raise RuntimeError(f'{mode}/{point}: {p.stderr} {p.stdout}')
 return p.stdout.strip()
for point in points:
 call('seed',point)
 marker=root/f'stopped-{point}'
 p=subprocess.Popen([str(exe),'fault',point,'synthetic'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  deadline=time.monotonic()+25
  while time.monotonic()<deadline and not marker.exists():
   if p.poll() is not None: raise RuntimeError(f'{point}: exited before boundary: {p.communicate()}')
   time.sleep(.05)
  if not marker.exists(): raise TimeoutError(f'{point}: no marker')
  stop_deadline=time.monotonic()+3
  while True:
   waited,status=os.waitpid(p.pid,os.WNOHANG|os.WUNTRACED)
   if waited==p.pid and os.WIFSTOPPED(status): break
   if waited==p.pid or time.monotonic()>=stop_deadline: raise RuntimeError(f'{point}: child not stopped at boundary')
   time.sleep(.01)
  busy=call('busy',point)
  os.kill(p.pid,signal.SIGKILL)
  _,err=p.communicate(timeout=10)
  if p.returncode!=-signal.SIGKILL: raise RuntimeError(f'{point}: unexpected exit {p.returncode}: {err}')
  recovered=call('recover',point)
  results.append({'boundary':point,'sigkill':True,'lease_busy_before_kill':True,'recovery':recovered})
  out.joinpath('migration-boundaries.json').write_text(json.dumps({'results':results,'scope':'exact migration source, instrumented UserDefaults adapter; boundaries bracket calls, not inside OS I/O'},indent=2)+'\n')
  print(f'{point}=PASS',flush=True)
 finally:
  if p.poll() is None: p.kill();p.wait(timeout=10)
out.joinpath('migration-boundaries.json').write_text(json.dumps({'results':results,'scope':'exact migration source, instrumented UserDefaults adapter; boundaries bracket calls, not inside OS I/O'},indent=2)+'\n')
