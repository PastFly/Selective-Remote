import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { fileURLToPath } from 'node:url';
import { applyMigrations,loadMigrations } from '../src/migrations.mjs';
import { seedPublishedVault,insertSchemaOperation } from './whole-publication-fixtures.mjs';
import { seedMigration } from './vault-v2-migration-db-fixtures.mjs';
import { uuid } from './vault-v2-migration-fixtures.mjs';

const directory=fileURLToPath(new URL('../migrations/',import.meta.url));
const database=process.env.TEST_DATABASE_URL;
test('whole publication storage and cancellation migrations are additive through version22',async()=>{
  const m=(await loadMigrations(directory)).at(-1);assert.equal(m.version,22);
  assert.doesNotMatch(m.sql,/UPDATE shared_vaults SET format_state|TRUNCATE/iu);
});
async function withDB(work){
  if(!new URL(database).pathname.endsWith('_test'))throw Error('disposable_test_database_required');
  const pool=new pg.Pool({connectionString:database});try{await applyMigrations(pool,directory,{info(){}});await work(pool);}finally{await pool.end();}
}
test('schema preserves V1 rows and defaults; operation intent and ownership are immutable',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),v1=await seedMigration(pool),op=await insertSchemaOperation(pool,f);
  const row=(await pool.query('SELECT format_state,format_schema_version,active_publication_attempt_id FROM shared_vaults WHERE id=$1',[v1.input.vaultID])).rows[0];
  assert.deepEqual(row,{format_state:'V1_ACTIVE',format_schema_version:1,active_publication_attempt_id:null});
  await assert.rejects(pool.query("UPDATE team_publication_operations SET request='{}' WHERE id=$1",[op]),/immutable_publication_operation/);
  await assert.rejects(pool.query('UPDATE team_publication_operations SET actor_user_id=$2 WHERE id=$1',[op,v1.accountID]),/immutable_publication_operation/);
  await assert.rejects(pool.query('DELETE FROM team_publication_operations WHERE id=$1',[op]),/immutable_publication_operation/);
  await assert.rejects(pool.query('UPDATE team_publication_operations SET state=\'COMMITTED\' WHERE id=$1',[op]),/publication_not_ready|publication_atomic_commit_incomplete/);
}));
test('generation link rejects foreign scope and ready requires complete successor attempts',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),foreign=await seedPublishedVault(pool),op=await insertSchemaOperation(pool,f);
  await assert.rejects(pool.query(`INSERT INTO team_publication_generations(operation_id,team_id,vault_id,attempt_id,predecessor_id,predecessor_hash,sequence,policy_version)
    VALUES($1,$2,$3,$4,$5,$6,2,2)`,[op,f.input.teamID,f.input.vaultID,foreign.scope.attemptID,f.scope.attemptID,'a'.repeat(64)]),/scope|foreign key/);
  await assert.rejects(pool.query("UPDATE team_publication_operations SET state='READY' WHERE id=$1",[op]),/publication_generations_incomplete/);
  const before=(await pool.query('SELECT * FROM vault_migration_attempts WHERE id=$1',[f.scope.attemptID])).rows[0];
  await assert.rejects(pool.query('UPDATE shared_vaults SET active_publication_attempt_id=$2 WHERE id=$1',[f.input.vaultID,foreign.scope.attemptID]),/irreversible_v2_publication|publication_scope/);
  const after=(await pool.query('SELECT * FROM vault_migration_attempts WHERE id=$1',[f.scope.attemptID])).rows[0];assert.deepEqual(after,before);
}));
test('receipt and effective-delta outbox cannot be forged before committed operation',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),op=await insertSchemaOperation(pool,f);
  await assert.rejects(pool.query('INSERT INTO team_publication_receipts(operation_id,team_id,body) VALUES($1,$2,$3)',[op,f.input.teamID,{}]),/publication_not_committed/);
  await assert.rejects(pool.query(`INSERT INTO team_publication_outbox(operation_id,team_id,vault_id,resource_id,membership_id,user_id,membership_epoch,before_mask,after_mask)
    VALUES($1,$2,$3,$4,$5,$6,1,1,0)`,[op,f.input.teamID,f.input.vaultID,f.out.resources[0].id,f.recipient.membershipID,f.accountID]),/publication_not_committed/);
}));
test('direct SQL cannot omit counts or bypass the complete participant count with JSON null',{skip:!database},()=>withDB(async pool=>{
  const f=await seedPublishedVault(pool),id=uuid();
  for(const counts of [{},{vaults:null,resources:1,parts:2,wrappers:2},{vaults:1,resources:1,parts:null,wrappers:2}])
    await assert.rejects(pool.query(`INSERT INTO team_publication_operations(id,team_id,actor_user_id,actor_device_id,session_id,actor_key_version,
      request_hash,request,prepared,counts,effective_at) VALUES($1,$2,$3,$4,$5,1,$6,$7,$8,$9,now())`,
      [id,f.input.teamID,f.accountID,f.deviceID,f.sessionID,'a'.repeat(64),{version:1,operationID:id,teamID:f.input.teamID,vaults:[{vaultID:f.input.vaultID}]},{},counts]),/check constraint|publication_scope/);
}));
