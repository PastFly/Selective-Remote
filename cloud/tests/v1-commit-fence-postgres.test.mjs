import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import test from 'node:test';
import { PostgresStore } from '../src/postgres-store.mjs';
import { isolatedPublicationDatabase } from './publication-runtime-fixture.mjs';
import { installV1CommitFence, useFramedV1Writer, assertV1CommitFence } from '../src/v1-commit-fence.mjs';

test('database writer barrier drains in-flight legacy writes and rejects later legacy commits', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let old, writer, late;
  try {
    const user = randomUUID(), user2 = randomUUID(), team = randomUUID(), vault = randomUUID(), device = randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-fence@example.test','p0_fence_test',now())", [user]);
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-fence2@example.test','p0_fence2_test',now())", [user2]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES ($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')", [user]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES ($1,'TEST-ONLY-CODEX-FENCE',$2)", [team,user]);
    await db.pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash) VALUES ($1,$2,'TEST-ONLY-CODEX-FENCE',$3,1,1,'c2VlZA','bm9uY2U','dGFn','aGFzaA')", [vault,team,user]);
    await assert.rejects(assertV1CommitFence((sql,values)=>db.pool.query(sql,values)), /v1_writer_fence_missing/);
    old = await db.pool.connect(); writer = await db.pool.connect(); late = await db.pool.connect();
    await late.query('BEGIN');
    await old.query('BEGIN');
    await old.query("UPDATE personal_vaults SET revision=3,ciphertext='b2xk' WHERE user_id=$1", [user]);
    let installed = false;
    const barrier = installV1CommitFence(db.pool).then(() => { installed = true; });
    await new Promise(resolve => setTimeout(resolve,150));
    assert.equal(installed, false, 'installation must wait for old write transactions');
    await old.query('COMMIT');
    await barrier;
    await assertV1CommitFence((sql,values)=>db.pool.query(sql,values));
    await db.pool.query('ALTER TABLE public.personal_vaults DISABLE TRIGGER selective_remote_framed_v1_writer');
    await assert.rejects(assertV1CommitFence((sql,values)=>db.pool.query(sql,values)), /v1_writer_fence_missing/);
    await db.pool.query('ALTER TABLE public.personal_vaults ENABLE TRIGGER selective_remote_framed_v1_writer');
    await assertV1CommitFence((sql,values)=>db.pool.query(sql,values));
    await db.pool.query("CREATE OR REPLACE FUNCTION public.selective_remote_require_framed_v1_writer() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$");
    await assert.rejects(assertV1CommitFence((sql,values)=>db.pool.query(sql,values)), /v1_writer_fence_missing/);
    await installV1CommitFence(db.pool);
    await assertV1CommitFence((sql,values)=>db.pool.query(sql,values));
    await assert.rejects(late.query('UPDATE personal_vaults SET revision=4 WHERE user_id=$1',[user]), /v1_writer_upgrade_required/, 'transaction begun before installation must not write after it');
    await late.query('ROLLBACK');
    const before = (await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1', [user])).rows;
    const beforeTeam = (await db.pool.query('SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1',[vault])).rows;
    const hash = value => createHash('sha256').update(value).digest('hex');
    await assert.rejects(old.query("UPDATE personal_vaults SET revision=4,ciphertext='bmV3' WHERE user_id=$1", [user]), /v1_writer_upgrade_required/);
    await assert.rejects(old.query('UPDATE shared_vaults SET revision=2 WHERE id=$1', [vault]), /v1_writer_upgrade_required/);
    await assert.rejects(old.query('INSERT INTO personal_vaults(user_id) VALUES($1)',[user2]),/v1_writer_upgrade_required/);
    await assert.rejects(old.query('DELETE FROM personal_vaults WHERE user_id=$1',[user]),/v1_writer_upgrade_required/);
    await assert.rejects(old.query('DELETE FROM shared_vaults WHERE id=$1',[vault]),/v1_writer_upgrade_required/);
    await old.query("UPDATE shared_vaults SET name='TEST-ONLY-CODEX-RENAMED' WHERE id=$1",[vault]);
    assert.equal((await db.pool.query('SELECT name FROM shared_vaults WHERE id=$1',[vault])).rows[0].name,'TEST-ONLY-CODEX-RENAMED');
    const after = (await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1', [user])).rows;
    assert.deepEqual(after,before);
    assert.equal(hash(after[0].ciphertext),hash(before[0].ciphertext));
    assert.deepEqual((await db.pool.query('SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1',[vault])).rows,beforeTeam);
    await installV1CommitFence(db.pool);
    await assert.rejects(old.query('UPDATE personal_vaults SET revision=4 WHERE user_id=$1',[user]), /v1_writer_upgrade_required/, 'reinstallation must retain the fence');
    await writer.query('BEGIN');
    await useFramedV1Writer(writer);
    await writer.query("UPDATE personal_vaults SET revision=4,ciphertext='bmV3' WHERE user_id=$1",[user]);
    await writer.query('UPDATE shared_vaults SET revision=2 WHERE id=$1',[vault]);
    await writer.query('COMMIT');
    assert.equal(Number((await db.pool.query('SELECT revision FROM personal_vaults WHERE user_id=$1',[user])).rows[0].revision),4);
    assert.equal(Number((await db.pool.query('SELECT revision FROM shared_vaults WHERE id=$1',[vault])).rows[0].revision),2);
    await assert.rejects(writer.query('UPDATE personal_vaults SET revision=5 WHERE user_id=$1',[user]), /v1_writer_upgrade_required/, 'writer capability must not leak after COMMIT');
    await writer.query('BEGIN');
    await useFramedV1Writer(writer);
    await writer.query('ROLLBACK');
    await assert.rejects(writer.query('UPDATE personal_vaults SET revision=5 WHERE user_id=$1',[user]), /v1_writer_upgrade_required/, 'writer capability must not leak after ROLLBACK');
    const store = new PostgresStore(null,db.pool);
    const beforeUnfenced=(await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows;
    await assert.rejects(store.putVault(user,device,{baseRevision:4,envelopeVersion:1,wrappedKey:{},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'}),/deployment_fence_required/);
    assert.deepEqual((await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows,beforeUnfenced);
  } finally {
    if (late) { try { await late.query('ROLLBACK'); } catch {} late.release(); }
    if (old) { try { await old.query('ROLLBACK'); } catch {} old.release(); }
    if (writer) { try { await writer.query('ROLLBACK'); } catch {} writer.release(); }
    await db.cleanup();
  }
});

test('current Team writer can initialize through the database barrier', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture;
  try {
    const user=randomUUID(), device=randomUUID(), store=new PostgresStore(null,db.pool);
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-team@example.test','p0_team_test',now())",[user]);
    const team=await store.createTeam({actorUserID:user,name:'TEST-ONLY-CODEX-TEAM',idempotencyKey:'p0-team-create-0001'});
    const publicKey=JSON.stringify({kty:'EC',crv:'P-256',x:'A'.repeat(43),y:'B'.repeat(43),ext:true,key_ops:[]});
    await db.pool.query(`INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at)
      VALUES($1,$2,'test','web',$3,'p256-ecdh-v1',now(),now())`,[device,user,publicKey]);
    const created=await store.createSharedVault({actorUserID:user,teamID:team.team.id,name:'TEST-ONLY-CODEX-VAULT',idempotencyKey:'p0-vault-create-0001'});
    const {teamVaultWrapperContextHash}=await import('../src/security.mjs');
    const wrapper={membershipID:team.membership.id,membershipEpoch:Number(team.membership.epoch),deviceID:device,wrapperVersion:1,
      ephemeralPublicKey:{kty:'EC',crv:'P-256',x:'E'.repeat(43),y:'Z'.repeat(43)},ciphertext:'E'.repeat(43),nonce:'E'.repeat(16),authTag:'E'.repeat(22),
      contextHash:teamVaultWrapperContextHash({teamID:team.team.id,vaultID:created.vault.id,keyGeneration:1,membershipID:team.membership.id,membershipEpoch:Number(team.membership.epoch),deviceID:device})};
    const {MigrationFence}=await import('../src/migration-fence.mjs');
    const {readV1VaultState,assertV1DataFloor}=await import('../src/v1-data-fence.mjs');
    const {publicationRuntimeFixture}=await import('./publication-runtime-fixture.mjs');
    fixture=await publicationRuntimeFixture(db.databaseURL);
    const fence=new MigrationFence(fixture.path);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const request={actorUserID:user,actorDeviceID:device,teamID:team.team.id,vaultID:created.vault.id,
      envelope:{baseRevision:0,keyGeneration:1,envelopeVersion:1,ciphertext:'AA',nonce:'B'.repeat(16),authTag:'C'.repeat(22),contentHash:'D'.repeat(43),wrappers:[wrapper]},
      idempotencyKey:'p0-vault-initialize-0001'};
    await assert.rejects(store.putSharedVault(request),/deployment_fence_required/);
    assert.equal(Number((await db.pool.query('SELECT revision FROM shared_vaults WHERE id=$1',[created.vault.id])).rows[0].revision),0);
    store.v1Fence=fence;
    const result=await store.putSharedVault(request);
    assert.equal(result.revision,1);
    assert.equal((await fence.snapshot()).v1Committed.find(v=>v.vaultID===created.vault.id).revision,1);
    const row=(await db.pool.query('SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1',[created.vault.id])).rows[0];
    assert.deepEqual([row.id,Number(row.revision),row.ciphertext],[created.vault.id,1,'AA']);
    const query=(sql,values)=>db.pool.query(sql,values),snapshot=await fence.snapshot();
    await assert.rejects(db.pool.query('DELETE FROM shared_vault_key_wrappers WHERE vault_id=$1',[created.vault.id]),/v1_writer_upgrade_required/);
    const client=await db.pool.connect();
    try {
      await client.query('BEGIN');await useFramedV1Writer(client);
      await client.query('DELETE FROM shared_vault_key_wrappers WHERE vault_id=$1',[created.vault.id]);
      await client.query('COMMIT');
    } finally {client.release();}
    await assert.rejects(assertV1DataFloor(query,snapshot),/deployment_v1_data_mismatch/,'restored or altered wrapper set must not pass the retained floor');
  } finally { await fixture?.cleanup();await db.cleanup(); }
});

test('an unavailable or corrupted V1 journal cannot authorize a direct writer', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {mkdtemp,writeFile,rm}=await import('node:fs/promises');
  const {join}=await import('node:path');
  const {tmpdir}=await import('node:os');
  const {MigrationFence}=await import('../src/migration-fence.mjs');
  const directory=await mkdtemp(join(tmpdir(),'sr-v1-journal-denial-'));
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try {
    const user=randomUUID(),device=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'journal-denial@example.test','journal_denial_test',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    await installV1CommitFence(db.pool);
    const before=(await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows;
    const journal=join(directory,'journal');await writeFile(journal,'invalid journal\n',{mode:0o600});
    const payload={baseRevision:1,envelopeVersion:1,wrappedKey:{},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'};
    for(const [path,expected] of [[journal,/corrupt_deployment_fence/],[join(directory,'missing'),{code:'ENOENT'}]]) {
      const store=new PostgresStore(null,db.pool,{v1Fence:new MigrationFence(path)});
      await assert.rejects(store.putVault(user,device,payload),expected);
      assert.deepEqual((await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows,before);
    }
  } finally {await db.cleanup();await rm(directory,{recursive:true,force:true});}
});


test('failed installation leaves no partial database barrier', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try {
    const user=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-failure@example.test','p0_failure_test',now())",[user]);
    await db.pool.query('INSERT INTO personal_vaults(user_id) VALUES ($1)',[user]);
    const failPool={async connect(){
      const c=await db.pool.connect();
      return {query(sql,...args){ if (sql.includes('CREATE TRIGGER') && sql.includes('shared_vaults')) throw Error('synthetic_install_failure'); return c.query(sql,...args); },release(){c.release();}};
    }};
    await assert.rejects(installV1CommitFence(failPool),/synthetic_install_failure/);
    const triggers=await db.pool.query("SELECT count(*)::int AS n FROM pg_trigger WHERE tgname='selective_remote_framed_v1_writer' AND NOT tgisinternal");
    assert.equal(triggers.rows[0].n,0,'all DDL must roll back');
    await db.pool.query('UPDATE personal_vaults SET updated_at=now() WHERE user_id=$1',[user]);
  } finally { await db.cleanup(); }
});

test('retained writer floor denies an actual pre-barrier PostgreSQL backup restore', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 120000,
}, async () => {
  const { mkdtemp, rm } = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const { MigrationFence } = await import('../src/migration-fence.mjs');
  const { currentCapabilities, verifyDeploymentCompatibility } = await import('../src/deployment-compatibility.mjs');
  const { publicationRuntimeFixture } = await import('./publication-runtime-fixture.mjs');
  const exec=promisify(execFile), directory=await mkdtemp(join(tmpdir(),'sr-v1-fence-restore-'));
  const original=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let restored, fixture;
  try {
    const user=randomUUID();
    await original.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'restore-p0@example.test','restore_p0_test',now())",[user]);
    await original.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    const before=(await original.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows;
    const archive=join(directory,'before-fence.dump');
    try { await exec(process.env.PG_DUMP_PATH??'pg_dump',['--format=custom','--no-owner','--no-acl','--file',archive,original.databaseURL]); }
    catch { throw Error('synthetic_pg_dump_failed'); }
    fixture=await publicationRuntimeFixture(original.databaseURL);
    await installV1CommitFence(original.pool);
    const fence=new MigrationFence(fixture.path);
    const {readV1VaultState}=await import('../src/v1-data-fence.mjs');
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>original.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const guard=pool=>verifyDeploymentCompatibility({query:(sql,values)=>pool.query(sql,values),fence,candidate:currentCapabilities});
    assert.equal((await guard(original.pool)).writerFloor,1);
    const {v1WriterProtocol:_,emptyVaultCreationVersion:__,wrapperEnvelopeVersion:___,...oldCandidate}=currentCapabilities;
    await assert.rejects(verifyDeploymentCompatibility({query:(sql,values)=>original.pool.query(sql,values),fence,candidate:oldCandidate}),/deployment_writer_floor/);
    restored=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    await restored.pool.query('DROP SCHEMA public CASCADE');
    await restored.pool.query('CREATE SCHEMA public');
    try { await exec(process.env.PG_RESTORE_PATH??'pg_restore',['--exit-on-error','--no-owner','--no-acl','--dbname',restored.databaseURL,archive]); }
    catch { throw Error('synthetic_pg_restore_failed'); }
    assert.deepEqual((await restored.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows,before);
    await assert.rejects(guard(restored.pool),/v1_writer_fence_missing/);
  } finally { await fixture?.cleanup(); await restored?.cleanup(); await original.cleanup(); await rm(directory,{recursive:true,force:true}); }
});

test('V1 data floor rejects altered decryption metadata even when revision and ciphertext match', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {readV1VaultState,assertV1DataFloor}=await import('../src/v1-data-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try {
    const user=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'metadata-p0@example.test','metadata_p0_test',now())",[user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    const query=(sql,values)=>db.pool.query(sql,values);
    const snapshot={v1BaselineID:randomUUID(),v1Committed:await readV1VaultState(query),v1Pending:[]};
    assert.equal(await assertV1DataFloor(query,snapshot),true);
    await db.pool.query("UPDATE personal_vaults SET auth_tag='YWx0ZXJlZA' WHERE user_id=$1",[user]);
    await assert.rejects(assertV1DataFloor(query,snapshot),/deployment_v1_data_mismatch/);
  } finally { await db.cleanup(); }
});

test('V1 floor reads opaque commitments without transferring ciphertext or wrappers to the Cloud process', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {readV1VaultState}=await import('../src/v1-data-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try {
    const user=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'scale-privacy@example.test','scale_privacy',now())",[user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}',repeat('A',8192),'nonce','tag','hash')",[user]);
    let inspected=false;
    const state=await readV1VaultState(async(sql,values)=>{
      const result=await db.pool.query(sql,values);inspected=true;
      for(const row of result.rows){assert.equal('ciphertext' in row,false);assert.equal('envelope' in row,false);}
      return result;
    });
    assert.equal(inspected,true);assert.equal(state.length,1);
    assert.match(state[0].ciphertextHash,/^[a-f0-9]{64}$/u);assert.match(state[0].envelopeHash,/^[a-f0-9]{64}$/u);
  } finally {await db.cleanup();}
});

