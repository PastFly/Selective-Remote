import json,os,secrets,shlex,subprocess,sys
from pathlib import Path
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
root=Path(os.environ['SR_KEYCHAIN_FAULT_ROOT']);root.mkdir(mode=0o700,exist_ok=False)
exe=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(exist_ok=True)
def sec(*args):
 p=subprocess.run(['security',*args],capture_output=True,text=True,timeout=30)
 if p.returncode:raise RuntimeError(f'synthetic keychain setup: {args[0]} exit={p.returncode}')
 return p.stdout
original_default=shlex.split(sec('default-keychain','-d','user'));original_keychains=shlex.split(sec('list-keychains','-d','user'));path=root/'synthetic-matrix.keychain-db';password=secrets.token_hex(24);results=[]
try:
 sec('create-keychain','-p',password,str(path));sec('set-keychain-settings','-lut','1800',str(path));sec('unlock-keychain','-p',password,str(path));sec('list-keychains','-d','user','-s',str(path));sec('default-keychain','-d','user','-s',str(path))
 for mode in ('seed','migrate','restart','delete','verify-delete'):
  p=subprocess.run([str(exe),mode],capture_output=True,text=True,timeout=40)
  if p.returncode:raise RuntimeError(f'{mode}: {p.stderr}')
  results.append({'phase':mode,'result':p.stdout.strip()});print(p.stdout.strip(),flush=True)
  out.joinpath('keychain-matrix.json').write_text(json.dumps({'scope':'exact UnifiedCredentialVault source and six synthetic account shapes seeded directly in legacy v1 vault; no real 0.31 UI or Touch ID','results':results},indent=2)+'\n')
finally:
 if original_default:sec('default-keychain','-d','user','-s',original_default[0])
 if original_keychains:sec('list-keychains','-d','user','-s',*original_keychains)
 if path.exists():sec('delete-keychain',str(path))
