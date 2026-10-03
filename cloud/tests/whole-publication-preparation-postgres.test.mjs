import test from 'node:test';
import assert from 'node:assert/strict';
import {withDB,requestFor,storeFor,seedPublishedVault,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
const database=process.env.TEST_DATABASE_URL;
test('start durably freezes exact operation and retains ACTIVE predecessor without pointer change',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),preview=await s.preview(f.input,request);
  const started=await s.start(f.input,preview.token,request);
  assert.equal(started.state,'PREPARING');assert.equal(started.operationID,request.operationID);
  assert.deepEqual((await s.start(f.input,preview.token,request)).generations,started.generations);
  assert.equal((await pool.query('SELECT active_publication_attempt_id FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0].active_publication_attempt_id,f.scope.attemptID);
  const op=(await pool.query('SELECT * FROM team_publication_operations WHERE id=$1',[request.operationID])).rows[0];
  assert.equal(op.state,'PREPARING');assert.equal(op.request_hash,preview.binding.requestHash);
  await assert.rejects(s.putPart(f.input,request.operationID,f.input.vaultID,f.out.objects[0]),/invalid_migration_object/);
  await assert.rejects(s.validate(f.input,request.operationID,[]),/publication_incomplete/);
  await assert.rejects(s.start(f.input,preview.token,{...request,groupMutation:{action:'CREATE',groupID:request.operationID,name:'changed'}}),/publication_replay_conflict|preview_invalidated/);
}));
test('complete fresh generation reaches immutable READY; identical upload retries succeed and changed bytes fail',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p);
  const ready=await uploadWholeFixture(s,f,p,out);assert.equal(ready.state,'READY');
  const g=out.generations[0];assert.notEqual(g.objects[0].envelope.nonce,f.out.objects[0].envelope.nonce);
  assert.deepEqual(await s.putPart(f.input,request.operationID,g.vaultID,g.objects[0]),g.objects[0]);
  const changed=structuredClone(g.objects[0]);changed.sha256='b'.repeat(64);
  await assert.rejects(s.putPart(f.input,request.operationID,g.vaultID,changed),/migration_object_hash|publication_replay_conflict/);
  await assert.rejects(pool.query("UPDATE vault_migration_parts SET sha256=$2 WHERE attempt_id=$1",[g.generationID,'c'.repeat(64)]),/immutable_migration_object/);
  assert.equal((await pool.query('SELECT active_publication_attempt_id FROM shared_vaults WHERE id=$1',[g.vaultID])).rows[0].active_publication_attempt_id,f.scope.attemptID);
  const another=requestFor(f);await assert.rejects(s.preview(f.input,another),/publication_ready_attempt_exists/);
  assert.equal((await s.preview(f.input,request)).binding.readSetHash,p.binding.readSetHash);
  await s.discard(f.input,request.operationID);await s.preview(f.input,another);
}));
test('incomplete coverage and wrong successor header/context never reach READY',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p),g=out.generations[0];
  await s.start(f.input,p.token,request);
  await assert.rejects(s.validate(f.input,request.operationID,[{vaultID:g.vaultID,manifest:g.manifest}]),/migration_parts_incomplete/);
  const missing=structuredClone(g.objects[0]);missing.wrappers=[];
  const {migrationHash}=await import('../src/migration-policy.mjs');const {sha256,...body}=missing;missing.sha256=await migrationHash(body);
  await assert.rejects(s.putPart(f.input,request.operationID,g.vaultID,missing),/migration_wrapper_coverage/);
  await s.putPart(f.input,request.operationID,g.vaultID,g.objects[0]);
  const projection=structuredClone(g.readerProjection);projection.header.payload.sequence=1;
  await assert.rejects(s.putProjection(f.input,request.operationID,g.vaultID,projection,g.administrativeSidecar),/publication_signature_invalid|publication_scope_mismatch|publication_invalid/);
  assert.equal((await pool.query('SELECT state FROM team_publication_operations WHERE id=$1',[request.operationID])).rows[0].state,'PREPARING');
}));

test('bounded projection chunks are immutable and only complete digest reaches stored projection',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),s=storeFor(pool,f),request=requestFor(f),p=await s.preview(f.input,request),out=await prepareWholeFixture(f,p),g=out.generations[0];
  await s.start(f.input,p.token,request);for(const o of g.objects)await s.putPart(f.input,request.operationID,g.vaultID,o);
  const {canonicalMigrationJSON}=await import('../src/migration-policy.mjs'),{createHash}=await import('node:crypto');
  const payload=Buffer.from(canonicalMigrationJSON({projection:g.readerProjection,sidecar:g.administrativeSidecar})),sha256=createHash('sha256').update(payload).digest('hex'),mid=Math.floor(payload.length/2);
  const chunks=[payload.subarray(0,mid),payload.subarray(mid)].map((data,index)=>({version:1,index,count:2,sha256,data:data.toString('base64url')}));
  assert.equal((await s.putProjectionChunk(f.input,request.operationID,g.vaultID,chunks[1])).complete,false);
  assert.equal((await pool.query('SELECT attempt_id FROM vault_publication_projections WHERE attempt_id=$1',[g.generationID])).rows.length,0);
  await assert.rejects(s.putProjectionChunk(f.input,request.operationID,g.vaultID,{...chunks[1],data:Buffer.from('changed').toString('base64url')}),/publication_replay_conflict/);
  assert.equal((await s.putProjectionChunk(f.input,request.operationID,g.vaultID,chunks[0])).complete,true);
  assert.equal((await s.putProjectionChunk(f.input,request.operationID,g.vaultID,chunks[0])).complete,true);
  await s.validate(f.input,request.operationID,[{vaultID:g.vaultID,manifest:g.manifest}]);
  await assert.rejects(pool.query('UPDATE team_publication_upload_chunks SET chunk_data=$3 WHERE operation_id=$1 AND vault_id=$2',[request.operationID,g.vaultID,Buffer.from('changed')]),/immutable_publication_upload/);
}));