test('PostgreSQL and client compute identical V1 ciphertext commitments', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {v1CiphertextHash,v1CiphertextHashSQL}=await import('../src/v1-data-fence.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try {
    for(const value of [null,'','AQID_-','тест-中-🙂','A'.repeat(65536)]){
      const result=await db.pool.query(`SELECT ${v1CiphertextHashSQL('$1::text')} AS value`,[value]);
      assert.equal(result.rows[0].value,v1CiphertextHash(value));
    }
  } finally {await db.cleanup();}
});

test('current writer holds barrier integrity until its transaction commits', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let release,fixture;
  try {
    const user=randomUUID(),device=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-commit@example.test','p0_commit_test',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    await installV1CommitFence(db.pool);
    const {MigrationFence}=await import('../src/migration-fence.mjs');
    const {readV1VaultState}=await import('../src/v1-data-fence.mjs');
    const {publicationRuntimeFixture}=await import('./publication-runtime-fixture.mjs');
    fixture=await publicationRuntimeFixture(db.databaseURL);const fence=new MigrationFence(fixture.path);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    let reached;
    const atWrite=new Promise(resolve=>{reached=resolve;});
    const pause=new Promise(resolve=>{release=resolve;});
    const pool={async connect(){const c=await db.pool.connect();return {
      async query(sql,values){if(sql.includes('SELECT id, revision FROM personal_vaults')){reached();await pause;}return c.query(sql,values);},
      release(){c.release();},
    };}};
    const store=new PostgresStore(null,pool,{v1Fence:fence});
    const write=store.putVault(user,device,{baseRevision:1,envelopeVersion:1,wrappedKey:{},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'});
    await atWrite;
    let tampered=false;
    const disable=db.pool.query('ALTER TABLE public.personal_vaults DISABLE TRIGGER selective_remote_framed_v1_writer').then(()=>{tampered=true;});
    await new Promise(resolve=>setTimeout(resolve,150));
    try { assert.equal(tampered,false,'barrier DDL must wait until the writer transaction ends'); } finally { release(); release=null; }
    assert.deepEqual(await write,{conflict:false,revision:2});
    await disable;
    await assert.rejects(assertV1CommitFence((sql,values)=>db.pool.query(sql,values)),/v1_writer_fence_missing/);
  } finally { release?.(); await fixture?.cleanup(); await db.cleanup(); }
});

test('arming fails closed with an undrained writer and retains the floor only after barrier verification', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const { armV1CommitFence }=await import('../src/v1-commit-fence.mjs');
  const { MigrationFence }=await import('../src/migration-fence.mjs');
  const { publicationRuntimeFixture }=await import('./publication-runtime-fixture.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture,blocker;
  try {
    fixture=await publicationRuntimeFixture(db.databaseURL);
    const fence=new MigrationFence(fixture.path);
    blocker=await db.pool.connect();
    await blocker.query('BEGIN');
    await assert.rejects(armV1CommitFence({pool:db.pool,fence}),/v1_writer_not_drained/);
    assert.equal((await fence.snapshot()).writerFloor,undefined);
    await assert.rejects(assertV1CommitFence((sql,values)=>db.pool.query(sql,values)),/v1_writer_fence_missing/);
    await blocker.query('ROLLBACK');blocker.release(true);blocker=null;
    assert.equal((await armV1CommitFence({pool:db.pool,fence})).writerFloor,1);
    assert.equal((await fence.snapshot()).writerFloor,1);
    assert.match((await fence.snapshot()).v1BaselineID,/^[0-9a-f-]{36}$/u);
    assert.equal((await armV1CommitFence({pool:db.pool,fence})).writerFloor,1,'repeat is idempotent');
    await assertV1CommitFence((sql,values)=>db.pool.query(sql,values));
    await db.pool.query('ALTER TABLE public.personal_vaults DISABLE TRIGGER selective_remote_framed_v1_writer');
    await assert.rejects(armV1CommitFence({pool:db.pool,fence}),/v1_writer_fence_missing/,'a retained floor must never repair a restored or altered database silently');
    assert.equal((await fence.snapshot()).writerFloor,1);
  } finally { if(blocker){try{await blocker.query('ROLLBACK');}catch{}blocker.release(true);} await fixture?.cleanup();await db.cleanup(); }
});

test('arming interruption never exposes an unprotected current writer', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const { armV1CommitFence }=await import('../src/v1-commit-fence.mjs');
  const { MigrationFence }=await import('../src/migration-fence.mjs');
  const { publicationRuntimeFixture }=await import('./publication-runtime-fixture.mjs');
  for (const afterAppend of [false,true]) {
    const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture;
    try {
      fixture=await publicationRuntimeFixture(db.databaseURL);
      const fence=new MigrationFence(fixture.path);
      const failing={assertWritable:()=>fence.assertWritable(),snapshot:()=>fence.snapshot(),
        async append(event){if(event.type==='V1_BASELINE')return fence.append(event);if(afterAppend)await fence.append(event);throw Error('synthetic_interruption');}};
      await assert.rejects(armV1CommitFence({pool:db.pool,fence:failing}),/synthetic_interruption/);
      await assertV1CommitFence((sql,values)=>db.pool.query(sql,values));
      assert.match((await fence.snapshot()).v1BaselineID,/^[0-9a-f-]{36}$/u);
      assert.equal((await fence.snapshot()).writerFloor,afterAppend?1:undefined);
      assert.equal((await armV1CommitFence({pool:db.pool,fence})).writerFloor,1);
    } finally { await fixture?.cleanup();await db.cleanup(); }
  }
});

