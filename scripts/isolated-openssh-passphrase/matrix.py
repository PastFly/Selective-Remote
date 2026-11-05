import json,os,secrets,shlex,subprocess,sys
from pathlib import Path
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
root=Path(os.environ['RUNNER_TEMP'])/'ssh-passphrase-fixture';root.mkdir(mode=0o700); evidence=Path(os.environ['RUNNER_TEMP'])/'evidence';evidence.mkdir(exist_ok=True)
def command(args,env=None,timeout=25):
 p=subprocess.run(args,capture_output=True,text=True,timeout=timeout,env=env)
 if p.returncode:raise RuntimeError(f'{Path(args[0]).name} exit={p.returncode}: {p.stderr[:300]}')
 return p.stdout
sec=lambda *args:command(['/usr/bin/security',*args])
original_default=shlex.split(sec('default-keychain','-d','user'));original_list=shlex.split(sec('list-keychains','-d','user'));kc=root/'synthetic.keychain-db';password=secrets.token_hex(24);secret='TEST-ONLY-'+secrets.token_hex(16);key=root/'synthetic-key';agentpid=None
try:
 sec('create-keychain','-p',password,str(kc));sec('set-keychain-settings','-lut','1800',str(kc));sec('unlock-keychain','-p',password,str(kc));sec('list-keychains','-d','user','-s',str(kc));sec('default-keychain','-d','user','-s',str(kc))
 command(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N',secret,'-f',str(key)])
 askpass=root/'askpass';askpass.write_text('#!/bin/sh\nprintf "%s\\n" "$SR_SYNTHETIC_KEY_PASSPHRASE"\n');askpass.chmod(0o700)
 agent=command(['/usr/bin/ssh-agent','-s','-a',str(root/'agent.sock')]);sock=pid=None
 for field in agent.split(';'):
  field=field.strip()
  if field.startswith('SSH_AUTH_SOCK='):sock=field.split('=',1)[1]
  if field.startswith('SSH_AGENT_PID='):pid=int(field.split('=',1)[1])
 if not sock or not pid:raise RuntimeError('could not read synthetic agent identity')
 agentpid=pid;env=os.environ.copy();env.update({'SSH_AUTH_SOCK':sock,'SSH_AGENT_PID':str(pid),'SSH_ASKPASS':str(askpass),'SSH_ASKPASS_REQUIRE':'force','DISPLAY':':0','SR_SYNTHETIC_KEY_PASSPHRASE':secret})
 command(['/usr/bin/ssh-add','--apple-use-keychain',str(key)],env=env,timeout=40)
 first=command(['/usr/bin/ssh-add','-L'],env=env).split()[1];expected=key.with_suffix('.pub').read_text().split()[1]
 if first!=expected:raise RuntimeError('synthetic key fingerprint mismatch')
 command(['/usr/bin/ssh-add','-D'],env=env)
 command(['/usr/bin/ssh-add','--apple-load-keychain',str(key)],env=env,timeout=40)
 second=command(['/usr/bin/ssh-add','-L'],env=env).split()[1]
 if second!=expected:raise RuntimeError('keychain reload mismatch')
 print('SYNTHETIC_OPENSSH_PASSPHRASE_RELOAD=PASS')
 evidence.joinpath('openssh-keychain.json').write_text(json.dumps({'result':'PASS','scope':'synthetic encrypted SSH key; real ssh-add and temporary agent/Keychain, no app UI or Touch ID','loadedKeyMatchesGeneratedPublicKey':True})+'\n')
finally:
 if agentpid:
  try:os.kill(agentpid,15)
  except ProcessLookupError:pass
 if original_default:sec('default-keychain','-d','user','-s',original_default[0])
 if original_list:sec('list-keychains','-d','user','-s',*original_list)
 if kc.exists():sec('delete-keychain',str(kc))
