import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { mkdtemp,copyFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { applyMigrations,loadMigrations } from '../src/migrations.mjs';
import { seedMigration } from './vault-v2-migration-db-fixtures.mjs';
import { uuid } from './vault-v2-migration-fixtures.mjs';
const database=process.env.TEST_DATABASE_URL,directory=fileURLToPath(new URL('../migrations/',import.meta.url));
const r=()=>({id:uuid(),kind:'HOST',parentFolderID:null,sourceOrdinal:0});
async function attempt(c,f,resource,attemptID=uuid()) {
 await c.query("INSERT INTO vault_migration_attempts(id,team_id,vault_id,actor_user_id,actor_device_id,source_revision,source_hash,snapshot_hash,snapshot,policy,resources,scope) VALUES($1,$2,$3,$4,$5,1,'source',$6,'{}','[]',$7,'{}')",[attemptID,f.input.teamID,f.input.vaultID,f.accountID,f.deviceID,'a'.repeat(64),JSON.stringify([resource])]);
 return attemptID;
}
const associate=(c,f,resource,id)=>c.query("INSERT INTO vault_migration_resources(id,attempt_id,team_id,vault_id,kind,source_ordinal) VALUES($1,$2,$3,$4,$5,0)",[resource.id,id,f.input.teamID,f.input.vaultID,resource.kind]);
const registry=(c,f,resource)=>c.query("INSERT INTO vault_resource_registry(id,team_id,vault_id,policy_class,policy_kind) VALUES($1,$2,$3,'general','HOST')",[resource.id,f.input.teamID,f.input.vaultID]);
async function isolatedDatabase(work) {
 const admin=new pg.Pool({connectionString:database}),name='publication_upgrade_'+uuid().replaceAll('-','');
 await admin.query('CREATE DATABASE '+name);
 const url=new URL(database);url.pathname='/'+name;const pool=new pg.Pool({connectionString:url.toString()});
 try{return await work(pool);}finally{await pool.end();await admin.query('DROP DATABASE '+name);await admin.end();}
}
async function prefix(max,work) {
 const path=await mkdtemp(join(tmpdir(),'publication-migrations-'));
 try{for(const migration of await loadMigrations(directory))if(migration.version<=max)await copyFile(join(directory,migration.name),join(path,migration.name));return await work(path);}
 finally{await rm(path,{recursive:true,force:true});}
}
test('fresh and schema12→22 preserve an existing V1 Vault and install scoped identity storage',{skip:!database},async()=>{
 await isolatedDatabase(async pool=>{
  await prefix(12,async old=>applyMigrations(pool,old,{info(){}}));
  const user=uuid(),device=uuid(),team=uuid(),vault=uuid();
  await pool.query("INSERT INTO users(id,email,username) VALUES($1,'upgrade@example.test','upgrade')",[user]);
  await pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'synthetic','test')",[device,user]);
  await pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'synthetic upgrade',$2)",[team,user]);
  await pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')",[team,user]);
  await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id) VALUES($1,$2,'synthetic unchanged',$3)",[vault,team,user]);
  await applyMigrations(pool,directory,{info(){}});
  const row=(await pool.query('SELECT format_state,format_schema_version,active_publication_attempt_id FROM shared_vaults WHERE id=$1',[vault])).rows[0];
  assert.deepEqual(row,{format_state:'V1_ACTIVE',format_schema_version:1,active_publication_attempt_id:null});
  assert.equal(Number((await pool.query('SELECT max(version) version FROM schema_migrations')).rows[0].version),22);
  assert.match((await pool.query('SHOW server_version')).rows[0].server_version,/^16\./);
 });
});
test('schema19→20 recovers released discarded identities and refuses conflicting historical cross-scope reuse',{skip:!database},async()=>{
 for(const conflict of [false,true])await isolatedDatabase(async pool=>{
  await prefix(19,async old=>applyMigrations(pool,old,{info(){}}));
  const f=await seedMigration(pool),resource=r(),id=await attempt(pool,f,resource);
  await associate(pool,f,resource,id);await pool.query("UPDATE vault_migration_attempts SET state='DISCARDED' WHERE id=$1",[id]);
  await pool.query('DELETE FROM vault_migration_resources WHERE attempt_id=$1',[id]);
  assert.equal((await pool.query('SELECT count(*)::int n FROM vault_resource_identity_reservations WHERE id=$1',[resource.id])).rows[0].n,0);
  if(conflict){const other=await seedMigration(pool);await associate(pool,other,resource,await attempt(pool,other,resource));
   await assert.rejects(applyMigrations(pool,directory,{info(){}}),/historical_resource_id_collision/);
   assert.equal(Number((await pool.query('SELECT max(version) version FROM schema_migrations')).rows[0].version),19);
  }else{await applyMigrations(pool,directory,{info(){}});
   const reserved=(await pool.query('SELECT team_id,vault_id,kind FROM vault_resource_identity_reservations WHERE id=$1',[resource.id])).rows[0];
   assert.deepEqual(reserved,{team_id:f.input.teamID,vault_id:f.input.vaultID,kind:'HOST'});
   await associate(pool,f,resource,await attempt(pool,f,resource));
  }
 });
});
test('registry and generation insertion orders share permanent same-scope identity and retain deletion tombstones',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database});
 try{
  await applyMigrations(pool,directory,{info(){}});
  for(const registryFirst of [false,true]){
   const f=await seedMigration(pool),resource=r();
   await pool.query("UPDATE shared_vaults SET format_state='V2_PREPARING',format_schema_version=2 WHERE id=$1",[f.input.vaultID]);
   if(registryFirst)await registry(pool,f,resource);
   await associate(pool,f,resource,await attempt(pool,f,resource));
   if(!registryFirst)await registry(pool,f,resource);
   assert.equal((await pool.query('SELECT count(*)::int n FROM vault_resource_identity_reservations WHERE id=$1',[resource.id])).rows[0].n,1);
   await pool.query('UPDATE vault_resource_registry SET deleted_at=now(),resource_version=resource_version+1 WHERE id=$1',[resource.id]);
   await assert.rejects(associate(pool,f,resource,await attempt(pool,f,resource)),/tombstoned_resource_identity/);
   await assert.rejects(pool.query('UPDATE vault_resource_identity_reservations SET deleted_at=NULL WHERE id=$1',[resource.id]),/immutable_resource_identity_reservation/);
   await assert.rejects(pool.query('DELETE FROM vault_resource_identity_reservations WHERE id=$1',[resource.id]),/immutable_resource_identity_reservation/);
  }
 }finally{await pool.end();}
});
test('direct SQL association/tombstone races lock the physical identity in both orders',{skip:!database},async()=>{
 const pool=new pg.Pool({connectionString:database,max:5});
 try{
  for(const tombstoneFirst of [false,true]){
   const f=await seedMigration(pool),resource=r();
   await pool.query("UPDATE shared_vaults SET format_state='V2_PREPARING',format_schema_version=2 WHERE id=$1",[f.input.vaultID]);
   await registry(pool,f,resource);const id=await attempt(pool,f,resource),writer=await pool.connect(),competitor=await pool.connect();
   try{
    await writer.query('BEGIN');
    if(tombstoneFirst)await writer.query('UPDATE vault_resource_registry SET deleted_at=now(),resource_version=resource_version+1 WHERE id=$1',[resource.id]);
    else await associate(writer,f,resource,id);
    const pid=(await competitor.query('SELECT pg_backend_pid() pid')).rows[0].pid;
    let completed=false;
    const waiting=(tombstoneFirst?associate(competitor,f,resource,id):competitor.query('UPDATE vault_resource_registry SET deleted_at=now(),resource_version=resource_version+1 WHERE id=$1',[resource.id]))
     .then(value=>({value}),error=>({error})).finally(()=>{completed=true;});
    let blocked=false;for(let n=0;n<100;n++){const locks=(await pool.query('SELECT cardinality(pg_blocking_pids($1))::int n',[pid])).rows[0].n;
     if(locks){blocked=true;break;}await new Promise(r=>setTimeout(r,5));}
    assert.equal(blocked,true);assert.equal(completed,false);await writer.query('COMMIT');
    const result=await waiting;
    if(tombstoneFirst)assert.match(result.error.message,/tombstoned_resource_identity/);else assert.ok(result.value);
    await assert.rejects(associate(pool,f,resource,await attempt(pool,f,resource)),/tombstoned_resource_identity/);
   }finally{await writer.query('ROLLBACK');writer.release();competitor.release();}
  }
 }finally{await pool.end();}
});