test('an older post-floor backup must not serve after newer V1 data was committed', {skip:!process.env.TEST_DATABASE_URL,timeout:60000}, async()=>{
 const {mkdtemp,rm}=await import('node:fs/promises');
 const {tmpdir}=await import('node:os');
 const {join}=await import('node:path');
 const {execFile}=await import('node:child_process');
 const {promisify}=await import('node:util');
 const {MigrationFence}=await import('../src/migration-fence.mjs');
 const {publicationRuntimeFixture}=await import('./publication-runtime-fixture.mjs');
 const {verifyDeploymentCompatibility,currentCapabilities}=await import('../src/deployment-compatibility.mjs');
 const original=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-post-floor-'));let restored,fixture;
 try{
  const user=randomUUID(),device=randomUUID();
  await original.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-postfloor@example.test','p0_postfloor',now())",[user]);
  await original.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
  await original.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
  fixture=await publicationRuntimeFixture(original.databaseURL);const fence=new MigrationFence(fixture.path);
  await installV1CommitFence(original.pool);
  const {readV1VaultState}=await import('../src/v1-data-fence.mjs');
  await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>original.pool.query(sql,values))});
  await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
  const exec=promisify(execFile),archive=join(dir,'post-floor.dump');await exec('pg_dump',['--format=custom','--no-owner','--no-acl','--file',archive,original.databaseURL]);
  const store=new PostgresStore(null,original.pool,{v1Fence:fence});
  assert.equal((await store.putVault(user,device,{baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:'synthetic'},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'})).revision,2);
  assert.equal((await fence.snapshot()).v1Committed[0].revision,2);
  assert.equal((await verifyDeploymentCompatibility({query:(sql,values)=>original.pool.query(sql,values),fence,candidate:currentCapabilities})).writerFloor,1);
  restored=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);await restored.pool.query('DROP SCHEMA public CASCADE');await restored.pool.query('CREATE SCHEMA public');
  await exec('pg_restore',['--exit-on-error','--no-owner','--no-acl','--dbname',restored.databaseURL,archive]);
  const old=(await restored.pool.query('SELECT revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows[0];
  assert.equal(Number(old.revision),1);
  const guard=()=>verifyDeploymentCompatibility({query:(sql,values)=>restored.pool.query(sql,values),fence,candidate:currentCapabilities});
  await assert.rejects(guard,/deployment_v1_data_mismatch/,'restored older V1 data must not be accepted');
  const c=await restored.pool.connect();try{await c.query('BEGIN');await useFramedV1Writer(c);await c.query("UPDATE personal_vaults SET revision=2,ciphertext='c3RhbGU' WHERE user_id=$1",[user]);await c.query('COMMIT');}finally{c.release();}
  await assert.rejects(guard,/deployment_v1_data_mismatch/,'same revision with different ciphertext must not be accepted');
 }finally{await fixture?.cleanup();await restored?.cleanup();await original.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('lost Personal COMMIT reply stays pending until exact durable readback after restart', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {MigrationFence}=await import('../src/migration-fence.mjs');
  const {readV1VaultState}=await import('../src/v1-data-fence.mjs');
  const {PublicationFenceCoordinator,readCommittedV1Outcome}=await import('../src/publication-fence-coordinator.mjs');
  const {currentCapabilities,verifyDeploymentCompatibility}=await import('../src/deployment-compatibility.mjs');
  const {publicationRuntimeFixture}=await import('./publication-runtime-fixture.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture;
  try {
    const user=randomUUID(),device=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-commit-loss@example.test','p0_commit_loss',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    fixture=await publicationRuntimeFixture(db.databaseURL);const fence=new MigrationFence(fixture.path);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    let injected=false;
    const pool={async connect(){const c=await db.pool.connect();return {
      async query(sql,values){if(sql==='COMMIT'&&!injected){injected=true;await c.query(sql,values);throw Error('synthetic_lost_commit_reply');}return c.query(sql,values);},
      release(){c.release();},
    };}};
    const store=new PostgresStore(null,pool,{v1Fence:fence});
    await assert.rejects(store.putVault(user,device,{baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:'synthetic'},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'}),/synthetic_lost_commit_reply/);
    assert.equal(Number((await db.pool.query('SELECT revision FROM personal_vaults WHERE user_id=$1',[user])).rows[0].revision),2);
    const pending=(await fence.snapshot()).v1Pending;assert.equal(pending.length,1);
    const guard=()=>verifyDeploymentCompatibility({query:(sql,values)=>db.pool.query(sql,values),fence,candidate:currentCapabilities});
    await assert.rejects(guard,/deployment_fence_pending/);
    const restarted=new PublicationFenceCoordinator({fence:new MigrationFence(fixture.path)});
    const result=await restarted.reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query:(sql,values)=>db.pool.query(sql,values),intent})});
    assert.equal(result.status,'confirmed');assert.equal((await guard()).writerFloor,1);
    assert.equal((await db.pool.query('SELECT ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows[0].ciphertext,'bmV3');
  } finally {await fixture?.cleanup();await db.cleanup();}
});

test('crash after durable V1 intent but before COMMIT stays pending and preserves the old row', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {MigrationFence}=await import('../src/migration-fence.mjs');
  const {readV1VaultState}=await import('../src/v1-data-fence.mjs');
  const {PublicationFenceCoordinator,readCommittedV1Outcome}=await import('../src/publication-fence-coordinator.mjs');
  const {currentCapabilities,verifyDeploymentCompatibility}=await import('../src/deployment-compatibility.mjs');
  const {publicationRuntimeFixture}=await import('./publication-runtime-fixture.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture;
  try {
    const user=randomUUID(),device=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-crash@example.test','p0_crash_test',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    const before=(await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows;
    fixture=await publicationRuntimeFixture(db.databaseURL);const fence=new MigrationFence(fixture.path);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const crashing={snapshot:()=>fence.snapshot(),async append(event){await fence.append(event);if(event.type==='V1_PENDING_INTENT')throw Error('synthetic_crash_after_intent');}};
    const store=new PostgresStore(null,db.pool,{v1Fence:crashing});
    await assert.rejects(store.putVault(user,device,{baseRevision:1,envelopeVersion:1,wrappedKey:{algorithm:'synthetic'},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'}),/synthetic_crash_after_intent/);
    assert.deepEqual((await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows,before);
    const pending=(await fence.snapshot()).v1Pending;assert.equal(pending.length,1);
    const guard=()=>verifyDeploymentCompatibility({query:(sql,values)=>db.pool.query(sql,values),fence,candidate:currentCapabilities});
    await assert.rejects(guard,/deployment_fence_pending/);
    const restarted=new PublicationFenceCoordinator({fence:new MigrationFence(fixture.path)});
    const result=await restarted.reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query:(sql,values)=>db.pool.query(sql,values),intent})});
    assert.equal(result.status,'pending','absence after restart is not proof of abort');
    await assert.rejects(guard,/deployment_fence_pending/);
  } finally {await fixture?.cleanup();await db.cleanup();}
});

test('concurrent current Personal writers cannot both commit the same base revision', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const {MigrationFence}=await import('../src/migration-fence.mjs');
  const {readV1VaultState,assertV1DataFloor}=await import('../src/v1-data-fence.mjs');
  const {publicationRuntimeFixture}=await import('./publication-runtime-fixture.mjs');
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture;
  try {
    const user=randomUUID(),device=randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-race@example.test','p0_race_test',now())",[user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')",[user]);
    fixture=await publicationRuntimeFixture(db.databaseURL);const fence=new MigrationFence(fixture.path);
    await installV1CommitFence(db.pool);
    await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
    await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
    const store=new PostgresStore(null,db.pool,{v1Fence:fence});
    const envelope=ciphertext=>({baseRevision:1,envelopeVersion:1,wrappedKey:{},ciphertext,nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'});
    const outcomes=await Promise.allSettled([store.putVault(user,device,envelope('Zmlyc3Q')),store.putVault(user,device,envelope('c2Vjb25k'))]);
    const successes=outcomes.filter(item=>item.status==='fulfilled'&&item.value.conflict===false);
    assert.equal(successes.length,1);
    for(const outcome of outcomes)if(outcome.status==='rejected')assert.match(outcome.reason.message,/deployment_fence_pending|deployment_fence_locked|deployment_v1_history_changed|deployment_v1_data_mismatch/);
    const row=(await db.pool.query('SELECT revision,ciphertext FROM personal_vaults WHERE user_id=$1',[user])).rows[0];
    assert.equal(Number(row.revision),2);assert.ok(['Zmlyc3Q','c2Vjb25k'].includes(row.ciphertext));
    const state=await fence.snapshot();assert.equal(state.v1Pending.length,0);
    assert.equal(await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),state),true);
  } finally {await fixture?.cleanup();await db.cleanup();}
});
