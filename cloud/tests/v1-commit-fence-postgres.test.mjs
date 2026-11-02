import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import test from 'node:test';
import { PostgresStore } from '../src/postgres-store.mjs';
import { isolatedPublicationDatabase } from './publication-runtime-fixture.mjs';
import { installV1CommitFence, useFramedV1Writer } from '../src/v1-commit-fence.mjs';

test('database writer barrier drains in-flight legacy writes and rejects later legacy commits', {
  skip: !process.env.TEST_DATABASE_URL, timeout: 60000,
}, async () => {
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let old, writer, late;
  try {
    const user = randomUUID(), team = randomUUID(), vault = randomUUID(), device = randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'p0-fence@example.test','p0_fence_test',now())", [user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','web')",[device,user]);
    await db.pool.query("INSERT INTO personal_vaults(user_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash) VALUES ($1,1,1,'{}','c2VlZA','bm9uY2U','dGFn','aGFzaA')", [user]);
    await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES ($1,'TEST-ONLY-CODEX-FENCE',$2)", [team,user]);
    await db.pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash) VALUES ($1,$2,'TEST-ONLY-CODEX-FENCE',$3,1,1,'c2VlZA','bm9uY2U','dGFn','aGFzaA')", [vault,team,user]);
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
    await assert.rejects(late.query('UPDATE personal_vaults SET revision=4 WHERE user_id=$1',[user]), /v1_writer_upgrade_required/, 'transaction begun before installation must not write after it');
    await late.query('ROLLBACK');
    const before = (await db.pool.query('SELECT id,revision,ciphertext FROM personal_vaults WHERE user_id=$1', [user])).rows;
    const beforeTeam = (await db.pool.query('SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1',[vault])).rows;
    const hash = value => createHash('sha256').update(value).digest('hex');
    await assert.rejects(old.query("UPDATE personal_vaults SET revision=4,ciphertext='bmV3' WHERE user_id=$1", [user]), /v1_writer_upgrade_required/);
    await assert.rejects(old.query('UPDATE shared_vaults SET revision=2 WHERE id=$1', [vault]), /v1_writer_upgrade_required/);
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
    const result = await store.putVault(user,device,{baseRevision:4,envelopeVersion:1,wrappedKey:{},ciphertext:'bmV3',nonce:'bm9uY2U',authTag:'dGFn',contentHash:'aGFzaA'});
    assert.deepEqual(result,{conflict:false,revision:5}, 'real current store must set the transaction-local capability');
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
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
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
    await installV1CommitFence(db.pool);
    const result=await store.putSharedVault({actorUserID:user,actorDeviceID:device,teamID:team.team.id,vaultID:created.vault.id,
      envelope:{baseRevision:0,keyGeneration:1,envelopeVersion:1,ciphertext:'AA',nonce:'B'.repeat(16),authTag:'C'.repeat(22),contentHash:'D'.repeat(43),wrappers:[wrapper]},
      idempotencyKey:'p0-vault-initialize-0001'});
    assert.equal(result.revision,1);
    const row=(await db.pool.query('SELECT id,revision,ciphertext FROM shared_vaults WHERE id=$1',[created.vault.id])).rows[0];
    assert.deepEqual([row.id,Number(row.revision),row.ciphertext],[created.vault.id,1,'AA']);
  } finally { await db.cleanup(); }
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
