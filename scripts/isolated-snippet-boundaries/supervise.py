import fcntl,json,os,signal,subprocess,sys,time
from pathlib import Path
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
root=Path(os.environ['SR_SNIPPET_FAULT_ROOT']);root.mkdir(mode=0o700,exist_ok=False)
exe=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(exist_ok=True);results=[]
for point in ('before_group','after_group','after_template','before_remove_template','after_remove_template','before_remove_group','after_remove_group','before_journal','after_journal','before_clear','after_clear','before_remove_journal','after_remove_journal','before_remove_clear','after_remove_clear'):
 seed=subprocess.run([str(exe),'seed',point],capture_output=True,text=True,timeout=20)
 if seed.returncode: raise RuntimeError(f'{point} seed {seed.stderr}')
 p=subprocess.Popen([str(exe),'fault',point],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  marker=root/f'stopped-{point}';deadline=time.monotonic()+25
  while not marker.exists() and time.monotonic()<deadline:
   if p.poll() is not None:raise RuntimeError(f'{point} before boundary {p.communicate()}')
   time.sleep(.05)
  if not marker.exists():raise TimeoutError(point)
  deadline=time.monotonic()+3
  while True:
   waited,status=os.waitpid(p.pid,os.WNOHANG|os.WUNTRACED)
   if waited==p.pid and os.WIFSTOPPED(status):break
   if waited==p.pid or time.monotonic()>=deadline:raise RuntimeError('child not stopped')
   time.sleep(.01)
  fd=os.open(root/f'lock-{point}'/'native-app.lock',os.O_RDONLY|os.O_NOFOLLOW)
  try:
   try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);raise RuntimeError('lock unexpectedly free')
   except BlockingIOError:pass
  finally:os.close(fd)
  os.kill(p.pid,signal.SIGKILL);p.communicate(timeout=10)
  if p.returncode!=-signal.SIGKILL:raise RuntimeError('not killed')
  recovered=subprocess.run([str(exe),'recover',point],capture_output=True,text=True,timeout=25)
  results.append({'boundary':point,'sigkill':True,'returncode':recovered.returncode,'stdout':recovered.stdout,'stderr':recovered.stderr})
  out.joinpath('snippet-atomicity.json').write_text(json.dumps({'results':results,'scope':'exact snippet store source, real isolated UserDefaults, instrumented flush and SIGKILL between group and template writes'},indent=2)+'\n')
  print(f'{point}={"PASS" if recovered.returncode==0 else "FAIL"}',flush=True)
 finally:
  if p.poll() is None:p.kill();p.wait(timeout=10)
if any(x['returncode'] for x in results):sys.exit(1)
