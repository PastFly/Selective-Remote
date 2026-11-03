import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {PostgresStore} from '../src/postgres-store.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {isolatedPublicationDatabase} from './publication-runtime-fixture.mjs';

test('empty Personal and Team creation preserve independently retained V1 history', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  const dir=await mkdtemp(join(tmpdir(),'sr-v1-empty-creation-'));
  try {
    const owner=randomUUID(),team=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'owner-create@example.test','owner_create',now())",[owner]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX',$2)",[team,owner]);
    await db.pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')",[team,owner]);
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});
    const fence=new MigrationFence(file);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const store=new PostgresStore(null,db.pool,{v1Fence:fence});
    const user=await store.createUser({email:'new-create@example.test',username:'new_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'a'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)});
    const personal=await store.getVault(user.id);assert.equal(Number(personal.revision),0);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot());
    const created=await store.createSharedVault({actorUserID:owner,teamID:team,name:'TEST-ONLY-CODEX-VAULT',idempotencyKey:'synthetic-create-vault'});
    assert.equal(Number(created.vault.revision),0);
    const snapshot=await fence.snapshot();assert.equal(snapshot.v1Pending.length,0);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),snapshot);
    assert.equal(snapshot.v1Committed.filter(x=>x.vaultID===personal.id||x.vaultID===created.vault.id).length,2);
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('lost COMMIT reply for Personal creation keeps pending intent until durable readback', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-empty-lost-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    let injected=false;
    const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){
      if(sql==='COMMIT'&&!injected){injected=true;await c.query(sql,values);throw Error('synthetic_lost_commit_reply');}
      return c.query(sql,values);
    },release(){c.release();}}}};
    const store=new PostgresStore(null,pool,{v1Fence:fence});
    await assert.rejects(store.createUser({email:'lost-create@example.test',username:'lost_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'b'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)}),/synthetic_lost_commit_reply/);
    const pending=(await new MigrationFence(file).snapshot()).v1Pending;assert.equal(pending.length,1);assert.equal(pending[0].baseRevision,-1);
    const {PublicationFenceCoordinator,readCommittedV1Outcome}=await import('../src/publication-fence-coordinator.mjs');
    const result=await new PublicationFenceCoordinator({fence:new MigrationFence(file)}).reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query:(sql,values)=>db.pool.query(sql,values),intent})});
    assert.equal(result.status,'confirmed');await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await new MigrationFence(file).snapshot());
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('creation with uncertain COMMIT and absent row stays pending fail-closed', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-empty-unknown-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){if(sql==='COMMIT')throw Error('synthetic_commit_not_acknowledged');return c.query(sql,values);},release(){c.release();}}}};
    const store=new PostgresStore(null,pool,{v1Fence:fence});
    await assert.rejects(store.createUser({email:'unknown-create@example.test',username:'unknown_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'c'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)}),/synthetic_commit_not_acknowledged/);
    const snapshot=await new MigrationFence(file).snapshot();assert.equal(snapshot.v1Pending.length,1);
    assert.equal((await db.pool.query("SELECT 1 FROM users WHERE email='unknown-create@example.test'")).rowCount,0);
    const {PublicationFenceCoordinator,readCommittedV1Outcome}=await import('../src/publication-fence-coordinator.mjs');
    const result=await new PublicationFenceCoordinator({fence:new MigrationFence(file)}).reconcile({intentID:snapshot.v1Pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query:(sql,values)=>db.pool.query(sql,values),intent})});
    assert.equal(result.status,'pending');
    await assert.rejects(assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot()),/deployment_fence_pending/);
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('prior journal parser rejects the new empty-Vault creation intent', async()=>{
  const {execFileSync}=await import('node:child_process');
  const source=execFileSync('git',['show','b31462894beef06677385ecab75740174bc3253f:cloud/src/migration-fence-journal.mjs'],{encoding:'utf8'});
  const old=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  const event={version:2,type:'V1_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),baseRevision:-1,revision:0,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)};
  const {validateFenceEvent}=await import('../src/migration-fence-journal.mjs');
  const {v1CiphertextHash}=await import('../src/v1-data-fence.mjs');event.ciphertextHash=v1CiphertextHash(null);
  assert.equal(validateFenceEvent(event).revision,0);
  assert.throws(()=>old.validateFenceEvent(event),/invalid_deployment_fence/);
});

test('missing writer floor fails closed without creating account or changing journal', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-create-floor-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    const {readFile}=await import('node:fs/promises'),before=await readFile(file);
    const store=new PostgresStore(null,db.pool,{v1Fence:fence});
    await assert.rejects(store.createUser({email:'nofloor@example.test',username:'nofloor_test',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'d'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)}),/deployment_v1_history_unavailable/);
    assert.equal((await db.pool.query("SELECT 1 FROM users WHERE email='nofloor@example.test'")).rowCount,0);
    assert.deepEqual(await readFile(file),before);
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('lost COMMIT reply for Team Vault creation retains pending history and replays safely', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-team-lost-'));
  try {
    const owner=randomUUID(),team=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'team-lost@example.test','team_lost',now())",[owner]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX',$2)",[team,owner]);
    await db.pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')",[team,owner]);
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    let injected=false;
    const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){if(sql==='COMMIT'&&!injected){injected=true;await c.query(sql,values);throw Error('synthetic_lost_team_commit_reply');}return c.query(sql,values);},release(){c.release();}}}};
    const request={actorUserID:owner,teamID:team,name:'TEST-ONLY-CODEX-VAULT',idempotencyKey:'lost-team-create'};
    await assert.rejects(new PostgresStore(null,pool,{v1Fence:fence}).createSharedVault(request),/synthetic_lost_team_commit_reply/);
    const pending=(await new MigrationFence(file).snapshot()).v1Pending;assert.equal(pending.length,1);assert.equal(pending[0].vaultKind,'TEAM');assert.equal(pending[0].revision,0);
    const {PublicationFenceCoordinator,readCommittedV1Outcome}=await import('../src/publication-fence-coordinator.mjs');
    const result=await new PublicationFenceCoordinator({fence:new MigrationFence(file)}).reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query:(sql,values)=>db.pool.query(sql,values),intent})});
    assert.equal(result.status,'confirmed');
    const replay=await new PostgresStore(null,db.pool,{v1Fence:fence}).createSharedVault(request);
    assert.equal(replay.vault.id,pending[0].vaultID);
    assert.equal((await db.pool.query('SELECT count(*)::int AS n FROM shared_vaults WHERE team_id=$1',[team])).rows[0].n,1);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot());
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('concurrent Personal creations do not lose retained Vault identities', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-create-concurrent-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const store=new PostgresStore(null,db.pool,{v1Fence:fence});
    const make=n=>({email:`parallel-${n}@example.test`,username:`parallel_${n}`,displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:String(n).repeat(64),verificationExpiresAt:new Date(Date.now()+60000)});
    const results=await Promise.allSettled([store.createUser(make(1)),store.createUser(make(2))]);
    assert.ok(results.some(r=>r.status==='fulfilled'),'at least one creation must commit');
    for(const result of results.filter(r=>r.status==='rejected'))assert.match(result.reason.message,/deployment_fence_pending|deployment_fence_busy|deployment_fence_locked|deployment_v1_data_mismatch/);
    const snapshot=await fence.snapshot();assert.equal(snapshot.v1Pending.length,0);
    const rows=await readV1VaultState((sql,values)=>db.pool.query(sql,values));
    assert.equal(rows.length,results.filter(r=>r.status==='fulfilled').length);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),snapshot);
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('restoring pre-creation journal cannot hide a committed empty Vault', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-create-oldjournal-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const {readFile}=await import('node:fs/promises'),oldBytes=await readFile(file);
    await new PostgresStore(null,db.pool,{v1Fence:fence}).createUser({email:'rollback-create@example.test',username:'rollback_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'e'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)});
    const restored=join(dir,'old-journal');await writeFile(restored,oldBytes,{mode:0o600});
    await assert.rejects(assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await new MigrationFence(restored).snapshot()),/deployment_v1_data_mismatch/);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot());
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('full retained journal refuses account creation without DB mutation', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-create-full-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const {readFile}=await import('node:fs/promises'),{FENCE_MAX_BYTES}=await import('../src/migration-fence-journal.mjs');
    const prefix=await readFile(file),line=Buffer.from(JSON.stringify({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1})+'\n');
    const count=Math.floor((FENCE_MAX_BYTES-prefix.length)/line.length);
    const full=Buffer.concat([prefix,Buffer.from(line.toString().repeat(count))]);await writeFile(file,full);
    const store=new PostgresStore(null,db.pool,{v1Fence:fence});
    await assert.rejects(store.createUser({email:'full-create@example.test',username:'full_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'f'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)}),/deployment_fence_limit/);
    assert.equal((await db.pool.query("SELECT 1 FROM users WHERE email='full-create@example.test'")).rowCount,0);
    assert.deepEqual(await readFile(file),full);
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('empty-Vault intent rejects a non-null ciphertext commitment', async()=>{
  const {validateFenceEvent}=await import('../src/migration-fence-journal.mjs');
  const event={version:2,type:'V1_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),baseRevision:-1,revision:0,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)};
  assert.throws(()=>validateFenceEvent(event),/invalid_deployment_fence/);
});

test('missing committed empty Vault is rejected by retained floor', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-create-olddb-'));
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const user=await new PostgresStore(null,db.pool,{v1Fence:fence}).createUser({email:'olddb-create@example.test',username:'olddb_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'9'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)});
    const {useFramedV1Writer}=await import('../src/v1-commit-fence.mjs');const client=await db.pool.connect();
    try{await client.query('BEGIN');await useFramedV1Writer(client);await client.query('DELETE FROM personal_vaults WHERE user_id=$1',[user.id]);await client.query('COMMIT');}finally{client.release();}
    await assert.rejects(assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot()),/deployment_v1_data_mismatch/);
  } finally {await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('isolated PostgreSQL restore before creation is rejected by retained journal', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-create-restore-'));let restored;
  try {
    const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=new MigrationFence(file);await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const {execFile}=await import('node:child_process'),{promisify}=await import('node:util'),run=promisify(execFile),dump=join(dir,'before.dump');
    await run('pg_dump',['--format=custom','--no-owner','--no-acl','--file',dump,db.databaseURL]);
    await new PostgresStore(null,db.pool,{v1Fence:fence}).createUser({email:'restore-create@example.test',username:'restore_create',displayName:'Synthetic',passwordHash:'synthetic',device:{id:randomUUID(),name:'Synthetic',platform:'web',appVersion:'test',publicKey:null},verificationHash:'8'.repeat(64),verificationExpiresAt:new Date(Date.now()+60000)});
    restored=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    await run('pg_restore',['--clean','--if-exists','--no-owner','--no-acl','--dbname',restored.databaseURL,dump]);
    await assert.rejects(assertV1DataFloor((sql,values)=>restored.pool.query(sql,values),await fence.snapshot()),/deployment_v1_data_mismatch/);
    await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot());
  } finally {await restored?.cleanup();await db.cleanup();await rm(dir,{recursive:true,force:true});}
});
