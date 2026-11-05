import errno,fcntl,os,sys
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('USER')=='runner'
assert sys.argv[1] in ('busy','free')
path=os.path.join(os.environ['HOME'],'Library/Application Support/Selective Remote/CredentialLocks/native-app.lock')
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
try:
 try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); state='free'
 except OSError as e:
  if e.errno not in (errno.EAGAIN,errno.EWOULDBLOCK): raise
  state='busy'
 print('SYNTHETIC_LEASE_STATE='+state.upper()); assert state==sys.argv[1]
finally: os.close(fd)
