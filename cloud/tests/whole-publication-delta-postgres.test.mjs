import test from 'node:test';
import assert from 'node:assert/strict';
import {withDB,seedPublishedVault,requestFor,storeFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
import {uuid} from './vault-v2-migration-fixtures.mjs';
import {defaultMigrationPolicy} from '../src/migration-policy.mjs';
const database=process.env.TEST_DATABASE_URL;
async function viewerFixture(pool,{groups=false,groupGrantCount=null}={}){
  const base=await seedMigration(pool),other=await seedMigration(pool),membershipID=uuid();
  await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'viewer')",[membershipID,base.input.teamID,other.accountID]);
  await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[membershipID,other.deviceID]);
  const own=base.pinnedTrust,foreign=other.pinnedTrust;
  base.pinnedTrust={loadPin:(endpoint,accountID)=>(accountID===base.accountID?own:foreign).loadPin(endpoint,accountID),advancePin:(old,next)=>(old.accountID===base.accountID?own:foreign).advancePin(old,next)};
  const ids=groups?[uuid(),uuid()]:[];
  for(const groupID of ids){
    await pool.query("INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,$4,$3)",[groupID,base.input.teamID,base.accountID,groupID]);
    await pool.query('INSERT INTO team_access_group_members(id,team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id) VALUES($1,$2,$3,$4,$5,1,$6)',[uuid(),base.input.teamID,groupID,other.accountID,membershipID,base.accountID]);
  }
  const f=await seedPublishedVault(pool,{base,policyFor:groups?(resources,snapshot)=>{
    const all=defaultMigrationPolicy({resources,snapshot}),viewer=all.find(g=>g.principalID===other.accountID);
    const {membershipID:unusedID,membershipEpoch:unusedEpoch,...grant}=viewer;
    const principals=groupGrantCount===null?ids:Array.from({length:groupGrantCount},()=>ids[0]);
    return [...all.filter(g=>g.principalID!==other.accountID),...principals.map(principalID=>({...grant,id:uuid(),principalKind:'GROUP',principalID}))];
  }:null});
  f.publicationPins=base.pinnedTrust;return {f,other,membershipID,groupIDs:ids};
}
test('only committed effective delta creates outbox; lost response retries an idempotent notification sink',{skip:!database},()=>withDB(async pool=>{
  const {f,other}=await viewerFixture(pool),s=storeFor(pool,f),request=requestFor(f);
  request.vaults[0].policy=request.vaults[0].policy.filter(g=>g.principalID!==other.accountID);
  const p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);
  assert.equal(p.rows.filter(r=>r.type==='DELTA').length,1);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_outbox WHERE operation_id=$1',[request.operationID])).rows[0].n,0);
  await uploadWholeFixture(s,f,p,out);await s.commit(f.input,request.operationID,p.token,request);
  const row=(await pool.query('SELECT * FROM team_publication_outbox WHERE operation_id=$1',[request.operationID])).rows[0];
  assert.equal(row.user_id,other.accountID);assert.deepEqual([row.before_mask,row.after_mask],[1,0]);
  await s.commit(f.input,request.operationID,null,request);
  const {WholePublicationOutbox}=await import('../src/whole-publication-outbox.mjs');
  const notifications=new Map();let failResponse=true;
  const runner=new WholePublicationOutbox(pool,{...f.config,deliver:async event=>{notifications.set(event.idempotencyKey,event);if(failResponse){failResponse=false;throw Error('lost_sink_response');}}});
  for(const config of [{...f.config,enabled:false},{...f.config,environment:'production'},{...f.config,allowedVaultIDs:[uuid()]}])
    assert.equal(await new WholePublicationOutbox(pool,{...config,deliver:async()=>assert.fail('disabled or foreign outbox delivered')}).dispatchOne(),false);
  assert.equal(await runner.dispatchOne(),false);assert.equal(notifications.size,1);
  await pool.query('UPDATE team_publication_outbox SET available_at=now() WHERE id=$1',[row.id]);
  const otherRunner=new WholePublicationOutbox(pool,{...f.config,deliver:async event=>notifications.set(event.idempotencyKey,event)});
  const results=await Promise.all([runner.dispatchOne(),otherRunner.dispatchOne()]);assert.equal(results.filter(Boolean).length,1);
  assert.equal(await runner.dispatchOne(),false);assert.equal(notifications.size,1);
  assert.equal([...notifications.values()][0].kind,'effective_access_changed');
  assert.equal((await pool.query('SELECT delivered_at FROM team_publication_outbox WHERE id=$1',[row.id])).rows[0].delivered_at instanceof Date,true);
}));
test('group deletion exact 1000 grant fanout commits; 1001 returns typed bounded revoke-first result',{skip:!database},()=>withDB(async pool=>{
  for(const count of [1000,1001]){
    const {f,groupIDs}=await viewerFixture(pool,{groups:true,groupGrantCount:count}),s=storeFor(pool,f),request=requestFor(f);
    request.groupMutation={action:'DELETE',groupID:groupIDs[0]};request.vaults[0].policy=request.vaults[0].policy.filter(g=>g.principalID!==groupIDs[0]);
    if(count===1001){
      await assert.rejects(s.preview(f.input,request),e=>e.code==='group_grants_must_be_revoked_first'&&e.remainingGrantCount===1001);
      assert.equal((await pool.query('SELECT id FROM team_publication_operations WHERE id=$1',[request.operationID])).rows.length,0);
    }else{
      const p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);await uploadWholeFixture(s,f,p,out);await s.commit(f.input,request.operationID,p.token,request);
      assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_outbox WHERE operation_id=$1',[request.operationID])).rows[0].n,1);
    }
  }
}));
test('revoking one group path preserves effective permissions and creates audit without false revoke notification',{skip:!database},()=>withDB(async pool=>{
  const {f,groupIDs}=await viewerFixture(pool,{groups:true}),s=storeFor(pool,f),request=requestFor(f);
  request.groupMutation={action:'DELETE',groupID:groupIDs[0]};request.vaults[0].policy=request.vaults[0].policy.filter(g=>g.principalID!==groupIDs[0]);
  const p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);assert.equal(p.rows.filter(r=>r.type==='DELTA').length,0);
  await uploadWholeFixture(s,f,p,out);await s.commit(f.input,request.operationID,p.token,request);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM team_publication_outbox WHERE operation_id=$1',[request.operationID])).rows[0].n,0);
  assert.equal((await pool.query("SELECT count(*)::int AS n FROM team_audit_events WHERE metadata->>'operationID'=$1",[request.operationID])).rows[0].n,1);
  assert.ok((await pool.query('SELECT deleted_at FROM team_access_groups WHERE id=$1',[groupIDs[0]])).rows[0].deleted_at);
}));
