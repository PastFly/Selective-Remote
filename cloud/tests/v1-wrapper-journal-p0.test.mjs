import {syntheticAnchoredFence,syntheticV1Anchor} from './synthetic-v1-anchor-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {PostgresStore} from '../src/postgres-store.mjs';
import {teamVaultWrapperContextHash} from '../src/security.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {installV1CommitFence} from '../src/v1-commit-fence.mjs';
import {readV1VaultState,assertV1DataFloor} from '../src/v1-data-fence.mjs';
import {isolatedPublicationDatabase} from './publication-runtime-fixture.mjs';

function wrapper(membership,deviceID,teamID,vaultID,marker){
 return {membershipID:membership.id,membershipEpoch:Number(membership.epoch),deviceID,wrapperVersion:1,
  ephemeralPublicKey:{kty:'EC',crv:'P-256',x:marker.repeat(43),y:'Z'.repeat(43)},ciphertext:marker.repeat(43),nonce:marker.repeat(16),authTag:marker.repeat(22),
  contextHash:teamVaultWrapperContextHash({teamID,vaultID,keyGeneration:1,membershipID:membership.id,membershipEpoch:Number(membership.epoch),deviceID})};
}

test('granting a new device wrapper retains the changed Team envelope at the same revision', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-grant-'));
 try{
  const owner=randomUUID(),ownerDevice=randomUUID(),newDevice=randomUUID();
  await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'wrapper-owner@example.test','wrapper_owner',now())",[owner]);
  const publicKey=JSON.stringify({kty:'EC',crv:'P-256',x:'A'.repeat(43),y:'B'.repeat(43),ext:true,key_ops:[]});
  await db.pool.query("INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'Synthetic','web',$3,'p256-ecdh-v1',now(),now())",[ownerDevice,owner,publicKey]);
  const setup=new PostgresStore(null,db.pool,{writerFence:async()=>{}});
  const team=await setup.createTeam({actorUserID:owner,name:'TEST-ONLY-CODEX',idempotencyKey:'test-wrapper-team'});
  const vault=await setup.createSharedVault({actorUserID:owner,teamID:team.team.id,name:'TEST-ONLY-CODEX',idempotencyKey:'test-wrapper-vault'});
  await setup.putSharedVault({actorUserID:owner,actorDeviceID:ownerDevice,teamID:team.team.id,vaultID:vault.vault.id,envelope:{baseRevision:0,keyGeneration:1,envelopeVersion:1,ciphertext:'AA',nonce:'B'.repeat(16),authTag:'C'.repeat(22),contentHash:'D'.repeat(43),wrappers:[wrapper(team.membership,ownerDevice,team.team.id,vault.vault.id,'E')]},idempotencyKey:'test-wrapper-init'});
  await db.pool.query("INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'Synthetic new','web',$3,'p256-ecdh-v1',now(),now())",[newDevice,owner,publicKey]);
  const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=(await syntheticAnchoredFence(file));await installV1CommitFence(db.pool);
  await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
  await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
  const before=await fence.snapshot();const old=before.v1Committed.find(item=>item.vaultID===vault.vault.id);
  const store=new PostgresStore(null,db.pool,{v1Fence:fence});
  const request={actorUserID:owner,actorDeviceID:ownerDevice,teamID:team.team.id,vaultID:vault.vault.id,wrapper:wrapper(team.membership,newDevice,team.team.id,vault.vault.id,'F'),keyGeneration:1,idempotencyKey:'test-wrapper-grant'};
  assert.equal((await store.grantSharedVaultWrapper(request)).granted,true);
  const after=await fence.snapshot(),retained=after.v1Committed.find(item=>item.vaultID===vault.vault.id);
  assert.equal(retained.revision,old.revision);assert.notEqual(retained.envelopeHash,old.envelopeHash);assert.equal(retained.ciphertextHash,old.ciphertextHash);
  assert.equal(after.v1Pending.length,0);await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),after);
  assert.equal((await store.grantSharedVaultWrapper(request)).granted,true);
 }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('wrapper batch commits all changed envelope hashes without changing Vault revisions',async()=>{
 const {validateFenceEvent,reduceFenceEvents,fenceIntentDigest}=await import('../src/migration-fence-journal.mjs');
 const owner=randomUUID(),a=randomUUID(),b=randomUUID(),baselineID=randomUUID();
 const original=id=>({vaultKind:'TEAM',ownerID:owner,vaultID:id,revision:4,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)});
 const base={version:2,type:'V1_BASELINE',baselineID,vaults:[original(a),original(b)]};
 const change=id=>({vaultKind:'TEAM',ownerID:owner,vaultID:id,revision:4,ciphertextHash:'a'.repeat(64),beforeEnvelopeHash:'b'.repeat(64),envelopeHash:'c'.repeat(64)});
 const intent={version:2,type:'V1_WRAPPER_BATCH_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),changes:[change(b),change(a)]};
 assert.equal(validateFenceEvent(intent).changes.length,2);
 const begin=[base,{version:2,type:'V1_WRITER_FLOOR',writerProtocol:1},intent];
 assert.equal(reduceFenceEvents(begin).v1Pending.length,1);
 const overlap={...intent,intentID:randomUUID(),operationID:randomUUID(),changes:[change(a)]};
 assert.throws(()=>reduceFenceEvents([...begin,overlap]),/deployment_fence_conflict/);
 const outcome={version:2,type:'V1_CONFIRMED_COMMIT',intentID:intent.intentID,intentDigest:fenceIntentDigest(intent)};
 const final=reduceFenceEvents([...begin,outcome]);assert.equal(final.v1Pending.length,0);assert.equal(final.wrapperEnvelopeVersion,1);
 assert.deepEqual(final.v1Committed.map(item=>[item.vaultID,item.revision,item.ciphertextHash,item.envelopeHash]).sort(),[a,b].map(id=>[id,4,'a'.repeat(64),'c'.repeat(64)]).sort());
 assert.throws(()=>reduceFenceEvents([base,{version:2,type:'V1_WRITER_FLOOR',writerProtocol:1},{...intent,changes:[{...change(a),beforeEnvelopeHash:'d'.repeat(64)}]}]),/deployment_fence_conflict/);
 assert.throws(()=>validateFenceEvent({...intent,changes:[change(a),change(a)]}),/invalid_deployment_fence/);
});

