import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {isolatedPublicationDatabase,publicationRuntimeFixture} from './publication-runtime-fixture.mjs';
import {PostgresStore} from '../src/postgres-store.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {PublicationFenceCoordinator,readCommittedV1Outcome} from '../src/publication-fence-coordinator.mjs';
import {teamVaultWrapperContextHash} from '../src/security.mjs';
test('Team lost COMMIT preserves wrappers and exact idempotent retry', {skip: !process.env.TEST_DATABASE_URL, timeout: 60000}, async()=>{
const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);let fixture;
try{
 const user=randomUUID(),device=randomUUID(),seed=new PostgresStore(null,db.pool);
 await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'lost-team@example.test','lost_team_test',now())",[user]);
 const team=await seed.createTeam({actorUserID:user,name:'TEST-ONLY-CODEX-LOST-TEAM',idempotencyKey:'p0-lost-team-0001'});
 const pub=JSON.stringify({kty:'EC',crv:'P-256',x:'A'.repeat(43),y:'B'.repeat(43),ext:true,key_ops:[]});
 await db.pool.query("INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'test','web',$3,'p256-ecdh-v1',now(),now())",[device,user,pub]);
 const created=await seed.createSharedVault({actorUserID:user,teamID:team.team.id,name:'TEST-ONLY-CODEX-LOST-VAULT',idempotencyKey:'p0-lost-vault-0001'});
 const vaultID=created.vault.id,teamID=team.team.id,member=team.membership;
 const wrapper={membershipID:member.id,membershipEpoch:Number(member.epoch),deviceID:device,wrapperVersion:1,ephemeralPublicKey:{kty:'EC',crv:'P-256',x:'E'.repeat(43),y:'Z'.repeat(43)},ciphertext:'E'.repeat(43),nonce:'E'.repeat(16),authTag:'E'.repeat(22),contextHash:teamVaultWrapperContextHash({teamID,vaultID,keyGeneration:1,membershipID:member.id,membershipEpoch:Number(member.epoch),deviceID:device})};
 fixture=await publicationRuntimeFixture(db.databaseURL);const fence=new MigrationFence(fixture.path),query=(sql,values)=>db.pool.query(sql,values);
 await installV1CommitFence(db.pool);await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState(query)});await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
 let injected=false;
 const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){if(sql==='COMMIT'&&!injected){injected=true;await c.query(sql,values);throw Error('synthetic_lost_commit_reply');}return c.query(sql,values);},release(){c.release();}};}};
 const request={actorUserID:user,actorDeviceID:device,teamID,vaultID,envelope:{baseRevision:0,keyGeneration:1,envelopeVersion:1,ciphertext:'AA',nonce:'B'.repeat(16),authTag:'C'.repeat(22),contentHash:'D'.repeat(43),wrappers:[wrapper]},idempotencyKey:'p0-lost-team-write-0001'};
 const store=new PostgresStore(null,pool,{v1Fence:fence});await assert.rejects(store.putSharedVault(request),/synthetic_lost_commit_reply/);
 const row=(await query('SELECT revision,ciphertext FROM shared_vaults WHERE id=$1',[vaultID])).rows[0];assert.equal(Number(row.revision),1);assert.equal(row.ciphertext,'AA');assert.equal((await query('SELECT 1 FROM shared_vault_key_wrappers WHERE vault_id=$1',[vaultID])).rowCount,1);
 const pending=(await fence.snapshot()).v1Pending;assert.equal(pending.length,1);await assert.rejects(fence.assertWritable(),/deployment_fence_pending/);
 const restarted=new PublicationFenceCoordinator({fence:new MigrationFence(fixture.path)});assert.equal((await restarted.reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1Outcome({query,intent})})).status,'confirmed');
 assert.equal(await assertV1DataFloor(query,await fence.snapshot()),true);
 const replay=await new PostgresStore(null,db.pool,{v1Fence:fence}).putSharedVault(request);assert.equal(replay.revision,1);assert.equal(replay.conflict,false);
 assert.equal((await query('SELECT count(*)::int AS n FROM shared_vault_revisions WHERE vault_id=$1',[vaultID])).rows[0].n,1);
 console.log('TEAM_LOST_COMMIT=BLOCKED_UNTIL_EXACT_READBACK; WRAPPER_PRESERVED=YES; IDEMPOTENT_REPLAY=PASS');
}finally{await fixture?.cleanup();await db.cleanup();}

});
