import test from 'node:test';
import assert from 'node:assert/strict';
import {withDB,storeFor,seedPublishedTeam,seedPublishedVault,requestFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {uuid} from './vault-v2-migration-fixtures.mjs';
import {VaultPublicationStore} from '../src/vault-publication-store.mjs';
import {seedMigration,addSyntheticDevices} from './vault-v2-migration-db-fixtures.mjs';
const database=process.env.TEST_DATABASE_URL;
async function state(pool,f,op){return {
  pointers:(await pool.query("SELECT active_publication_attempt_id FROM shared_vaults WHERE team_id=$1 AND format_state='V2_ACTIVE' ORDER BY id",[f.input.teamID])).rows.map(r=>r.active_publication_attempt_id),
  state:(await pool.query('SELECT state FROM team_publication_operations WHERE id=$1',[op])).rows[0].state,
  receipts:(await pool.query('SELECT count(*)::int AS n FROM team_publication_receipts WHERE operation_id=$1',[op])).rows[0].n,
  outbox:(await pool.query('SELECT count(*)::int AS n FROM team_publication_outbox WHERE operation_id=$1',[op])).rows[0].n,
  audit:(await pool.query("SELECT count(*)::int AS n FROM team_audit_events WHERE metadata->>'operationID'=$1",[op])).rows[0].n,
};}

test('every commit persistence failure leaves both old Vaults, READY and no receipt/audit/outbox; retry commits once',{skip:!database},()=>withDB(async pool=>{
  const {f,request}=await seedPublishedTeam(pool);request.groupMutation={action:'CREATE',groupID:request.operationID,name:'Atomic group'};
  let failure=null;const s=storeFor(pool,f,{faultAt:async point=>{if(point===failure)throw Error('injected_'+point);}}),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);
  await uploadWholeFixture(s,f,p,out);const before=await state(pool,f,request.operationID);
  for(const point of ['commit_precondition','policy_installed','successor_validated','pointer_swapped','operation_committed','outbox_inserted','audit_inserted','receipt_inserted']){
    failure=point;await assert.rejects(s.commit(f.input,request.operationID,p.token,request),/injected_/);
    assert.deepEqual(await state(pool,f,request.operationID),before,point);
    assert.equal((await pool.query('SELECT id FROM team_access_groups WHERE id=$1',[request.operationID])).rows.length,0);
  }
  failure=null;const receipt=await s.commit(f.input,request.operationID,p.token,request),after=await state(pool,f,request.operationID);
  assert.equal(after.state,'COMMITTED');assert.equal(after.receipts,1);assert.equal(after.audit,1);
  assert.deepEqual(after.pointers,receipt.vaults.map(v=>v.generationID));
  assert.deepEqual(await s.commit(f.input,request.operationID,null,request),receipt);
  for(const v of receipt.vaults){const readback=await s.readback(f.input,request.operationID,v.vaultID);assert.deepEqual(readback.header,out.generations.find(g=>g.vaultID===v.vaultID).readerProjection.header);}
}));
test('direct SQL membership, device, tombstone and policy-version changes invalidate frozen publication',{skip:!database},()=>withDB(async pool=>{
  const changes=[
    (p,f)=>p.query("UPDATE team_memberships SET role='admin' WHERE id=$1",[f.recipient.membershipID]),
    (p,f)=>p.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[f.deviceID]),
    (p,f)=>p.query('UPDATE vault_resource_identity_reservations SET deleted_at=now() WHERE id=$1',[f.out.resources[0].id]),
    (p,f)=>p.query('UPDATE shared_vaults SET access_policy_version=access_policy_version+1 WHERE id=$1',[f.input.vaultID]),
  ];
  for(const change of changes){
    const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);await uploadWholeFixture(s,f,p,out);
    const before=await state(pool,f,request.operationID);await change(pool,f);
    await assert.rejects(s.commit(f.input,request.operationID,p.token,request),/preview_invalidated|publication_stale|publication_repair_required|publication_session_invalid|team_access_denied/);
    assert.deepEqual(await state(pool,f,request.operationID),before);
  }
}));
test('conflicting direct SQL device writer waits for atomic commit, then ordinary reads require repair',{skip:!database},()=>withDB(async pool=>{
  const base=await seedMigration(pool),others=await addSyntheticDevices(pool,base,1);
  base.recipient.checkpoint=(await pool.query('SELECT directory_json FROM device_trust_directories_v1 WHERE account_id=$1 ORDER BY version DESC LIMIT 1',[base.accountID])).rows[0].directory_json;
  const f=await seedPublishedVault(pool,{base});let signal,release;
  const barrier=new Promise(r=>signal=r),wait=new Promise(r=>release=r);
  const s=storeFor(pool,f,{faultAt:async point=>{if(point==='commit_precondition'){signal();await wait;}}}),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);await uploadWholeFixture(s,f,p,out);
  const committing=s.commit(f.input,request.operationID,p.token,request);await barrier;
  let changed=false;const sql=pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[others[0].deviceID]).then(()=>{changed=true;});
  try{await pool.query('SELECT pg_sleep(0.05)');assert.equal(changed,false);}finally{release();}
  const receipt=await committing;await sql;assert.equal(receipt.operationID,request.operationID);
  await assert.rejects(new VaultPublicationStore(pool,f.config).header(f.input),/publication_repair_required/);
}));
test('readers observe complete old or new pointer sets while first swap is uncommitted',{skip:!database},()=>withDB(async pool=>{
  const {f,request}=await seedPublishedTeam(pool);let resolveBarrier,releaseCommit;
  const barrier=new Promise(r=>resolveBarrier=r),release=new Promise(r=>releaseCommit=r);
  let first=true;const s=storeFor(pool,f,{faultAt:async point=>{if(point==='pointer_swapped'&&first){first=false;resolveBarrier();await release;}}});
  const p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);await uploadWholeFixture(s,f,p,out);
  const before=await state(pool,f,request.operationID),committing=s.commit(f.input,request.operationID,p.token,request);
  await barrier;try{assert.deepEqual(await state(pool,f,request.operationID),before);}finally{releaseCommit();}
  const receipt=await committing;assert.deepEqual((await state(pool,f,request.operationID)).pointers,receipt.vaults.map(v=>v.generationID));
}));
test('direct SQL trust/group phantom invalidates frozen READY; no automatic re-preview',{skip:!database},()=>withDB(async pool=>{
  const {f,request}=await seedPublishedTeam(pool),s=storeFor(pool,f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);await uploadWholeFixture(s,f,p,out);
  const before=await state(pool,f,request.operationID);
  await pool.query("INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,'phantom after READY',$3)",[request.operationID,f.input.teamID,f.accountID]);
  await assert.rejects(s.commit(f.input,request.operationID,p.token,request),/preview_invalidated|publication_stale/);
  assert.deepEqual(await state(pool,f,request.operationID),before);
  await assert.rejects(s.preview(f.input,request),/publication_stale/);
}));
test('expired session after a conflicting SQL lock wait leaves READY intact; new authenticated session can explicitly re-preview',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);
  await uploadWholeFixture(s,f,p,out);const before=await state(pool,f,request.operationID),blocker=await pool.connect();
  await pool.query("UPDATE sessions SET expires_at=clock_timestamp()+interval '400 milliseconds' WHERE id=$1",[f.sessionID]);
  let result;
  try{
    await blocker.query('BEGIN');await blocker.query('LOCK TABLE sessions IN ROW EXCLUSIVE MODE');
    const committing=s.commit(f.input,request.operationID,p.token,request).then(value=>({value}),error=>({error}));
    await blocker.query('SELECT pg_sleep(0.5)');await blocker.query('COMMIT');result=await committing;
  }finally{await blocker.query('ROLLBACK').catch(()=>{});blocker.release();}
  assert.match(result.error?.message??'',/publication_session_invalid/);assert.deepEqual(await state(pool,f,request.operationID),before);
  const sessionID=uuid();await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[sessionID,f.accountID,f.deviceID,uuid()]);
  const input={...f.input,sessionID};await assert.rejects(s.commit(input,request.operationID,p.token,request),/preview_invalidated/);
  const fresh=await s.preview(input,request);const receipt=await s.commit(input,request.operationID,fresh.token,request);
  assert.deepEqual(await s.receipt(input,request.operationID),receipt);
  await assert.rejects(s.receipt({...input,actorDeviceID:uuid()},request.operationID),/publication_session_invalid/);
}));
test('two exact concurrent preparations cannot both become READY or publish their old predecessor',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),a=requestFor(f),b=requestFor(f),pa=await s.preview(f.input,a),pb=await s.preview(f.input,b);
  const oa=await prepareWholeFixture(f,pa),ob=await prepareWholeFixture(f,pb);
  for(const [p,out] of [[pa,oa],[pb,ob]]){
    await s.start(f.input,p.token,p.request);
    for(const g of out.generations){for(const object of g.objects)await s.putPart(f.input,out.request.operationID,g.vaultID,object);await s.putProjection(f.input,out.request.operationID,g.vaultID,g.readerProjection,g.administrativeSidecar);}
  }
  const manifests=out=>out.generations.map(g=>({vaultID:g.vaultID,manifest:g.manifest}));
  const results=await Promise.allSettled([s.validate(f.input,a.operationID,manifests(oa)),s.validate(f.input,b.operationID,manifests(ob))]);
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.match(results.find(r=>r.status==='rejected').reason.message,/publication_ready_attempt_exists/);
  const winner=results[0].status==='fulfilled'?[a,pa]:[b,pb],loser=results[0].status==='fulfilled'?[b,pb]:[a,pa];
  await s.commit(f.input,winner[0].operationID,winner[1].token,winner[0]);
  await assert.rejects(s.commit(f.input,loser[0].operationID,loser[1].token,loser[0]),/publication_not_ready|publication_stale|preview_invalidated/);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_receipts WHERE operation_id=ANY($1::uuid[])',[[a.operationID,b.operationID]])).rows[0].n,1);
}));