test('old image cannot start after retained wrapper batch has been recorded',async()=>{
 const {fenceIntentDigest}=await import('../src/migration-fence-journal.mjs');
 const {currentCapabilities,verifyDeploymentCompatibility}=await import('../src/deployment-compatibility.mjs');
 const dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-floor-'));
 try{
  const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=(await syntheticAnchoredFence(file)),owner=randomUUID(),vault=randomUUID();
  const original={vaultKind:'TEAM',ownerID:owner,vaultID:vault,revision:3,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)};
  await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[original]});await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
  const intent={version:2,type:'V1_WRAPPER_BATCH_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),changes:[{...original,beforeEnvelopeHash:original.envelopeHash,envelopeHash:'c'.repeat(64)}]};
  await fence.append(intent);await fence.append({version:2,type:'V1_CONFIRMED_COMMIT',intentID:intent.intentID,intentDigest:fenceIntentDigest(intent)});
  const {wrapperEnvelopeVersion:_,...oldCandidate}=currentCapabilities;let queried=false;
  await assert.rejects(verifyDeploymentCompatibility({fence,candidate:oldCandidate,query:()=>{queried=true;throw Error('unexpected_query');}}),/deployment_code_floor/);assert.equal(queried,false);
  assert.equal(currentCapabilities.wrapperEnvelopeVersion,1);
 }finally{await rm(dir,{recursive:true,force:true});}
});

