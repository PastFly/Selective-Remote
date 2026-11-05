import fcntl,json,os,signal,subprocess,sys,time
from pathlib import Path
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
root=Path(os.environ['SR_HOST_FAULT_ROOT']);root.mkdir(mode=0o700,exist_ok=False);exe=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(exist_ok=True);results=[]
for point in ('before_set','after_set','after_flush'):
 seed=subprocess.run([str(exe),'seed',point],capture_output=True,text=True,timeout=20)
 if seed.returncode:raise RuntimeError(f'{point} seed: {seed.stderr}')
 p=subprocess.Popen([str(exe),'fault',point],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  marker=root/f'stop-{point}';deadline=time.monotonic()+25
  while not marker.exists() and time.monotonic()<deadline:
   if p.poll() is not None:raise RuntimeError(f'{point} early: {p.communicate()}')
   time.sleep(.05)
  if not marker.exists():raise TimeoutError(point)
  deadline=time.monotonic()+3
  while True:
   waited,status=os.waitpid(p.pid,os.WNOHANG|os.WUNTRACED)
   if waited==p.pid and os.WIFSTOPPED(status):break
   if waited==p.pid or time.monotonic()>=deadline:raise RuntimeError('process not stopped')
   time.sleep(.01)
  fd=os.open(root/f'lock-{point}'/'native-app.lock',os.O_RDONLY|os.O_NOFOLLOW)
  try:
   try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);raise RuntimeError('lease not held')
   except BlockingIOError:pass
  finally:os.close(fd)
  os.kill(p.pid,signal.SIGKILL);p.communicate(timeout=10)
  if p.returncode!=-signal.SIGKILL:raise RuntimeError('not killed')
  recovery=subprocess.run([str(exe),'recover',point],capture_output=True,text=True,timeout=20)
  results.append({'boundary':point,'sigkill':True,'returncode':recovery.returncode,'stdout':recovery.stdout,'stderr':recovery.stderr})
  out.joinpath('host-crash.json').write_text(json.dumps({'scope':'exact AppModel.saveProfiles method body with isolated real UserDefaults adapter and synthetic Codable records, not full app and not inside preferences daemon I/O','results':results},indent=2)+'\n')
  print(f'{point}={"PASS" if recovery.returncode==0 else "FAIL"}',flush=True)
 finally:
  if p.poll() is None:p.kill();p.wait(timeout=10)
if any(r['returncode'] for r in results):sys.exit(1)
