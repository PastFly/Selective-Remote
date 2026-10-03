import test from 'node:test';
import assert from 'node:assert/strict';
import {withDB,seedPublishedVault,requestFor,storeFor,insertSchemaOperation} from './whole-publication-fixtures.mjs';
import {uuid} from './vault-v2-migration-fixtures.mjs';
const database=process.env.TEST_DATABASE_URL;
test('confirmed pre-start discard permanently fences delayed START and is immutable/idempotent',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request);
  assert.equal(await s.receipt(f.input,request.operationID),null);
  const result=await s.discard(f.input,request.operationID);assert.equal(result.state,'DISCARDED');
  assert.deepEqual(await s.discard(f.input,request.operationID),result);
  await assert.rejects(s.start(f.input,p.token,request),/publication_discarded/);
  assert.equal((await pool.query('SELECT id FROM team_publication_operations WHERE id=$1',[request.operationID])).rows.length,0);
  await assert.rejects(pool.query('DELETE FROM team_publication_cancellations WHERE operation_id=$1',[request.operationID]),/immutable_publication_cancellation/);
  await assert.rejects(pool.query('UPDATE team_publication_cancellations SET confirmed_by_session=$2 WHERE operation_id=$1',[request.operationID,uuid()]),/immutable_publication_cancellation/);
  assert.equal((await pool.query('SELECT active_publication_attempt_id FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0].active_publication_attempt_id,f.scope.attemptID);
}));
test('old repeatable-read snapshot cannot insert operation after cancellation or cancellation after operation',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f);
  for(const reverse of [false,true]){
    const operationID=uuid(),c=await pool.connect();
    try{
      await c.query('BEGIN ISOLATION LEVEL REPEATABLE READ');await c.query('SELECT count(*) FROM team_publication_cancellations');
      if(reverse){
        await pool.query(`INSERT INTO team_publication_operations(id,team_id,actor_user_id,actor_device_id,session_id,actor_key_version,request_hash,request,prepared,counts,effective_at)
          VALUES($1,$2,$3,$4,$5,1,$6,$7,$8,$9,now())`,[operationID,f.input.teamID,f.accountID,f.deviceID,f.sessionID,'a'.repeat(64),{version:1,teamID:f.input.teamID,operationID,vaults:[{vaultID:f.input.vaultID}]},{},{vaults:1,resources:1,parts:2,wrappers:2}]);
        await assert.rejects(c.query('INSERT INTO team_publication_cancellations(operation_id,team_id,actor_user_id,actor_device_id,confirmed_by_session) VALUES($1,$2,$3,$4,$5)',[operationID,f.input.teamID,f.accountID,f.deviceID,f.sessionID]),/publication_operation_exists|duplicate key|could not serialize/);
      }else{
        await s.discard(f.input,operationID);
        await assert.rejects(c.query(`INSERT INTO team_publication_operations(id,team_id,actor_user_id,actor_device_id,session_id,actor_key_version,request_hash,request,prepared,counts,effective_at)
          VALUES($1,$2,$3,$4,$5,1,$6,$7,$8,$9,now())`,[operationID,f.input.teamID,f.accountID,f.deviceID,f.sessionID,'a'.repeat(64),{version:1,teamID:f.input.teamID,operationID,vaults:[{vaultID:f.input.vaultID}]},{},{vaults:1,resources:1,parts:2,wrappers:2}]),/publication_discarded|duplicate key|could not serialize/);
      }
    }finally{await c.query('ROLLBACK');c.release();}
  }
}));
test('concurrent START/discard has a final discarded operation or tombstone and never a late live attempt',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request);
  const [start,discard]=await Promise.allSettled([s.start(f.input,p.token,request),s.discard(f.input,request.operationID)]);
  assert.equal(discard.status,'fulfilled');if(start.status==='rejected')assert.match(start.reason.message,/publication_discarded/);
  const op=(await pool.query('SELECT state FROM team_publication_operations WHERE id=$1',[request.operationID])).rows[0];
  if(op)assert.equal(op.state,'DISCARDED');else assert.equal((await pool.query('SELECT operation_id FROM team_publication_cancellations WHERE operation_id=$1',[request.operationID])).rows.length,1);
  await assert.rejects(s.start(f.input,p.token,request),/publication_discarded/);
  assert.equal(await s.receipt(f.input,request.operationID),null);
}));
test('direct SQL operation/cancellation insertion orders cannot coexist across concurrent snapshots',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f);await s.discard(f.input,request.operationID);
  const insert=operationID=>pool.query(`INSERT INTO team_publication_operations(id,team_id,actor_user_id,actor_device_id,session_id,actor_key_version,request_hash,request,prepared,counts,effective_at)
    VALUES($1,$2,$3,$4,$5,1,$6,$7,$8,$9,now())`,[operationID,f.input.teamID,f.accountID,f.deviceID,f.sessionID,'a'.repeat(64),{version:1,teamID:f.input.teamID,operationID,vaults:[{vaultID:f.input.vaultID}]},{},{vaults:1,resources:1,parts:2,wrappers:2}]);
  await assert.rejects(insert(request.operationID),/publication_discarded/);
  const existing=await insertSchemaOperation(pool,f);
  await assert.rejects(pool.query('INSERT INTO team_publication_cancellations(operation_id,team_id,actor_user_id,actor_device_id,confirmed_by_session) VALUES($1,$2,$3,$4,$5)',[existing,f.input.teamID,f.accountID,f.deviceID,f.sessionID]),/publication_operation_exists/);
}));
