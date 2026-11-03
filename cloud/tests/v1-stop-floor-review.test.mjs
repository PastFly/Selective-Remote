import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MigrationFence } from '../src/migration-fence.mjs';
import { verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';
import { installV1CommitFence, useFramedV1Writer } from '../src/v1-commit-fence.mjs';
import { readV1VaultState } from '../src/v1-data-fence.mjs';
import { isolatedPublicationDatabase } from './publication-runtime-fixture.mjs';

const candidate={version:1,fenceVersion:2,maxSchemaVersion:22,readerProjectionVersion:1,wholePublicationVersion:1,v1WriterProtocol:2};

test('a retained stop floor makes the legacy parser and candidate fail closed',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'sr-stop-floor-'));try{
    const file=join(dir,'journal');await writeFile(file,'');const fence=new MigrationFence(file);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const stopID=randomUUID();
    await fence.append({version:2,type:'V1_STOP_PENDING',stopID});
    assert.equal((await fence.snapshot()).v1StopPending,stopID);
    await assert.rejects(verifyDeploymentCompatibility({query:()=>{throw Error('unexpected_query');},fence,candidate}),/deployment_fence_pending/);
    await fence.append({version:2,type:'V1_STOP_CONFIRMED',stopID});
    assert.equal((await fence.snapshot()).writerFloor,2);
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    assert.equal((await fence.snapshot()).writerFloor,2);
    await assert.rejects(verifyDeploymentCompatibility({query:()=>{throw Error('unexpected_query');},fence,candidate:{...candidate,v1WriterProtocol:1}}),/deployment_writer_floor/);
    const actual=await readFile(file,'utf8'); assert.match(actual,/V1_STOP_CONFIRMED/);
  }finally{await rm(dir,{recursive:true,force:true});}
});

test('STOP waits for already admitted framed writer and blocks subsequent old writer', {skip:!process.env.TEST_DATABASE_URL, timeout:60000}, async()=>{
  const { armV1StopFence } = await import('../src/v1-commit-fence.mjs');
  assert.equal(typeof armV1StopFence,'function');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-stop-db-')); let writer;
  try{
    const user=randomUUID();await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'stopfloor@example.test','stopfloor_test',now())",[user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    await installV1CommitFence(db.pool); const file=join(dir,'journal');await writeFile(file,'');const fence=new MigrationFence(file);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    writer=await db.pool.connect();await writer.query('BEGIN');await useFramedV1Writer(writer);
    await writer.query("UPDATE personal_vaults SET revision=2,ciphertext='bmV3' WHERE user_id=$1",[user]);
    let settled=false;const arm=armV1StopFence({pool:db.pool,fence,stopID:randomUUID()}).finally(()=>{settled=true;});
    await new Promise(r=>setTimeout(r,150));assert.equal(settled,false,'exclusive fence must wait for admitted transaction');
    await writer.query('ROLLBACK');writer.release();writer=null;
    assert.equal((await arm).writerFloor,2);
    const old=await db.pool.connect();try{await old.query('BEGIN');await useFramedV1Writer(old);await assert.rejects(old.query("UPDATE personal_vaults SET revision=2,ciphertext='c3RhbGU' WHERE user_id=$1",[user]),/v1_write_stopped/);await old.query('ROLLBACK');}finally{old.release();}
    const row=(await db.pool.query('SELECT revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows[0];assert.equal(Number(row.revision),1);assert.equal(row.ciphertext,'c2VlZA');
  }finally{if(writer){await writer.query('ROLLBACK');writer.release();}await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('old parser rejects new durable stop events',async()=>{
  const {execFileSync}=await import('node:child_process'); const {pathToFileURL}=await import('node:url');
  const dir=await mkdtemp(join(tmpdir(),'sr-old-parser-'));
  try{
    const source=execFileSync('git',['show','5fdf36e3bbeff01151bbf6e695b808594e4ba919:cloud/src/migration-fence-journal.mjs'],{encoding:'utf8'});
    const file=join(dir,'legacy.mjs');await writeFile(file,source);const legacy=await import(pathToFileURL(file).href);
    assert.throws(()=>legacy.validateFenceEvent({version:2,type:'V1_STOP_PENDING',stopID:randomUUID()}),/invalid_deployment_fence/);
    assert.throws(()=>legacy.validateFenceEvent({version:2,type:'V1_STOP_CONFIRMED',stopID:randomUUID()}),/invalid_deployment_fence/);
  }finally{await rm(dir,{recursive:true,force:true});}
});

test('pending STOP survives failure before terminal and same operation can recover safely', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
  const {armV1StopFence,assertV1StopFence}=await import('../src/v1-commit-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-stop-recover-'));
  try{
    const file=join(dir,'journal');await writeFile(file,'');const fence=new MigrationFence(file),stopID=randomUUID();
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>db.pool.query(s,v))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const failing={snapshot:()=>fence.snapshot(),assertWritable:()=>fence.assertWritable(),async append(e){if(e.type==='V1_STOP_CONFIRMED')throw Error('synthetic_terminal_failure');return fence.append(e);}};
    await assert.rejects(armV1StopFence({pool:db.pool,fence:failing,stopID}),/synthetic_terminal_failure/);
    assert.equal((await fence.snapshot()).v1StopPending,stopID);
    await assertV1StopFence((s,v)=>db.pool.query(s,v));
    await assert.rejects(verifyDeploymentCompatibility({query:()=>{throw Error('unexpected_query')},fence,candidate}),/deployment_fence_pending/);
    assert.equal((await armV1StopFence({pool:db.pool,fence:new MigrationFence(file),stopID})).writerFloor,2);
    assert.equal((await verifyDeploymentCompatibility({query:(s,v)=>db.pool.query(s,v),fence,candidate})).writerFloor,2);
    await db.pool.query('ALTER TABLE public.personal_vaults DISABLE TRIGGER selective_remote_stop_v1_writer');
    await assert.rejects(verifyDeploymentCompatibility({query:(s,v)=>db.pool.query(s,v),fence,candidate}),/v1_writer_fence_missing/);
  }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('active framed DB fence currently rejects new personal and Team vault creation', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
  const {PostgresStore}=await import('../src/postgres-store.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try{
    const owner=randomUUID(),team=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'owner-stop@example.test','stop_owner',now())",[owner]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'Synthetic Team',$2)",[team,owner]);
    await db.pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')",[team,owner]);
    await installV1CommitFence(db.pool);const store=new PostgresStore(null,db.pool);
    await assert.rejects(store.createUser({email:'new-stop@example.test',username:'stop_new',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'a'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)}),/v1_writer_upgrade_required/);
    assert.equal((await db.pool.query("SELECT 1 FROM users WHERE email='new-stop@example.test'")).rowCount,0);
    await assert.rejects(store.createSharedVault({actorUserID:owner,teamID:team,name:'Synthetic Vault',idempotencyKey:'synthetic-stop-creation'}),/v1_writer_upgrade_required/);
    assert.equal((await db.pool.query('SELECT 1 FROM shared_vaults WHERE team_id=$1',[team])).rowCount,0);
  }finally{await db.cleanup();}
});

