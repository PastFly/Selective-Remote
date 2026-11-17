import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {lstat} from 'node:fs/promises';
import {MigrationFence} from '../src/migration-fence.mjs';
import {FENCE_MAX_BYTES,fenceIntentDigest} from '../src/migration-fence-journal.mjs';
import {VaultMigrationStore} from '../src/vault-migration-store.mjs';
import {capacityFixture,eventBytes} from './migration-fence-capacity-fixtures.mjs';

const legacy=()=>({teamID:randomUUID(),vaultID:randomUUID(),attemptID:randomUUID(),manifestHash:'a'.repeat(64),schemaFloor:19});
const pending=()=>({version:2,type:'PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),kind:'PUBLICATION',schemaFloor:22,
 vaults:[{teamID:randomUUID(),vaultID:randomUUID(),generationID:randomUUID(),sequence:1,headerHash:'b'.repeat(64),manifestHash:'c'.repeat(64)}]});
const terminal=(intent,type='CONFIRMED_COMMIT')=>({version:2,type,
 intentID:intent.intentID??'legacy:'+fenceIntentDigest(intent),intentDigest:fenceIntentDigest(intent)});
const append=(fence,intent)=>intent.version?fence.append(intent):fence.intent(intent);

for(const format of ['legacy','modern']){
 test(`${format} intent refuses one byte short of terminal reservation without writes or retained lock`,async t=>{
  const intent=format==='legacy'?legacy():pending();
  const f=await capacityFixture(t,{remaining:eventBytes(intent)+eventBytes(terminal(intent))-1});
  const before=await f.bytes(),state=await f.fence.snapshot();
  await assert.rejects(append(f.fence,intent),/deployment_fence_limit/);
  assert.deepEqual(await f.bytes(),before);assert.deepEqual(await f.fence.snapshot(),state);
  assert.equal(f.calls.writes,0);await assert.rejects(lstat(f.path+'.lock'),{code:'ENOENT'});
  assert.equal(await f.fence.assertWritable(),true);
 });
 test(`${format} intent admits exact terminal reservation and confirms at physical cap`,async t=>{
  const intent=format==='legacy'?legacy():pending(),done=terminal(intent);
  const f=await capacityFixture(t,{remaining:eventBytes(intent)+eventBytes(done)});
  await append(f.fence,intent);assert.equal((await f.fence.snapshot()).pending.length,1);
  await f.fence.append(done);assert.equal(await f.size(),FENCE_MAX_BYTES);
  const state=await f.fence.snapshot();assert.equal(state.pending.length,0);assert.equal(state.committed.length,1);
  const before=await f.bytes(),syncs={...f.calls};
  await f.fence.append(done);await append(f.fence,intent);
  assert.deepEqual(await f.bytes(),before);assert.equal(f.calls.writes,syncs.writes);
  assert.equal(f.calls.fileSyncs,syncs.fileSyncs+2);assert.equal(f.calls.directorySyncs,syncs.directorySyncs+2);
 });
}

for(const shortBy of [1,0])test(`new intent reserves every existing legacy and modern pending terminal (${shortBy} byte short)`,async t=>{
 const old=legacy(),a=pending(),b=pending(),oldDone=terminal(old),aDone=terminal(a),bDone=terminal(b);
 const f=await capacityFixture(t,{events:[old,a],remaining:eventBytes(b)+eventBytes(oldDone)+eventBytes(aDone)+eventBytes(bDone)-shortBy});
 const before=await f.bytes(),state=await f.fence.snapshot();
 if(shortBy){
  await assert.rejects(f.fence.append(b),/deployment_fence_limit/);
  assert.deepEqual(await f.bytes(),before);assert.deepEqual(await f.fence.snapshot(),state);
  assert.equal(f.calls.writes,0);await assert.rejects(lstat(f.path+'.lock'),{code:'ENOENT'});
 }else{
  await f.fence.append(b);assert.equal((await f.fence.snapshot()).pending.length,3);
  for(const done of [aDone,oldDone,bDone])await f.fence.append(done);
  assert.equal(await f.size(),FENCE_MAX_BYTES);
  const final=await f.fence.snapshot();assert.equal(final.pending.length,0);assert.equal(final.committed.length,3);
 }
});

test('completed history does not consume pending terminal reservation',async t=>{
 const old=legacy(),intent=pending(),done=terminal(intent);
 const f=await capacityFixture(t,{events:[old,terminal(old)],remaining:eventBytes(intent)+eventBytes(done)});
 await f.fence.append(intent);await f.fence.append(done);
 assert.equal(await f.size(),FENCE_MAX_BYTES);assert.equal((await f.fence.snapshot()).committed.length,2);
});

