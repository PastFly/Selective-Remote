import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFile,spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {hashSessionToken} from '../src/security.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {readV1VaultState} from '../src/v1-data-fence.mjs';
import {isolatedPublicationDatabase,publicationRuntimeFixture,stopPublicationRuntime} from './publication-runtime-fixture.mjs';
import {syntheticHttpAnchor,syntheticHttpAnchorAvailable} from './synthetic-http-anchor-fixture.mjs';

test('old database restore cannot resurrect a logged-out session with Personal Vault access', {skip:!process.env.TEST_DATABASE_URL||!syntheticHttpAnchorAvailable,timeout:60000,todo:'session revocation is not yet retained by the independent security history'},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-session-revoke-restore-'));let restored,fixture,anchor,runtime;
 try{
  const user=randomUUID(),device=randomUUID(),session=randomUUID(),token='t'.repeat(43),pepper='s'.repeat(32);
  await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'session-rollback@example.test','session_rollback',now())",[user]);
  await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'synthetic','web')",[device,user]);
  await db.pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[session,user,device,hashSessionToken(token,pepper)]);
  await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','QUJD','BBBBBBBBBBBBBBBB','CCCCCCCCCCCCCCCCCCCCCC','DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD')",[user]);
  fixture=await publicationRuntimeFixture(db.databaseURL);anchor=await syntheticHttpAnchor(fixture.path);const fence=anchor.fence;
  await installV1CommitFence(db.pool);await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
  const dump=join(dir,'before-logout.dump'),run=promisify(execFile);await run('pg_dump',['--format=custom','--no-owner','--no-acl','--file',dump,db.databaseURL]);const oldHead=await fence.anchor.read();
  async function server(databaseURL){
   const sock=createServer();await new Promise(resolve=>sock.listen(0,'127.0.0.1',resolve));const port=sock.address().port;await new Promise(resolve=>sock.close(resolve));const origin=`http://127.0.0.1:${port}`;
   const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:'ignore',env:{PATH:process.env.PATH,USER:process.env.USER,DATABASE_URL:databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),CLOUD_PUBLIC_ORIGIN:origin,SESSION_TOKEN_PEPPER:pepper,EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_FENCE_PATH:fixture.path,...anchor.env}});
   runtime={child};for(let i=0;i<100;i++){if(child.exitCode!==null)throw Error('test_cloud_start_failed');try{if((await fetch(origin+'/readyz')).ok)return origin;}catch{}await new Promise(resolve=>setTimeout(resolve,50));}throw Error('test_cloud_ready_timeout');
  }
  let origin=await server(db.databaseURL);const headers={Authorization:`Bearer ${token}`};
  assert.equal((await fetch(origin+'/v1/vault',{headers})).status,200);
  assert.equal((await fetch(origin+'/v1/auth/logout',{method:'POST',headers})).status,204);
  assert.equal((await fetch(origin+'/v1/vault',{headers})).status,401);
  assert.deepEqual(await fence.anchor.read(),oldHead,'logout should not be assumed retained until proven');
  await stopPublicationRuntime(runtime);runtime=null;
  restored=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);await run('pg_restore',['--clean','--if-exists','--no-owner','--no-acl','--dbname',restored.databaseURL,dump]);
  origin=await server(restored.databaseURL);
  const result=await fetch(origin+'/v1/vault',{headers});console.log('SYNTHETIC_LOGGED_OUT_SESSION_AFTER_DB_RESTORE_STATUS='+result.status);
  assert.notEqual(result.status,200,'restored logged-out session must not receive Personal Vault');
 }finally{await stopPublicationRuntime(runtime);await restored?.cleanup();await anchor?.cleanup();await fixture?.cleanup();await db.cleanup();await rm(dir,{recursive:true,force:true});}
});