test('STOP pending reserves terminal bytes before changing retained journal',async()=>{
  const {FENCE_MAX_BYTES}=await import('../src/migration-fence-journal.mjs');
  const dir=await mkdtemp(join(tmpdir(),'sr-stop-capacity-'));
  try{
    const file=join(dir,'journal'),id=randomUUID();const baseline={version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]};
    const floor={version:2,type:'V1_WRITER_FLOOR',writerProtocol:1},line=JSON.stringify(floor)+'\n';
    const pending=JSON.stringify({version:2,type:'V1_STOP_PENDING',stopID:id})+'\n';
    const terminal=JSON.stringify({version:2,type:'V1_STOP_CONFIRMED',stopID:id})+'\n';
    const prefix=JSON.stringify(baseline)+'\n'+line;
    const repetitions=Math.floor((FENCE_MAX_BYTES-Buffer.byteLength(prefix)-Buffer.byteLength(pending)-Buffer.byteLength(terminal))/Buffer.byteLength(line))+1;
    await writeFile(file,prefix+line.repeat(repetitions));const before=await readFile(file);
    const fence=new MigrationFence(file);await assert.rejects(fence.append(JSON.parse(pending)),/deployment_fence_limit/);
    assert.deepEqual(await readFile(file),before,'rejection must not append any bytes');
  }finally{await rm(dir,{recursive:true,force:true});}
});