test('separate concurrent writers reserve all pending terminals while holding the journal lock',async t=>{
 const intents=[pending(),pending()];
 const remaining=intents.reduce((bytes,intent)=>bytes+eventBytes(intent)+eventBytes(terminal(intent)),0)-1;
 const f=await capacityFixture(t,{remaining}),other=new MigrationFence(f.path,{openFile:f.openFile});
 const results=await Promise.allSettled([f.fence.append(intents[0]),other.append(intents[1])]);
 assert.deepEqual(results.map(r=>r.status).sort(),['fulfilled','rejected']);
 assert.match(results.find(r=>r.status==='rejected').reason.message,/deployment_fence_limit/);
 const winner=intents[results.findIndex(r=>r.status==='fulfilled')],state=await f.fence.snapshot();
 assert.deepEqual(state.pending.map(p=>p.intentID),[winner.intentID]);
 assert.equal((await f.bytes()).toString(),JSON.stringify(winner)+'\n');
 await assert.rejects(lstat(f.path+'.lock'),{code:'ENOENT'});
 await f.fence.append(terminal(winner));assert.equal((await f.fence.snapshot()).pending.length,0);
});

for(const type of ['CONFIRMED_COMMIT','PROVEN_ABORT']){
 test(`reserved capacity permits ${type} and preserves exact terminal replay`,async t=>{
  const intent=pending(),done=terminal(intent,type);
  const f=await capacityFixture(t,{remaining:eventBytes(intent)+eventBytes(terminal(intent))});
  await f.fence.append(intent);await f.fence.append(done);
  const state=await f.fence.snapshot();assert.equal(state.pending.length,0);
  assert.equal(state.committed.length,type==='CONFIRMED_COMMIT'?1:0);
  assert.equal(await f.size(),FENCE_MAX_BYTES-(type==='PROVEN_ABORT'?4:0));
  const before=await f.bytes(),syncs={...f.calls};await f.fence.append(done);
  assert.deepEqual(await f.bytes(),before);assert.equal(f.calls.writes,syncs.writes);
  assert.equal(f.calls.fileSyncs,syncs.fileSyncs+1);assert.equal(f.calls.directorySyncs,syncs.directorySyncs+1);
 });
 test(`old underreserved history permits a fitting ${type} with another intent still pending`,async t=>{
  const old=legacy(),intent=pending(),done=terminal(intent,type);
  const f=await capacityFixture(t,{events:[old,intent],remaining:eventBytes(done)});
  const before=await f.bytes(),syncs={...f.calls};
  await f.fence.intent(old);await f.fence.append(intent);
  assert.deepEqual(await f.bytes(),before);assert.equal(f.calls.writes,syncs.writes);
  assert.equal(f.calls.fileSyncs,syncs.fileSyncs+2);assert.equal(f.calls.directorySyncs,syncs.directorySyncs+2);
  await f.fence.append(done);assert.equal(await f.size(),FENCE_MAX_BYTES);
  const state=await f.fence.snapshot();assert.deepEqual(state.pending.map(p=>p.intentID),[terminal(old).intentID]);
  assert.equal(state.committed.length,type==='CONFIRMED_COMMIT'?1:0);
  const finalBytes=await f.bytes();await f.fence.append(done);assert.deepEqual(await f.bytes(),finalBytes);
 });
}

test('transaction coordinator refuses capacity before any database COMMIT dispatch',async t=>{
 const intent=pending(),{version,type,intentID,...fields}=intent;
 const f=await capacityFixture(t,{remaining:eventBytes(intent)+eventBytes(terminal(intent))-1});
 const commands=[];let released=0;
 const pool={connect:async()=>({query:async sql=>{commands.push(sql);return {rows:[]};},release:()=>{released++;}})};
 const vaultID=intent.vaults[0].vaultID;
 const store=new VaultMigrationStore(pool,{environment:'staging',enabled:true,allowedVaultIDs:[vaultID],fence:f.fence});
 const before=await f.bytes(),state=await f.fence.snapshot();
 let failure;
 try{await store.transaction({vaultID,schemaVersion:2,capability:'resource_acl_v2'},
  async(_client,fenced)=>fenced.beforeCommit(fields));}catch(error){failure=error;}
 assert.equal(commands.includes('COMMIT'),false,'capacity refusal must precede COMMIT dispatch');
 assert.match(failure?.message??'',/deployment_fence_limit/);
 assert.equal(commands.length,3);assert.equal(commands[0],'BEGIN');assert.match(commands[1],/^LOCK TABLE /);
 assert.equal(commands[2],'ROLLBACK');assert.equal(released,1);
 assert.deepEqual(await f.bytes(),before);assert.deepEqual(await f.fence.snapshot(),state);
 await assert.rejects(lstat(f.path+'.lock'),{code:'ENOENT'});
});
