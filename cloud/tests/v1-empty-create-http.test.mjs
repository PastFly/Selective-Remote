import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {hashSessionToken} from '../src/security.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {isolatedPublicationDatabase,publicationRuntimeFixture,stopPublicationRuntime} from './publication-runtime-fixture.mjs';

test('real HTTP Team Vault creation is journaled, idempotent and leaves V1 PUT stopped', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let runtime;
  try{
    const user=randomUUID(),device=randomUUID(),session=randomUUID(),team=randomUUID(),token='t'.repeat(43),pepper='s'.repeat(32);
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'http-create@example.test','http_create',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'synthetic','web')",[device,user]);
    await db.pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[session,user,device,hashSessionToken(token,pepper)]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX',$2)",[team,user]);
    await db.pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')",[team,user]);
    const fixture=await publicationRuntimeFixture(db.databaseURL),fence=new MigrationFence(fixture.path);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const {verifyDeploymentCompatibility,currentCapabilities}=await import('../src/deployment-compatibility.mjs');
    await verifyDeploymentCompatibility({query:(sql,values)=>db.pool.query(sql,values),fence,candidate:currentCapabilities});
    const socket=createServer();await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
    const origin=`http://127.0.0.1:${port}`;
    const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:'ignore',env:{
      PATH:process.env.PATH,USER:process.env.USER,DATABASE_URL:db.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),CLOUD_PUBLIC_ORIGIN:origin,
      SESSION_TOKEN_PEPPER:pepper,EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
      TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),
      PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_FENCE_PATH:fixture.path,
    }});runtime={child,cleanup:fixture.cleanup};
    let ready=false;for(let i=0;i<100;i++){if(child.exitCode!==null)throw Error('test_cloud_start_failed');try{if((await fetch(`${origin}/readyz`)).ok){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,50));}assert.equal(ready,true);
    const headers={Authorization:`Bearer ${token}`,'Content-Type':'application/json','Idempotency-Key':'test-only-create-vault'};
    const path=`/v1/teams/${team}/vaults`,body=JSON.stringify({name:'TEST-ONLY-CODEX-HTTP-VAULT'});
    const first=await fetch(origin+path,{method:'POST',headers,body});assert.equal(first.status,201,await first.clone().text());const created=await first.json();
    const retry=await fetch(origin+path,{method:'POST',headers,body});assert.equal(retry.status,201);assert.deepEqual(await retry.json(),created);
    const snapshot=await fence.snapshot();assert.equal(snapshot.v1Pending.length,0);assert.equal(snapshot.v1Committed.length,1);await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),snapshot);
    const retainedHash=createHash('sha256').update(await readFile(fixture.path)).digest('hex');
    const stopped=await fetch(`${origin}/v1/teams/${team}/vaults/${created.vault.id}`,{method:'PUT',headers:{...headers,'X-Selective-V1-Write-Fence':'1'},body:JSON.stringify({protocol:'framed-v1',envelope:{}})});
    assert.equal(stopped.status,503);assert.deepEqual(await stopped.json(),{error:'vault_write_temporarily_unavailable'});
    assert.equal(createHash('sha256').update(await readFile(fixture.path)).digest('hex'),retainedHash);
  }finally{await stopPublicationRuntime(runtime);await db.cleanup();}
});
