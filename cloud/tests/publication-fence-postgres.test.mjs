import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,readFile,rm,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import pg from 'pg';
import {applyMigrations} from '../src/migrations.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {PublicationFenceCoordinator,readCommittedPublicationOutcome} from '../src/publication-fence-coordinator.mjs';
import {VaultMigrationStore} from '../src/vault-migration-store.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
import {legacy,record} from './vault-v2-migration-fixtures.mjs';
import {prepareLegacyMigration} from '../public/vault-v2-migration.js';
import {seedPublishedTeam,storeFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';

const database=process.env.TEST_DATABASE_URL;
async function withIsolatedDatabase(work){
  const target=new URL(database);
  assert.ok(['127.0.0.1','localhost','[::1]'].includes(target.hostname));
  const admin=new pg.Pool({connectionString:database,max:1});
  const name=`prc_task3_${randomUUID().replaceAll('-','')}`;
  let pool,created=false;
  const directory=await mkdtemp(join(tmpdir(),'publication-fence-pg-'));
  try{
    assert.match((await admin.query('SHOW server_version')).rows[0].server_version,/^16\./);
    await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created=true;
    target.pathname=`/${name}`;
    pool=new pg.Pool({connectionString:target.href,max:5});
    await applyMigrations(pool,fileURLToPath(new URL('../migrations/',import.meta.url)),{info(){}});
    const path=join(directory,'fence');await writeFile(path,'',{mode:0o600});
    await work({pool,path,fence:new MigrationFence(path)});
  }finally{
    try{await pool?.end();if(created)await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`);}
    finally{await admin.end();await rm(directory,{recursive:true,force:true});}
  }
}
async function readyMigration(pool,fence,extra={}){
  const f=await seedMigration(pool),store=new VaultMigrationStore(pool,{...f.config,fence,...extra});
  const document=legacy([record('credential',{title:'synthetic fence',secret:'synthetic-only'})]);
  const resources=document.records.map((r,n)=>({id:r.id,kind:'CREDENTIAL',parentFolderID:null,sourceOrdinal:n}));
  const started=await store.start({...f.input,resources});
  const out=await prepareLegacyMigration({...f,scope:started.scope,document,policy:started.policy,
    recipientTargets:(r,p)=>started.recipients[r.id][p],persistCheckpoint:async()=>{}});
  for(const object of out.objects)await store.putPart(f.input,object,out.checkpoint);
  await store.validate(f.input,out.manifest);
  return {...f,store,out,manifestHash:await store.manifestHash(f.input)};
}

test('real migration activation retains a pending intent before cutover and confirms its immutable outcome',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    let sawPending=false;
    const f=await readyMigration(pool,fence,{faultAt:async point=>{
      if(point==='pre_activation'){
        const rows=(await readFile(path,'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
        sawPending=rows.some(e=>e.type==='PENDING_INTENT'&&e.kind==='MIGRATION');
      }
    }});
    await f.store.activate(f.input,f.manifestHash);
    assert.equal(sawPending,true,'cutover must observe the durable pending event');
    const state=await fence.snapshot();
    assert.equal(state.pending.length,0);assert.equal(state.committed.length,1);
    assert.equal(state.committed[0].manifestHash,f.manifestHash);
  }));

test('real two-Vault publication commits one complete pending set and confirms both generations',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    // Both initial activations and the complete successor use this real file.
    const {f,request}=await seedPublishedTeam(pool,2,{fence});
    let sawPending=false;
    const store=storeFor(pool,f,{fence,faultAt:async point=>{
      if(point==='policy_installed'){
        const rows=(await readFile(path,'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
        sawPending=rows.some(e=>e.type==='PENDING_INTENT'&&e.kind==='PUBLICATION'&&e.vaults.length===2);
      }
    }});
    const preview=await store.preview(f.input,request),out=await prepareWholeFixture(f,preview);
    await uploadWholeFixture(store,f,preview,out);
    const receipt=await store.commit(f.input,request.operationID,preview.token,request);
    assert.equal(sawPending,true,'policy installation must observe one complete durable pending set');
    const state=await fence.snapshot();
    assert.equal(state.pending.length,0);assert.equal(state.committed.length,2);
    assert.deepEqual(state.committed.map(v=>v.generationID).sort(),receipt.vaults.map(v=>v.generationID).sort());
  }));

async function preparedWhole(pool,fence,extra={}){
  const {f,request}=await seedPublishedTeam(pool,2,{fence}),store=storeFor(pool,f,{fence,...extra});
  request.groupMutation={action:'CREATE',groupID:randomUUID(),name:'Synthetic fence operators'};
  const preview=await store.preview(f.input,request),out=await prepareWholeFixture(f,preview);
  await uploadWholeFixture(store,f,preview,out);return {f,request,store,preview,out};
}
async function pointers(pool,f){
  return (await pool.query('SELECT id,active_publication_attempt_id,access_policy_version FROM shared_vaults WHERE team_id=$1 ORDER BY id',[f.input.teamID])).rows;
}
async function reconcile(pool,fence,pending,coordinator=new PublicationFenceCoordinator({fence})){
  return coordinator.reconcile({intentID:pending.intentID,readCommittedOutcome:intent=>readCommittedPublicationOutcome({query:(text,values)=>pool.query(text,values),intent})});
}

test('all pre-COMMIT publication fault stages roll back the entire set and prove abort without discarding prior minima',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,fence})=>{
    const {f,request,store,preview}=await preparedWhole(pool,fence);
    const previous=await pointers(pool,f),history=(await fence.snapshot()).committed;
    for(const stage of ['commit_precondition','policy_installed','successor_validated','pointer_swapped','pointer_swapped:2','operation_committed','outbox_inserted','audit_inserted','receipt_inserted','before_commit']){
      const previousOutcomes=new Set((await fence.snapshot()).outcomes.map(e=>e.intentID));
      const [faultPoint,occurrence='1']=stage.split(':');let count=0;
      store.faultAt=async point=>{if(point===faultPoint&&++count===Number(occurrence))throw Error('synthetic_'+stage);};
      await assert.rejects(store.commit(f.input,request.operationID,preview.token,request),new RegExp('synthetic_'+stage));
      assert.deepEqual(await pointers(pool,f),previous);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_receipts WHERE operation_id=$1',[request.operationID])).rows[0].n,0);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_outbox WHERE operation_id=$1',[request.operationID])).rows[0].n,0);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_access_groups WHERE id=$1',[request.groupMutation.groupID])).rows[0].n,0);
      const state=await fence.snapshot();assert.equal(state.pending.length,0);assert.deepEqual(state.committed,history);
      if(stage!=='commit_precondition')assert.deepEqual(state.outcomes.filter(e=>!previousOutcomes.has(e.intentID)).map(e=>e.type),['PROVEN_ABORT']);
    }
    store.faultAt=async()=>{};
    await store.commit(f.input,request.operationID,preview.token,request);
    assert.equal((await fence.snapshot()).committed.every(v=>v.sequence===2),true);
  }));

test('migration cutover faults and a pre-intent guard rejection preserve the original Vault',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,fence})=>{
    const f=await readyMigration(pool,fence),before=(await pool.query('SELECT format_state,active_publication_attempt_id,ciphertext FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0];
    f.store.activationGuard=async()=>{throw Error('operator_guard');};
    await assert.rejects(f.store.activate(f.input,f.manifestHash),/operator_guard/);
    assert.equal((await fence.snapshot()).outcomes.length,0);
    f.store.activationGuard=async()=>{};
    for(const stage of ['pre_activation','active_attempt','active_pointer','shared_vault_key_wrappers','shared_vault_revisions','team_invitation_vault_wrappers','activation_audit','before_commit']){
      f.store.faultAt=async point=>{if(point===stage)throw Error('synthetic_'+stage);};
      await assert.rejects(f.store.activate(f.input,f.manifestHash),new RegExp('synthetic_'+stage));
      assert.deepEqual((await pool.query('SELECT format_state,active_publication_attempt_id,ciphertext FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0],before);
      const state=await fence.snapshot();assert.equal(state.pending.length,0);assert.equal(state.committed.length,0);
      assert.equal(state.outcomes.at(-1).type,'PROVEN_ABORT');
    }
  }));

function lostCommitPool(pool){
  return {async connect(){const client=await pool.connect();return {
    release:()=>client.release(),
    async query(text,values){const result=await client.query(text,values);if(text==='COMMIT')throw Object.assign(Error('lost_commit_reply'),{code:'40001'});return result;},
  };}};
}
for(const kind of ['migration','publication'])test(`real ${kind} COMMIT reply loss never retries or proves abort and recovers exact immutable rows`,
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    let store,operation;
    if(kind==='migration'){
      const f=await readyMigration(pool,fence);
      store=new VaultMigrationStore(lostCommitPool(pool),{...f.config,fence});
      operation=()=>store.activate(f.input,f.manifestHash);
    }else{
      const prepared=await preparedWhole(pool,fence),{f,request,preview}=prepared;
      store=prepared.store;store.pool=lostCommitPool(pool);operation=()=>store.commit(f.input,request.operationID,preview.token,request);
    }
    await assert.rejects(operation(),/lost_commit_reply/);
    const after=await fence.snapshot();assert.equal(after.pending.length,1);
    assert.equal(after.outcomes.some(e=>e.intentID===after.pending[0].intentID),false);
    const restarted=new MigrationFence(path);
    assert.equal((await reconcile(pool,restarted,after.pending[0])).status,'confirmed');
    const resolved=await restarted.snapshot();assert.equal(resolved.pending.length,0);
    assert.equal(resolved.committed.length,kind==='migration'?1:2);
  }));

test('SQL deadlock before COMMIT retries with distinct intents; confirmed complete set remains atomic',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    const {f,request,store,preview}=await preparedWhole(pool,fence);let failures=0;
    store.faultAt=async point=>{if(point==='policy_installed'&&failures++===0)throw Object.assign(Error('synthetic_deadlock'),{code:'40P01'});};
    await store.commit(f.input,request.operationID,preview.token,request);
    const events=(await readFile(path,'utf8')).trim().split('\n').map(JSON.parse);
    const attempts=events.filter(e=>e.type==='PENDING_INTENT'&&e.operationID===request.operationID);
    assert.equal(attempts.length,2);assert.notEqual(attempts[0].intentID,attempts[1].intentID);
    assert.equal(events.find(e=>e.intentID===attempts[0].intentID&&e.type==='PROVEN_ABORT')?.type,'PROVEN_ABORT');
    assert.equal(events.find(e=>e.intentID===attempts[1].intentID&&e.type==='CONFIRMED_COMMIT')?.type,'CONFIRMED_COMMIT');
  }));

test('a real confirmation fsync failure blocks the gate until exact same-instance readback replay succeeds',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    const prepared=await preparedWhole(pool,fence);let inject=true;
    const guarded=new MigrationFence(path,{openFile:async(...args)=>{
      const handle=await open(...args);
      return new Proxy(handle,{get(target,key){
        if(key==='sync'&&args[0]===path)return async()=>{
          const events=(await readFile(path,'utf8')).trim().split('\n').map(JSON.parse);
          if(inject&&events.at(-1)?.type==='CONFIRMED_COMMIT'&&events.some(e=>e.operationID===prepared.request.operationID)){inject=false;throw Error('terminal_fsync');}
          return target.sync();
        };
        const value=target[key];return typeof value==='function'?value.bind(target):value;
      }});
    }});
    const store=prepared.store;store.fence=guarded;store.fenceCoordinator=new PublicationFenceCoordinator({fence:guarded});
    await assert.rejects(store.commit(prepared.f.input,prepared.request.operationID,prepared.preview.token,prepared.request),/terminal_fsync/);
    await assert.rejects(guarded.snapshot(),/deployment_fence_locked/);
    const pending=(await readFile(path,'utf8')).trim().split('\n').map(JSON.parse).find(e=>e.type==='PENDING_INTENT'&&e.operationID===prepared.request.operationID);
    assert.equal((await reconcile(pool,guarded,pending,store.fenceCoordinator)).status,'confirmed');
    assert.equal((await guarded.snapshot()).pending.length,0);
  }));

test('immutable readback rejects changed receipt, partial generation set, manifest and header while retaining pending',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,fence})=>{
    const {f,request,store,preview}=await preparedWhole(pool,fence);
    store.faultAt=async point=>{if(point==='after_commit')throw Error('after_commit');};
    await assert.rejects(store.commit(f.input,request.operationID,preview.token,request),/after_commit/);
    const pending=(await fence.snapshot()).pending[0];
    for(const mutation of ['receipt','generations','manifest','header']){
      const query=async(text,values)=>{
        const result=await pool.query(text,values),rows=structuredClone(result.rows);
        if(mutation==='receipt'&&text.includes('FROM team_publication_receipts'))rows[0].body.vaults.pop();
        if(mutation==='generations'&&text.includes('FROM team_publication_generations'))rows.pop();
        if(mutation==='manifest'&&text.includes('FROM vault_migration_attempts'))rows[0].manifest.signature='A'.repeat(86);
        if(mutation==='header'&&text.includes('FROM vault_publication_projections'))rows[0].projection.header.payload.sequence++;
        return {...result,rows};
      };
      await assert.rejects(store.fenceCoordinator.reconcile({intentID:pending.intentID,
        readCommittedOutcome:intent=>readCommittedPublicationOutcome({query,intent})}));
      assert.equal((await fence.snapshot()).pending.length,1);
    }
    assert.equal((await reconcile(pool,fence,pending,store.fenceCoordinator)).status,'confirmed');
  }));

test('an older database without the committed receipt is unresolved, never an abort proof',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,fence})=>{
    const {f,request,store,preview}=await preparedWhole(pool,fence);
    store.faultAt=async point=>{if(point==='after_commit')throw Error('after_commit');};
    await assert.rejects(store.commit(f.input,request.operationID,preview.token,request),/after_commit/);
    const pending=(await fence.snapshot()).pending[0],coordinator=new PublicationFenceCoordinator({fence});
    // Positive rows come from the actual committed transaction; only receipt
    // absence is injected to model a restored prior DB, without restoring it.
    const result=await coordinator.reconcile({intentID:pending.intentID,readCommittedOutcome:intent=>readCommittedPublicationOutcome({
      query:(text,values)=>text.includes('FROM team_publication_receipts')?Promise.resolve({rows:[]}):pool.query(text,values),intent})});
    assert.equal(result.status,'pending');assert.equal((await fence.snapshot()).pending.length,1);
    assert.equal((await fence.snapshot()).outcomes.some(e=>e.intentID===pending.intentID),false);
  }));

test('serialization retry exhaustion is bounded to four separately proven aborted publication attempts',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    const {f,request,store,preview}=await preparedWhole(pool,fence),previous=await pointers(pool,f);let attempts=0;
    store.faultAt=async point=>{if(point==='policy_installed'){attempts++;throw Object.assign(Error('serialization_failure'),{code:'40001'});}};
    await assert.rejects(store.commit(f.input,request.operationID,preview.token,request),/serialization_failure/);
    assert.equal(attempts,4);assert.deepEqual(await pointers(pool,f),previous);
    const state=await fence.snapshot();assert.equal(state.pending.length,0);assert.equal(state.committed.every(v=>v.sequence===1),true);
    const events=(await readFile(path,'utf8')).trim().split('\n').map(JSON.parse).filter(e=>e.type==='PENDING_INTENT'&&e.operationID===request.operationID);
    assert.equal(new Set(events.map(e=>e.intentID)).size,4);
    for(const event of events)assert.equal(state.outcomes.find(e=>e.intentID===event.intentID).type,'PROVEN_ABORT');
  }));

test('migration retries a proven pre-COMMIT deadlock with a new intent for the same attempt',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,path,fence})=>{
    let failures=0;
    const f=await readyMigration(pool,fence,{faultAt:async point=>{if(point==='pre_activation'&&failures++===0)throw Object.assign(Error('deadlock'),{code:'40P01'});}});
    await f.store.activate(f.input,f.manifestHash);
    const pendingEvents=(await readFile(path,'utf8')).trim().split('\n').map(JSON.parse).filter(e=>e.type==='PENDING_INTENT');
    assert.equal(pendingEvents.length,2);assert.notEqual(pendingEvents[0].intentID,pendingEvents[1].intentID);
    assert.equal(pendingEvents.every(e=>e.operationID===f.input.attemptID),true);
    const state=await fence.snapshot();assert.equal(state.pending.length,0);assert.equal(state.committed.length,1);
  }));

test('legacy migration outcome does not require reader tables introduced at schema20',
  {skip:!database,timeout:120000},()=>withIsolatedDatabase(async({pool,fence})=>{
    const f=await readyMigration(pool,fence);await f.store.activate(f.input,f.manifestHash);
    const intent={kind:'MIGRATION',operationID:f.input.attemptID,vaults:[{teamID:f.input.teamID,vaultID:f.input.vaultID,attemptID:f.input.attemptID,manifestHash:f.manifestHash}]};
    const outcome=await readCommittedPublicationOutcome({intent,query:(text,values)=>{
      assert.equal(text.includes('vault_publication_projections'),false,'schema19 reconciliation must not touch schema20 reader tables');
      return pool.query(text,values);
    }});
    assert.equal(outcome.operationID,f.input.attemptID);
  }));