async function setupBatchInvitation(db,dir){
 const owner=randomUUID(),member=randomUUID(),ownerDevice=randomUUID(),memberDevice=randomUUID();
 await db.pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'batch-owner@example.test','batch_owner',now()),($2,'batch-member@example.test','batch_member',now())",[owner,member]);
 const publicKey=JSON.stringify({kty:'EC',crv:'P-256',x:'A'.repeat(43),y:'B'.repeat(43),ext:true,key_ops:[]});
 await db.pool.query("INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at) VALUES($1,$2,'Synthetic owner','web',$3,'p256-ecdh-v1',now(),now()),($4,$5,'Synthetic member','web',$3,'p256-ecdh-v1',now(),now())",[ownerDevice,owner,publicKey,memberDevice,member]);
 const store=new PostgresStore(null,db.pool,{writerFence:async()=>{}}),team=await store.createTeam({actorUserID:owner,name:'TEST-ONLY-CODEX',idempotencyKey:'test-only-batch-team'});
 await db.pool.query('UPDATE teams SET automatic_device_admission=true WHERE id=$1',[team.team.id]);
 const vaults=[];
 for(const name of ['first','second']){
  const result=await store.createSharedVault({actorUserID:owner,teamID:team.team.id,name,idempotencyKey:'test-only-batch-vault-'+name});const id=result.vault.id;vaults.push(id);
  await store.putSharedVault({actorUserID:owner,actorDeviceID:ownerDevice,teamID:team.team.id,vaultID:id,envelope:{baseRevision:0,keyGeneration:1,envelopeVersion:1,ciphertext:'AA',nonce:'B'.repeat(16),authTag:'C'.repeat(22),contentHash:'D'.repeat(43),wrappers:[wrapper(team.membership,ownerDevice,team.team.id,id,'E')]},idempotencyKey:'test-only-batch-init-'+name});
 }
 const invitation=await store.createTeamInvitation({actorUserID:owner,teamID:team.team.id,invitationType:'username',email:null,username:'batch_member',preprovisionWrappers:true,role:'viewer',tokenHash:'a'.repeat(64),expiresAt:new Date(Date.now()+60000),outboxEnvelope:null,linkSecretEnvelope:null,idempotencyKey:'test-only-batch-invite'});
 assert.equal(invitation.preprovisioning.vaults.length,2);
 const membership={id:invitation.preprovisioning.membershipID,epoch:invitation.preprovisioning.membershipEpoch};
 const wrappers=vaults.map(vaultID=>({vaultID,keyGeneration:1,wrapper:wrapper(membership,memberDevice,team.team.id,vaultID,'F')}));
 await store.preprovisionTeamInvitationWrappers({actorUserID:owner,actorDeviceID:ownerDevice,teamID:team.team.id,invitationID:invitation.invitation.id,wrappers,idempotencyKey:'test-only-batch-preprovision'});
 const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=(await syntheticAnchoredFence(file));await installV1CommitFence(db.pool);
 await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:await readV1VaultState((sql,values)=>db.pool.query(sql,values))});
 await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
 const request={actorUserID:member,actorDeviceID:memberDevice,actorEmail:'batch-member@example.test',invitationID:invitation.invitation.id,tokenHash:null,idempotencyKey:'test-only-batch-accept'};
 return {fence,file,vaults,request};
}

