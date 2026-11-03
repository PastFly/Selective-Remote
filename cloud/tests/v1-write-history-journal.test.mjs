import {syntheticAnchoredFence} from './synthetic-v1-anchor-fixture.mjs';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp,writeFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { MigrationFence } from '../src/migration-fence.mjs';
import { fenceIntentDigest,reduceFenceEvents } from '../src/migration-fence-journal.mjs';

const intent=(extra={})=>({version:2,type:'V1_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),
  vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),baseRevision:0,revision:1,ciphertextHash:'a'.repeat(64),envelopeHash:'d'.repeat(64),...extra});
const floor={version:2,type:'V1_WRITER_FLOOR',writerProtocol:1};
const baseline={version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]};
const terminal=(p,type='V1_CONFIRMED_COMMIT')=>({version:2,type,intentID:p.intentID,intentDigest:fenceIntentDigest(p)});

test('V1 journal retains exact monotonic Vault revision and ciphertext commitment',()=>{
  const first=intent(), digest=fenceIntentDigest(first), second=intent({...first,intentID:randomUUID(),operationID:randomUUID(),baseRevision:1,revision:2,ciphertextHash:'b'.repeat(64)});
  assert.match(digest,/^[a-f0-9]{64}$/u);
  assert.throws(()=>reduceFenceEvents([first]),/deployment_fence_conflict/,'an intent without the retained writer floor must fail closed');
  const pending=reduceFenceEvents([baseline,floor,first]);
  assert.equal(pending.v1Pending.length,1);
  assert.equal(pending.v1Committed.length,0);
  const confirmed=reduceFenceEvents([baseline,floor,first,terminal(first)]);
  assert.equal(confirmed.v1Pending.length,0);
  assert.deepEqual(confirmed.v1Committed,[{vaultKind:first.vaultKind,ownerID:first.ownerID,vaultID:first.vaultID,revision:1,ciphertextHash:first.ciphertextHash,envelopeHash:first.envelopeHash}]);
  assert.deepEqual(reduceFenceEvents([baseline,floor,first,terminal(first),terminal(first)]).v1Committed,confirmed.v1Committed);
  assert.equal(reduceFenceEvents([baseline,floor,first,terminal(first),second,terminal(second)]).v1Committed[0].revision,2);
  for(const bad of [
    intent({...second,revision:1,baseRevision:0}),
    intent({...second,baseRevision:1,revision:2,ciphertextHash:'c'.repeat(64)}),
    intent({...second,baseRevision:0,revision:1,ciphertextHash:'b'.repeat(64)}),
    intent({...second,ownerID:randomUUID()}),
  ]) assert.throws(()=>reduceFenceEvents([baseline,floor,first,terminal(first),second,terminal(second),bad]),/deployment_fence_conflict/);
  assert.throws(()=>reduceFenceEvents([baseline,floor,first,intent({...first,intentID:randomUUID(),operationID:randomUUID()})]),/deployment_fence_conflict/);
  assert.throws(()=>reduceFenceEvents([baseline,floor,first,{...terminal(first),intentDigest:'c'.repeat(64)}]),/deployment_fence_conflict/);
  assert.throws(()=>reduceFenceEvents([baseline,floor,first,terminal(first),intent({...second,intentID:randomUUID(),operationID:first.operationID})]),/deployment_fence_conflict/,'operation IDs cannot be reused for another intent');
});

test('unresolved V1 intent remains durable and blocks writer readiness',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'sr-v1-intent-'));const path=join(dir,'journal');
  try {
    await writeFile(path,'',{mode:0o600});const fence=(await syntheticAnchoredFence(path)),first=intent();
    await fence.append(baseline);
    await fence.append(floor);
    await fence.append(first);
    assert.equal((await (await syntheticAnchoredFence(path)).snapshot()).v1Pending.length,1);
    await assert.rejects(fence.assertWritable(),/deployment_fence_pending/);
    await fence.append(terminal(first,'V1_PROVEN_ABORT'));
    assert.equal((await fence.snapshot()).v1Pending.length,0);
    assert.equal((await fence.snapshot()).v1Committed.length,0);
  } finally {await rm(dir,{recursive:true,force:true});}
});

test('V1 baseline binds pre-existing Vault identities and commitments before writes',()=>{
  const item={vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),revision:8,ciphertextHash:'b'.repeat(64),envelopeHash:'d'.repeat(64)};
  const baseline={version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[item]};
  const next=intent({...item,intentID:randomUUID(),operationID:randomUUID(),baseRevision:8,revision:9,ciphertextHash:'c'.repeat(64)});
  const state=reduceFenceEvents([baseline,floor]);
  assert.equal(state.v1BaselineID,baseline.baselineID);
  assert.deepEqual(state.v1Committed,[item]);
  assert.equal(reduceFenceEvents([baseline,floor,next,terminal(next)]).v1Committed[0].revision,9);
  assert.throws(()=>reduceFenceEvents([baseline,floor,{...baseline,baselineID:randomUUID()}]),/deployment_fence_conflict/);
  assert.throws(()=>reduceFenceEvents([floor,{...baseline,vaults:[item,item]}]),/invalid_deployment_fence/);
  assert.throws(()=>reduceFenceEvents([baseline,floor,intent({...next,baseRevision:0,revision:1})]),/deployment_fence_conflict/);
});

test('V1 and V2 publication intents cannot cross an unresolved commit',()=>{
  const first=intent(), teamID=randomUUID();
  const v2={version:2,type:'PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),kind:'PUBLICATION',schemaFloor:22,
    vaults:[{teamID,vaultID:randomUUID(),generationID:randomUUID(),sequence:1,headerHash:'b'.repeat(64),manifestHash:'c'.repeat(64)}]};
  assert.throws(()=>reduceFenceEvents([baseline,floor,first,v2]),/deployment_fence_conflict/);
  assert.throws(()=>reduceFenceEvents([baseline,floor,v2,first]),/deployment_fence_conflict/);
  assert.throws(()=>reduceFenceEvents([v2,floor]),/deployment_fence_conflict/);
});

test('a prepared V1 baseline can be retained before the writer floor',()=>{
 const initial={version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]};
 const state=reduceFenceEvents([initial]);assert.equal(state.v1BaselineID,initial.baselineID);
 assert.equal(reduceFenceEvents([initial,floor]).writerFloor,1);
 assert.throws(()=>reduceFenceEvents([initial,intent()]),/deployment_fence_conflict/);
});
