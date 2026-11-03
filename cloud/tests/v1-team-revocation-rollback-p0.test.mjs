import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFile,spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {fileURLToPath} from 'node:url';
import {hashSessionToken} from '../src/security.mjs';
import {stopPublicationRuntime} from './publication-runtime-fixture.mjs';
import {promisify} from 'node:util';
import {PostgresStore} from '../src/postgres-store.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {verifyDeploymentCompatibility,currentCapabilities} from '../src/deployment-compatibility.mjs';
import {isolatedPublicationDatabase,publicationRuntimeFixture} from './publication-runtime-fixture.mjs';
import {syntheticHttpAnchor,syntheticHttpAnchorAvailable} from './synthetic-http-anchor-fixture.mjs';

// This fixture starts an isolated DB and separate TLS anchor. The only restored
// database and identities are synthetic; no existing user data is touched.
test('old membership restore cannot resurrect Team Vault HTTP access while safety stop is active', {skip:!process.env.TEST_DATABASE_URL||!syntheticHttpAnchorAvailable,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-team-revoke-restore-'));let restored,fixture,anchor,runtime;
 try{
  const owner=randomUUID(),member=randomUUID(),ownerDevice=randomUUID(),memberDevice=randomUUID(),team=randomUUID(),vault=randomUUID(),ownerMembership=randomUUID(),memberMembership=randomUUID();
  await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES ($1,'owner-rollback@example.test','owner_rollback',now()),($2,'member-rollback@example.test','member_rollback',now())",[owner,member]);
  const key=JSON.stringify({kty:'EC',crv:'P-256',x:'A'.repeat(43),y:'B'.repeat(43),ext:true,key_ops:[]});
  await db.pool.query("INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES ($1,$2,'synthetic','web',$3,'p256-ecdh-v1',now(),now()),($4,$5,'synthetic','web',$3,'p256-ecdh-v1',now(),now())",[ownerDevice,owner,key,memberDevice,member]);
  const token='t'.repeat(43),pepper='s'.repeat(32),session=randomUUID();
  await db.pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[session,member,memberDevice,hashSessionToken(token,pepper)]);
  await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX',$2)",[team,owner]);
  await db.pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'owner'),($4,$2,$5,'viewer')",[ownerMembership,team,owner,memberMembership,member]);
  await db.pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash) VALUES($1,$2,'TEST-ONLY-CODEX',$3,1,1,'AA','BBBBBBBBBBBBBBBB','CCCCCCCCCCCCCCCCCCCCCC','DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD')",[vault,team,owner]);
  for(const [membership,device] of [[ownerMembership,ownerDevice],[memberMembership,memberDevice]])await db.pool.query("INSERT INTO shared_vault_key_wrappers(vault_id,key_generation,membership_id,membership_epoch,device_id,wrapper_version,ephemeral_public_key,ciphertext,nonce,auth_tag,context_hash,created_by_device_id) VALUES($1,1,$2,1,$3,1,$4::jsonb,$5,$6,$7,$8,$9)",[vault,membership,device,key,'E'.repeat(43),'F'.repeat(16),'G'.repeat(22),'H'.repeat(43),ownerDevice]);
  fixture=await publicationRuntimeFixture(db.databaseURL);anchor=await syntheticHttpAnchor(fixture.path);const fence=anchor.fence;
  await installV1CommitFence(db.pool);
  await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
  await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
  const store=new PostgresStore(null,db.pool,{v1Fence:fence});assert.equal((await store.getSharedVault(team,vault,member,memberDevice)).id,vault);
  const run=promisify(execFile),dump=join(dir,'before-revocation.dump');await run('pg_dump',['--format=custom','--no-owner','--no-acl','--file',dump,db.databaseURL]);
  const oldHead=await fence.anchor.read();
  await store.revokeTeamMembership({actorUserID:owner,teamID:team,membershipID:memberMembership,idempotencyKey:'test-only-revoke-rollback'});
  await assert.rejects(store.getSharedVault(team,vault,member,memberDevice),/team_not_found/);
  const newHead=await fence.anchor.read();assert.deepEqual(newHead,oldHead,'repro: revocation does not advance retained history');
  await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot());
  restored=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  await run('pg_restore',['--clean','--if-exists','--no-owner','--no-acl','--dbname',restored.databaseURL,dump]);
  const restoredStore=new PostgresStore(null,restored.pool,{v1Fence:fence});
  const resurrected=await restoredStore.getSharedVault(team,vault,member,memberDevice);
  assert.equal(resurrected.id,vault);assert.ok(resurrected.wrapper_ciphertext);
  assert.equal((await verifyDeploymentCompatibility({fence,candidate:currentCapabilities,query:(sql,values)=>restored.pool.query(sql,values)})).compatible,true);
  const listener=createServer();await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve));const port=listener.address().port;await new Promise(resolve=>listener.close(resolve));const origin=`http://127.0.0.1:${port}`;
  const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:'ignore',env:{PATH:process.env.PATH,USER:process.env.USER,DATABASE_URL:restored.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),CLOUD_PUBLIC_ORIGIN:origin,
   SESSION_TOKEN_PEPPER:pepper,EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_FENCE_PATH:fixture.path,...anchor.env}});runtime={child};
  let ready=false;for(let i=0;i<100;i++){if(child.exitCode!==null)throw Error('test_cloud_start_failed');try{if((await fetch(`${origin}/readyz`)).ok){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,50));}assert.equal(ready,true);
  const headers={Authorization:`Bearer ${token}`,'Content-Type':'application/json','Idempotency-Key':'test-only-safety-stop'};
  assert.equal((await fetch(origin+'/v1/me',{headers})).status,200);
  assert.equal((await fetch(origin+'/v1/devices',{headers})).status,200);
  for(const [method,path] of [['GET','/v1/teams'],['GET',`/v1/teams/${team}/vaults/${vault}`],['GET',`/v1/teams/${team}/vaults/${vault}/publication/header`],['GET',`/v1/teams/${team}/vaults/${vault}/publication/inspection`],['GET',`/v1/teams/${team}/publication/context`],['POST',`/v1/teams/${team}/publication/preview`],['GET',`/v1/teams/${team}/members`],['POST','/v1/teams'],['PATCH',`/v1/teams/${team}/members/${memberMembership}`],['DELETE',`/v1/teams/${team}/members/${memberMembership}`],['GET','/v1/team-invitations'],['GET',`/v1/teams/${team}/invitations`],['POST','/v1/team-invitations/accept'],['POST',`/v1/teams/${team}/invitations`],['POST',`/v1/teams/${team}/members/${memberMembership}/devices/${memberDevice}/approve`],['POST',`/v1/devices/${memberDevice}`],['POST','/v1/devices/bootstrap-key'],['POST','/v1/device-trust'],['POST','/v1/device-trust/requests'],['POST',`/v1/device-trust/requests/${randomUUID()}/approve`],['POST',`/v1/device-trust/devices/${memberDevice}/revoke`],['DELETE',`/v1/devices/${memberDevice}`]]){
   const response=await fetch(origin+path,{method,headers,...(['POST','PATCH'].includes(method)?{body:'{}'}:{})});assert.equal(response.status,503,`${method} ${path}`);assert.deepEqual(await response.json(),{error:'team_security_temporarily_unavailable'});
  }
 }finally{await stopPublicationRuntime(runtime);await restored?.cleanup();await anchor?.cleanup();await fixture?.cleanup();await db.cleanup();await rm(dir,{recursive:true,force:true});}
});
