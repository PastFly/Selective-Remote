import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {isolatedPublicationDatabase,stopPublicationRuntime} from './publication-runtime-fixture.mjs';

for(const kind of ['unconfigured','missing','corrupt']) test(`Cloud must not listen with ${kind} independent deployment journal`, {
  skip: !process.env.TEST_DATABASE_URL, timeout: 30000,
}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),directory=await mkdtemp(join(tmpdir(),'sr-startup-fence-'));let child;
  try {
    const socket=createServer();await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));
    const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
    const journal=join(directory,'journal');
    if(kind==='corrupt')await writeFile(journal,'invalid journal\n',{mode:0o600});
    const fenceEnvironment=kind==='unconfigured'?{}:{PUBLICATION_FENCE_PATH:journal};
    child=spawn(process.execPath,['src/server.mjs'],{
      cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:['ignore','pipe','pipe'],
      env:{PATH:process.env.PATH,DATABASE_URL:db.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),
        CLOUD_PUBLIC_ORIGIN:`http://127.0.0.1:${port}`,SESSION_TOKEN_PEPPER:'s'.repeat(32),
        EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
        TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),
        ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),...fenceEnvironment},
    });
    let stderr='';child.stderr.on('data',data=>{stderr+=data.toString();});
    let result='timeout';
    for(let n=0;n<100;n++){
      if(child.exitCode!==null){result='exit';break;}
      try{if((await fetch(`http://127.0.0.1:${port}/healthz`)).ok){result='listening';break;}}catch{}
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    assert.equal(result,'exit','an unavailable retained journal must prevent listening');
    assert.equal(child.exitCode,1);assert.match(stderr,/Deployment compatibility preflight failed/);
  } finally {await stopPublicationRuntime({child});await db.cleanup();await rm(directory,{recursive:true,force:true});}
});
