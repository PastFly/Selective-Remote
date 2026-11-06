import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {PublicationFenceCoordinator,createPublicationFenceTransaction} from '../src/publication-fence-coordinator.mjs';
import {MemoryPublicationFence} from './publication-fence-fixtures.mjs';

function fields(){const attemptID=randomUUID();return {operationID:attemptID,kind:'MIGRATION',schemaFloor:19,
  vaults:[{teamID:randomUUID(),vaultID:randomUUID(),attemptID,manifestHash:'a'.repeat(64)}]};}
const committed=intent=>({kind:intent.kind,operationID:intent.operationID,vaults:intent.vaults});

test('lost COMMIT reply never proves abort; exact stored outcome resolves after restart',async()=>{
  const fence=new MemoryPublicationFence(),commands=[];
  const tx=createPublicationFenceTransaction({fence,query:async sql=>{
    commands.push(sql);if(sql==='COMMIT')throw Error('lost reply');return {rows:[]};
  }});
  const intent=await tx.beforeCommit(fields());
  await assert.rejects(tx.commit(),/lost reply/);
  await tx.rollback();
  assert.equal(tx.commitDispatched,true);
  assert.equal((await fence.snapshot()).pending.length,1);
  assert.equal(fence.events.some(e=>e.type==='PROVEN_ABORT'),false);
  assert.deepEqual(commands,['COMMIT','ROLLBACK']);
  const restarted=new PublicationFenceCoordinator({fence});
  assert.deepEqual(await restarted.reconcile({intentID:intent.intentID,readCommittedOutcome:async()=>null}),{status:'pending',intentID:intent.intentID});
  assert.equal((await fence.snapshot()).pending.length,1);
  assert.equal((await restarted.reconcile({intentID:intent.intentID,readCommittedOutcome:async p=>committed(p)})).status,'confirmed');
  assert.equal((await fence.snapshot()).pending.length,0);
});

test('only an acknowledged rollback before COMMIT can append abort',async()=>{
  const fence=new MemoryPublicationFence(),tx=createPublicationFenceTransaction({fence,query:async()=>({rows:[]})});
  const intent=await tx.beforeCommit(fields());
  await tx.rollback();
  const state=await fence.snapshot();
  assert.equal(state.pending.length,0);assert.equal(state.committed.length,0);
  assert.equal(fence.events.at(-1).type,'PROVEN_ABORT');
  assert.equal(fence.events.at(-1).intentID,intent.intentID);
});

test('failed ROLLBACK retains pending, and operator JSON cannot mint an abort proof',async()=>{
  const fence=new MemoryPublicationFence(),tx=createPublicationFenceTransaction({fence,query:async()=>{throw Error('rollback lost');}});
  const intent=await tx.beforeCommit(fields());
  await assert.rejects(tx.rollback(),/rollback lost/);
  const restarted=new PublicationFenceCoordinator({fence});
  for(const proof of [null,{},true,{rollbackAcknowledged:true,commitDispatched:false}])
    await assert.rejects(restarted.proveAbort({intentID:intent.intentID,proof}),/invalid_deployment_abort_proof/);
  const newTransaction=createPublicationFenceTransaction({fence,query:async()=>({rows:[]})});
  await newTransaction.rollback();
  assert.equal((await fence.snapshot()).pending.length,1);
});

test('partial or changed outcome cannot confirm a complete publication intent',async()=>{
  const fence=new MemoryPublicationFence(),coordinator=new PublicationFenceCoordinator({fence});
  const base=fields(),teamID=base.vaults[0].teamID;
  const intent=await coordinator.beforeCommit({...base,kind:'PUBLICATION',schemaFloor:22,vaults:[0,1].map(()=>({teamID,vaultID:randomUUID(),generationID:randomUUID(),sequence:2,headerHash:'b'.repeat(64),manifestHash:'c'.repeat(64)}))});
  for(const vaults of [intent.vaults.slice(0,1),[...intent.vaults,intent.vaults[0]],intent.vaults.map((v,i)=>i?{...v,headerHash:'d'.repeat(64)}:v)])
    await assert.rejects(coordinator.confirmCommit({intentID:intent.intentID,readCommittedOutcome:async()=>({...committed(intent),vaults})}),/deployment_fence_mismatch/);
  assert.equal((await fence.snapshot()).pending.length,1);
});

test('failed terminal durability remains pending and an exact confirmation retry is possible',async()=>{
  const fence=new MemoryPublicationFence(),coordinator=new PublicationFenceCoordinator({fence});
  const intent=await coordinator.beforeCommit(fields());
  const append=fence.append.bind(fence);let fail=true;
  fence.append=async event=>{if(fail&&event.type==='CONFIRMED_COMMIT')throw Error('fsync');return append(event);};
  const reader=async p=>committed(p);
  await assert.rejects(coordinator.confirmCommit({intentID:intent.intentID,readCommittedOutcome:reader}),/fsync/);
  assert.equal((await fence.snapshot()).pending.length,1);
  fail=false;
  await coordinator.confirmCommit({intentID:intent.intentID,readCommittedOutcome:reader});
  assert.equal((await fence.snapshot()).pending.length,0);
});

test('each rolled-back retry receives its own intent without changing operation identity',async()=>{
  const fence=new MemoryPublicationFence(),input=fields(),intents=[];
  for(let n=0;n<2;n++){
    const tx=createPublicationFenceTransaction({fence,query:async()=>({rows:[]})});
    intents.push(await tx.beforeCommit(input));await tx.rollback();
  }
  assert.notEqual(intents[0].intentID,intents[1].intentID);
  assert.equal(intents[0].operationID,intents[1].operationID);
  assert.equal((await fence.snapshot()).pending.length,0);
});