test('post-pending concurrent V1 write cannot append an intent',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'sr-stop-race-'));
  try{
    const file=join(dir,'journal');await writeFile(file,'');const fence=new MigrationFence(file);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    await fence.append({version:2,type:'V1_STOP_PENDING',stopID:randomUUID()});
    const before=await readFile(file);
    await assert.rejects(fence.append({version:2,type:'V1_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),baseRevision:0,revision:1,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)}),/deployment_fence_conflict/);
    assert.deepEqual(await readFile(file),before);
  }finally{await rm(dir,{recursive:true,force:true});}
});

test('ambiguous STOP trigger COMMIT keeps pending until guarded repeat confirms exact state', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
  const {armV1StopFence,assertV1StopFence}=await import('../src/v1-commit-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-stop-ambiguous-'));
  try{
    const file=join(dir,'journal');await writeFile(file,'');const fence=new MigrationFence(file),stopID=randomUUID();
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>db.pool.query(s,v))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    let injected=false;const uncertain={query:(s,v)=>db.pool.query(s,v),async connect(){const c=await db.pool.connect();return {async query(s,v){if(s==='COMMIT'&&!injected){injected=true;await c.query(s,v);throw Error('synthetic_lost_stop_commit_reply');}return c.query(s,v);},release(){c.release();}}}};
    await assert.rejects(armV1StopFence({pool:uncertain,fence,stopID}),/synthetic_lost_stop_commit_reply/);
    assert.equal((await fence.snapshot()).v1StopPending,stopID);await assertV1StopFence((s,v)=>db.pool.query(s,v));
    await assert.rejects(verifyDeploymentCompatibility({query:()=>{throw Error('unexpected_query')},fence,candidate}),/deployment_fence_pending/);
    assert.equal((await armV1StopFence({pool:db.pool,fence:new MigrationFence(file),stopID})).writerFloor,2);
    assert.equal((await verifyDeploymentCompatibility({query:(s,v)=>db.pool.query(s,v),fence,candidate})).writerFloor,2);
  }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('restoring an actual pre-stop PG backup cannot start with retained confirmed STOP journal', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
  const {execFile}=await import('node:child_process');const {promisify}=await import('node:util');const exec=promisify(execFile);
  const {armV1StopFence}=await import('../src/v1-commit-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-stop-restore-'));let restored;
  try{
    const file=join(dir,'journal'),backup=join(dir,'before-stop.dump');await writeFile(file,'');const fence=new MigrationFence(file);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>db.pool.query(s,v))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    await exec('pg_dump',['--format=custom','--no-owner','--no-acl','--file',backup,db.databaseURL]);
    const stopID=randomUUID();await armV1StopFence({pool:db.pool,fence,stopID});
    restored=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);await restored.pool.query('DROP SCHEMA public CASCADE');await restored.pool.query('CREATE SCHEMA public');
    await exec('pg_restore',['--exit-on-error','--no-owner','--no-acl','--dbname',restored.databaseURL,backup]);
    await assert.rejects(verifyDeploymentCompatibility({query:(s,v)=>restored.pool.query(s,v),fence,candidate}),/v1_writer_fence_missing/);
    await assert.rejects(armV1StopFence({pool:restored.pool,fence,stopID}),/v1_writer_fence_missing/,'confirmed journal must never recreate missing STOP triggers on old restore');
    await assert.rejects(verifyDeploymentCompatibility({query:()=>{throw Error('unexpected_query')},fence,candidate:{...candidate,v1WriterProtocol:1}}),/deployment_writer_floor/);
  }finally{await restored?.cleanup();await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('crash immediately after durable STOP pending leaves old clients and new startup blocked', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
  const {armV1StopFence,assertV1StopFence}=await import('../src/v1-commit-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-stop-pre-db-crash-'));
  try{
    const file=join(dir,'journal');await writeFile(file,'');const fence=new MigrationFence(file),stopID=randomUUID();
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((s,v)=>db.pool.query(s,v))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const failingPool={query:(s,v)=>db.pool.query(s,v),async connect(){throw Error('synthetic_process_failure_before_db_guard');}};
    await assert.rejects(armV1StopFence({pool:failingPool,fence,stopID}),/synthetic_process_failure_before_db_guard/);
    assert.equal((await new MigrationFence(file).snapshot()).v1StopPending,stopID);
    await assert.rejects(assertV1StopFence((s,v)=>db.pool.query(s,v)),/v1_writer_fence_missing/);
    await assert.rejects(verifyDeploymentCompatibility({query:()=>{throw Error('unexpected_query')},fence,candidate}),/deployment_fence_pending/);
    const {execFileSync}=await import('node:child_process');const {pathToFileURL}=await import('node:url');
    const legacyFile=join(dir,'legacy.mjs');await writeFile(legacyFile,execFileSync('git',['show','5fdf36e3bbeff01151bbf6e695b808594e4ba919:cloud/src/migration-fence-journal.mjs'],{encoding:'utf8'}));
    const legacy=await import(pathToFileURL(legacyFile).href);
    const events=(await readFile(file,'utf8')).trim().split('\n').map(JSON.parse);
    assert.throws(()=>legacy.reduceFenceEvents(events),/invalid_deployment_fence/);
    assert.equal((await armV1StopFence({pool:db.pool,fence:new MigrationFence(file),stopID})).writerFloor,2);
  }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});
