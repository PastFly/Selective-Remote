import test from 'node:test';
import assert from 'node:assert/strict';
import {withDB,requestFor,storeFor,seedPublishedVault,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {VaultPublicationStore} from '../src/vault-publication-store.mjs';
const database=process.env.TEST_DATABASE_URL;
test('commit installs exact successor group/policy, pointer, audit and durable scoped receipt atomically',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f);request.groupMutation={action:'CREATE',groupID:request.operationID,name:'Committed operators'};
  const p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);await uploadWholeFixture(s,f,p,out);
  const receipt=await s.commit(f.input,request.operationID,p.token,request);
  assert.equal(receipt.vaults[0].sequence,2);assert.equal(receipt.operationID,request.operationID);
  const current=(await pool.query('SELECT active_publication_attempt_id,access_policy_version FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0];
  assert.equal(current.active_publication_attempt_id,out.generations[0].generationID);assert.equal(Number(current.access_policy_version),2);
  assert.deepEqual(await s.receipt(f.input,request.operationID),receipt);
  assert.deepEqual(await s.commit(f.input,request.operationID,'lost/expired-token',request),receipt);
  await assert.rejects(s.commit(f.input,request.operationID,p.token,{...request,groupMutation:null}),/publication_replay_conflict/);
  const header=await new VaultPublicationStore(pool,f.config).header(f.input);assert.equal(header.header.payload.sequence,2);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_outbox WHERE operation_id=$1',[request.operationID])).rows[0].n,0);
  assert.equal((await pool.query("SELECT count(*)::int AS n FROM team_audit_events WHERE metadata->>'operationID'=$1 AND action='vault_publication_committed'",[request.operationID])).rows[0].n,1);
}));