test('accepting a preprovisioned invitation journals all Vault wrapper changes as one atomic batch', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-batch-'));
 try{
  const {fence,vaults,request}=await setupBatchInvitation(db,dir),before=await fence.snapshot();
  const accepted=await new PostgresStore(null,db.pool,{v1Fence:fence}).acceptTeamInvitation(request);assert.equal(accepted.membership.role,'viewer');
  const after=await fence.snapshot();assert.equal(after.v1Pending.length,0);assert.equal(after.wrapperEnvelopeVersion,1);
  for(const vaultID of vaults){const old=before.v1Committed.find(item=>item.vaultID===vaultID),next=after.v1Committed.find(item=>item.vaultID===vaultID);assert.equal(next.revision,old.revision);assert.equal(next.ciphertextHash,old.ciphertextHash);assert.notEqual(next.envelopeHash,old.envelopeHash);}
  const intents=(await fence.readRecords()).filter(record=>record.type==='V1_WRAPPER_BATCH_PENDING_INTENT');assert.equal(intents.length,1);assert.equal(intents[0].changes.length,2);
  await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),after);
  const replay=await new PostgresStore(null,db.pool,{v1Fence:fence}).acceptTeamInvitation(request);assert.equal(replay.membership.id,accepted.membership.id);
 }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('lost COMMIT response for multi-Vault invitation remains pending until all wrappers read back', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-batch-lost-'));
 try{
  const {fence,request}=await setupBatchInvitation(db,dir);let injected=false;
  const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){if(sql==='COMMIT'&&!injected){injected=true;await c.query(sql,values);throw Error('synthetic_batch_lost_commit');}return c.query(sql,values);},release(){c.release();}}}};
  await assert.rejects(new PostgresStore(null,pool,{v1Fence:fence}).acceptTeamInvitation(request),/synthetic_batch_lost_commit/);
  const pending=(await fence.snapshot()).v1Pending;assert.equal(pending.length,1);assert.equal(pending[0].changes.length,2);
  await assert.rejects(assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot()),/deployment_fence_pending/);
  const {PublicationFenceCoordinator,readCommittedV1WrapperBatchOutcome}=await import('../src/publication-fence-coordinator.mjs');
  const result=await new PublicationFenceCoordinator({fence}).reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1WrapperBatchOutcome({query:(sql,values)=>db.pool.query(sql,values),intent})});assert.equal(result.status,'confirmed');
  await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),await fence.snapshot());
  const replay=await new PostgresStore(null,db.pool,{v1Fence:fence}).acceptTeamInvitation(request);assert.equal(replay.membership.role,'viewer');
 }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('crash after durable multi-Vault intent and before COMMIT stays pending without partial wrappers', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-crash-'));
 try{
  const {fence,request}=await setupBatchInvitation(db,dir),before=await readV1VaultState((sql,values)=>db.pool.query(sql,values));
  const crashing={anchor:fence.anchor,snapshot:()=>fence.snapshot(),async append(event){await fence.append(event);if(event.type==='V1_WRAPPER_BATCH_PENDING_INTENT')throw Error('synthetic_after_batch_intent');}};
  await assert.rejects(new PostgresStore(null,db.pool,{v1Fence:crashing}).acceptTeamInvitation(request),/synthetic_after_batch_intent/);
  const pending=(await fence.snapshot()).v1Pending;assert.equal(pending.length,1);assert.equal(pending[0].changes.length,2);
  assert.deepEqual(await readV1VaultState((sql,values)=>db.pool.query(sql,values)),before);
  const {PublicationFenceCoordinator,readCommittedV1WrapperBatchOutcome}=await import('../src/publication-fence-coordinator.mjs');
  const result=await new PublicationFenceCoordinator({fence}).reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1WrapperBatchOutcome({query:(sql,values)=>db.pool.query(sql,values),intent})});assert.equal(result.status,'pending');
  await assert.rejects(fence.assertWritable(),/deployment_fence_pending/);
 }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('proven pre-COMMIT rollback aborts the whole batch and preserves the previous floors', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-abort-'));
 try{
  const {fence,request}=await setupBatchInvitation(db,dir),before=await readV1VaultState((sql,values)=>db.pool.query(sql,values));let injected=false;
  const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){if(sql.includes('UPDATE team_mutation_receipts SET response')&&!injected){injected=true;throw Error('synthetic_before_batch_commit');}return c.query(sql,values);},release(){c.release();}}}};
  await assert.rejects(new PostgresStore(null,pool,{v1Fence:fence}).acceptTeamInvitation(request),/synthetic_before_batch_commit/);
  assert.deepEqual(await readV1VaultState((sql,values)=>db.pool.query(sql,values)),before);
  const state=await fence.snapshot();assert.equal(state.v1Pending.length,0);assert.equal(state.wrapperEnvelopeVersion,1);
  assert.equal(state.v1Outcomes.at(-1).type,'V1_PROVEN_ABORT');await assertV1DataFloor((sql,values)=>db.pool.query(sql,values),state);
  assert.equal((await new PostgresStore(null,db.pool,{v1Fence:fence}).acceptTeamInvitation(request)).membership.role,'viewer');
 }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});

test('mixed old and new wrappers during uncertain multi-Vault commit are rejected', {skip:!process.env.TEST_DATABASE_URL,timeout:60000},async()=>{
 const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-partial-'));
 try{
  const {fence,request,vaults}=await setupBatchInvitation(db,dir);let injected=false;
  const pool={async connect(){const c=await db.pool.connect();return {async query(sql,values){if(sql==='COMMIT'&&!injected){injected=true;await c.query(sql,values);throw Error('synthetic_batch_lost_commit');}return c.query(sql,values);},release(){c.release();}}}};
  await assert.rejects(new PostgresStore(null,pool,{v1Fence:fence}).acceptTeamInvitation(request),/synthetic_batch_lost_commit/);
  const pending=(await fence.snapshot()).v1Pending;assert.equal(pending.length,1);
  const {useFramedV1Writer}=await import('../src/v1-commit-fence.mjs');const client=await db.pool.connect();
  try{await client.query('BEGIN');await useFramedV1Writer(client);await client.query('DELETE FROM shared_vault_key_wrappers WHERE vault_id=$1 AND device_id=$2',[vaults[0],request.actorDeviceID]);await client.query('COMMIT');}finally{client.release();}
  const {PublicationFenceCoordinator,readCommittedV1WrapperBatchOutcome}=await import('../src/publication-fence-coordinator.mjs');
  await assert.rejects(new PublicationFenceCoordinator({fence}).reconcile({intentID:pending[0].intentID,readCommittedOutcome:intent=>readCommittedV1WrapperBatchOutcome({query:(sql,values)=>db.pool.query(sql,values),intent})}),/deployment_fence_mismatch/);
  assert.equal((await fence.snapshot()).v1Pending.length,1);
 }finally{await db.cleanup();await rm(dir,{recursive:true,force:true});}
});
