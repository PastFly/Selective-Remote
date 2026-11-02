import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp,writeFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { MigrationFence } from '../src/migration-fence.mjs';
import { PublicationFenceCoordinator, createPublicationFenceTransaction } from '../src/publication-fence-coordinator.mjs';

async function fixture(){
 const dir=await mkdtemp(join(tmpdir(),'sr-v1-coordinator-')),path=join(dir,'journal');await writeFile(path,'',{mode:0o600});
 const fence=new MigrationFence(path);await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]});
 await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
 return {fence,cleanup:()=>rm(dir,{recursive:true,force:true})};
}
const fields=()=>({kind:'V1',operationID:randomUUID(),vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),baseRevision:0,revision:1,ciphertextHash:'a'.repeat(64),envelopeHash:'d'.repeat(64)});
const outcome=intent=>({kind:'V1',operationID:intent.operationID,vaultKind:intent.vaultKind,ownerID:intent.ownerID,
 vaultID:intent.vaultID,baseRevision:intent.baseRevision,revision:intent.revision,ciphertextHash:intent.ciphertextHash,envelopeHash:intent.envelopeHash});

test('V1 confirmation requires exact committed evidence and survives retry',async()=>{
 const f=await fixture();try{
  const coordinator=new PublicationFenceCoordinator({fence:f.fence});
  const first=await coordinator.beforeCommit(fields());
  assert.equal((await f.fence.snapshot()).v1Pending.length,1);
  await assert.rejects(coordinator.confirmCommit({intentID:first.intentID,readCommittedOutcome:async()=>({...outcome(first),ciphertextHash:'b'.repeat(64)})}),/deployment_fence_mismatch/);
  assert.equal((await f.fence.snapshot()).v1Pending.length,1);
  const restarted=new PublicationFenceCoordinator({fence:f.fence});
  assert.equal((await restarted.confirmCommit({intentID:first.intentID,readCommittedOutcome:async()=>outcome(first)})).status,'confirmed');
  assert.equal((await f.fence.snapshot()).v1Committed[0].ciphertextHash,first.ciphertextHash);
  assert.equal((await restarted.reconcile({intentID:first.intentID,readCommittedOutcome:async()=>outcome(first)})).status,'confirmed');
 }finally{await f.cleanup();}
});

test('V1 lost COMMIT reply remains pending; rollback cannot claim proven abort',async()=>{
 const f=await fixture();try{
  const tx=createPublicationFenceTransaction({fence:f.fence,query:async sql=>{if(sql==='COMMIT')throw Error('synthetic_lost_reply');}});
  await tx.beforeCommit(fields());
  await assert.rejects(tx.commit(),/synthetic_lost_reply/);
  await tx.rollback();
  assert.equal((await f.fence.snapshot()).v1Pending.length,1);
  await assert.rejects(f.fence.assertWritable(),/deployment_fence_pending/);
 }finally{await f.cleanup();}
});

test('V1 rollback acknowledged before COMMIT is a proven abort',async()=>{
 const f=await fixture();try{
  const tx=createPublicationFenceTransaction({fence:f.fence,query:async()=>{}});
  await tx.beforeCommit(fields());await tx.rollback();
  const state=await f.fence.snapshot();assert.equal(state.v1Pending.length,0);assert.equal(state.v1Committed.length,0);
  assert.equal(state.v1Outcomes[0].type,'V1_PROVEN_ABORT');
 }finally{await f.cleanup();}
});

test('V1 committed readback binds owner, Vault, revision and actual ciphertext',async()=>{
 const {readCommittedV1Outcome}=await import('../src/publication-fence-coordinator.mjs');
 const {v1CiphertextHash,v1EnvelopeHash}=await import('../src/v1-data-fence.mjs');
 const envelope={envelopeVersion:1,wrappedKey:{},ciphertext:'bmV3',nonce:'nonce',authTag:'tag',contentHash:'hash',keyGeneration:null,wrappers:null};
 const v={...fields(),ciphertextHash:v1CiphertextHash('bmV3'),envelopeHash:v1EnvelopeHash(envelope)};
 const row={vault_id:v.vaultID,owner_id:v.ownerID,revision:String(v.revision),current_revision:String(v.revision),ciphertext:'bmV3',current_ciphertext:'bmV3',envelope,current_envelope:envelope};
 const query=rows=>async()=>({rows});
 assert.deepEqual(await readCommittedV1Outcome({query:query([row]),intent:v}),v);
 assert.equal(await readCommittedV1Outcome({query:query([]),intent:v}),null);
 for(const bad of [{...row,ciphertext:'c3RhbGU'},{...row,current_ciphertext:'c3RhbGU'},{...row,owner_id:randomUUID()},
   {...row,current_revision:'0'},{...row,revision:'2'},{...row,envelope:{...envelope,authTag:'altered'}},{...row,current_envelope:{...envelope,wrappedKey:{altered:true}}}])
  await assert.rejects(readCommittedV1Outcome({query:query([bad]),intent:v}),/deployment_fence_mismatch/);
});
