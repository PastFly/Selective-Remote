import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { hashSessionToken } from '../src/security.mjs';
import { MigrationFence } from '../src/migration-fence.mjs';
import { readV1VaultState } from '../src/v1-data-fence.mjs';
import { installV1CommitFence } from '../src/v1-commit-fence.mjs';
import { isolatedPublicationDatabase, publicationRuntimeFixture, stopPublicationRuntime } from './publication-runtime-fixture.mjs';

// A current-protocol writer must not publish a possibly stale local snapshot
// until a safe 0.31/0.32 cutover exists. The test starts the actual HTTP server
// against disposable PostgreSQL; no fake route or test-only policy is used.
test('Personal and Team V1 writes fail closed while current data remains readable', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL); let runtime;
  try {
    const user=randomUUID(),device=randomUUID(),session=randomUUID(),team=randomUUID(),vault=randomUUID();
    const token='t'.repeat(43),pepper='s'.repeat(32);
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'cutover@example.test','cutover_test',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'synthetic','web')",[device,user]);
    await db.pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[session,user,device,hashSessionToken(token,pepper)]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','cGVyc29uYWw','nonce','auth','hash')",[user]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX',$2)",[team,user]);
    await db.pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash) VALUES($1,$2,'TEST-ONLY-CODEX',$3,1,1,'dGVhbQ','nonce','auth','hash')",[vault,team,user]);
    const fixture=await publicationRuntimeFixture(db.databaseURL),fence=new MigrationFence(fixture.path);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const before=await readV1VaultState((sql,values)=>db.pool.query(sql,values));
    const journalBefore=createHash('sha256').update(await readFile(fixture.path)).digest('hex');
    const socket=createServer(); await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));
    const port=socket.address().port; await new Promise(resolve=>socket.close(resolve));
    const origin=`http://127.0.0.1:${port}`;
    const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),stdio:'ignore',env:{
      PATH:process.env.PATH,DATABASE_URL:db.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),CLOUD_PUBLIC_ORIGIN:origin,
      SESSION_TOKEN_PEPPER:pepper,EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
      TEAM_INVITATION_TOKEN_PEPPER:'i'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),
      PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_FENCE_PATH:fixture.path,
    }});
    runtime={child,cleanup:fixture.cleanup};
    let ready=false;
    for(let i=0;i<100;i++){if(child.exitCode!==null)throw Error('test_cloud_start_failed');try{if((await fetch(`${origin}/readyz`)).ok){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,50));}
    assert.equal(ready,true);
    const headers={Authorization:`Bearer ${token}`,'Content-Type':'application/json','X-Selective-V1-Write-Fence':'1','Idempotency-Key':'synthetic-cutover-test'};
    const read=await fetch(`${origin}/v1/vault`,{headers});assert.equal(read.status,200);
    for(const path of ['/v1/vault',`/v1/teams/${team}/vaults/${vault}`]){
      const response=await fetch(origin+path,{method:'PUT',headers,body:JSON.stringify({protocol:'framed-v1',envelope:{}})});
      assert.equal(response.status,503,`${path} must stop before processing a current writer`);
      assert.deepEqual(await response.json(),{error:'vault_write_temporarily_unavailable'});
      const legacy=await fetch(origin+path,{method:'PUT',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:'{}'});
      assert.equal(legacy.status,426,`${path} must also reject old unframed writers`);
    }
    assert.deepEqual(await readV1VaultState((sql,values)=>db.pool.query(sql,values)),before);
    assert.equal(createHash('sha256').update(await readFile(fixture.path)).digest('hex'),journalBefore);
  } finally { await stopPublicationRuntime(runtime); await db.cleanup(); }
});
