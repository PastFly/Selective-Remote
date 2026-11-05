import json,os,secrets,shlex,signal,subprocess,sys,time
from pathlib import Path
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
root=Path(os.environ['SR_KEYCHAIN_FAULT_ROOT']); root.mkdir(mode=0o700,exist_ok=False)
exe=Path(sys.argv[1]); out=Path(sys.argv[2]);out.mkdir(exist_ok=True)
points=['before_pending_marker','after_pending_marker','before_current_add','after_current_add','before_marker_commit','after_marker_commit','before_current_update','after_current_update']
def security(*args):
 p=subprocess.run(['security',*args],capture_output=True,text=True,timeout=20)
 if p.returncode: raise RuntimeError(f'synthetic keychain setup failed: {args[0]} exit={p.returncode}')
 return p.stdout
def run(mode,point):
 try: p=subprocess.run([str(exe),mode,point],capture_output=True,text=True,timeout=40)
 except subprocess.TimeoutExpired: raise RuntimeError(f'{mode}/{point}: synthetic Keychain request timed out')
 if p.returncode: raise RuntimeError(f'{mode}/{point}: {p.stderr} {p.stdout}')
 return p.stdout.strip()
original_default=shlex.split(security('default-keychain','-d','user'))
original_keychains=shlex.split(security('list-keychains','-d','user'))
results=[]
try:
 for point in points:
  path=root/f'selective-remote-synthetic-{point}.keychain-db'; password=secrets.token_hex(24)
  try:
   security('create-keychain','-p',password,str(path));security('set-keychain-settings','-lut','1800',str(path));security('unlock-keychain','-p',password,str(path))
   security('list-keychains','-d','user','-s',str(path));security('default-keychain','-d','user','-s',str(path))
   run('seed',point)
   marker=root/f'stopped-{point}'
   p=subprocess.Popen([str(exe),'fault',point],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   try:
    deadline=time.monotonic()+30
    while time.monotonic()<deadline and not marker.exists():
     if p.poll() is not None: raise RuntimeError(f'{point}: exited before boundary: {p.communicate()}')
     time.sleep(.05)
    if not marker.exists(): raise TimeoutError(f'{point}: no boundary marker')
    deadline=time.monotonic()+3
    while True:
     waited,status=os.waitpid(p.pid,os.WNOHANG|os.WUNTRACED)
     if waited==p.pid and os.WIFSTOPPED(status):break
     if waited==p.pid or time.monotonic()>=deadline: raise RuntimeError(f'{point}: process not stopped')
     time.sleep(.01)
    run('busy',point)
    os.kill(p.pid,signal.SIGKILL); _,err=p.communicate(timeout=10)
    if p.returncode!=-signal.SIGKILL: raise RuntimeError(f'{point}: wrong exit {p.returncode}: {err}')
    recovery=run('recover',point)
    results.append({'boundary':point,'sigkill':True,'lease_busy_before_kill':True,'recovery':recovery})
    out.joinpath('keychain-boundaries.json').write_text(json.dumps({'results':results,'scope':'exact vault source, hooks bracket real Security API calls; not inside securityd I/O'},indent=2)+'\n')
    print(f'{point}=PASS',flush=True)
   finally:
    if p.poll() is None:p.kill();p.wait(timeout=10)
  finally:
   if original_default: security('default-keychain','-d','user','-s',original_default[0])
   if original_keychains: security('list-keychains','-d','user','-s',*original_keychains)
   if path.exists(): security('delete-keychain',str(path))
finally:
 if original_default: security('default-keychain','-d','user','-s',original_default[0])
 if original_keychains: security('list-keychains','-d','user','-s',*original_keychains)
