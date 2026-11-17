import test from 'node:test';import assert from 'node:assert/strict';
import {isolatedPublicationDatabase} from './publication-runtime-fixture.mjs';
import {withDB,seedPublishedVault} from './whole-publication-fixtures.mjs';import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
import {mkdtemp,readFile,realpath,rm} from 'node:fs/promises';import {join} from 'node:path';import {tmpdir} from 'node:os';
const temporary=[];test.after(async()=>{await Promise.all(temporary.map(dir=>rm(dir,{recursive:true,force:true})));});
import {captureNonTestVaultSnapshot} from '../src/non-test-vault-snapshot.mjs';
import {randomUUID} from 'node:crypto';
import {queryPublicScope,validateEnrollment} from '../scripts/staging-migration-operator-helper.mjs';
async function withIsolatedDB(work){
 const isolated=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
 try{return await work(isolated.pool);}finally{await isolated.cleanup();}
}
// Reproduce CI ordering: another suite has already published a V2 Vault in
// the shared base. Provisioning fixtures must neither capture it as V1 nor erase it.
let sharedV2;
test.before(async()=>{if(process.env.TEST_DATABASE_URL)await withDB(async pool=>{sharedV2=await seedPublishedVault(pool);});});
test.after(async()=>{if(sharedV2)await withDB(async pool=>{
 const row=(await pool.query('SELECT format_state,active_publication_attempt_id FROM shared_vaults WHERE id=$1',[sharedV2.input.vaultID])).rows[0];
 assert.deepEqual(row,{format_state:'V2_ACTIVE',active_publication_attempt_id:sharedV2.input.attemptID});
});});
test('actual PG adapter validates new public scope and denies revoked actor/device and baseline IDs',{skip:!process.env.TEST_DATABASE_URL},()=>withIsolatedDB(async pool=>{
 const f=await seedMigration(pool),scope={teamID:f.input.teamID,vaultID:f.input.vaultID,actorUserID:f.input.actorUserID,actorDeviceID:f.input.actorDeviceID,name:'TEST-ONLY-CODEX-provision-vault',attemptID:null};
 await pool.query('UPDATE shared_vaults SET name=$2 WHERE id=$1',[scope.vaultID,scope.name]);
 const query=(sql,values)=>pool.query(sql,values),baseline={scope:{shared:[],users:[],teams:[],personal:[]}},emails=[f.accountID+'@example.test','second@example.test'];
 const {row}=await queryPublicScope(query,scope);assert.deepEqual(validateEnrollment(scope,'provision',baseline,row,emails),scope);
 assert.throws(()=>validateEnrollment(scope,'provision',{scope:{...baseline.scope,shared:[scope.vaultID]}},row,emails));
 await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[scope.actorDeviceID]);await assert.rejects(queryPublicScope(query,scope));
 const f2=await seedMigration(pool);const scope2={...scope,teamID:f2.input.teamID,vaultID:f2.input.vaultID,actorUserID:f2.input.actorUserID,actorDeviceID:f2.input.actorDeviceID};
 await pool.query('UPDATE team_memberships SET revoked_at=now() WHERE team_id=$1 AND user_id=$2',[scope2.teamID,scope2.actorUserID]);await assert.rejects(queryPublicScope(query,scope2));
}));

test('baseline captures empty pre-existing teams and all users before test enrollment',{skip:!process.env.TEST_DATABASE_URL},()=>withIsolatedDB(async pool=>{
 const f=await seedMigration(pool),emptyTeam=randomUUID();await pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'TEST-ONLY-CODEX-provision-empty',$2)",[emptyTeam,f.accountID]);
 const directory=await realpath(await mkdtemp(join(tmpdir(),'staging-inventory-'))),path=join(directory,'ordinary.json');
 temporary.push(directory);const client=await pool.connect();try{await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');await captureNonTestVaultSnapshot({query:(sql,v)=>client.query(sql,v),path});await client.query('COMMIT');}finally{client.release();}
 const baseline=JSON.parse(await readFile(path));assert.ok(baseline.scope.teams.includes(emptyTeam));assert.ok(baseline.scope.users.includes(f.accountID));
 const scope={teamID:emptyTeam,vaultID:randomUUID(),actorUserID:randomUUID(),actorDeviceID:randomUUID(),name:'TEST-ONLY-CODEX-provision-fresh',attemptID:null},row={id:scope.vaultID,team_id:emptyTeam,name:scope.name,user_id:scope.actorUserID,device_id:scope.actorDeviceID,email:'one@example.test',format_state:'V1_ACTIVE'};
 assert.throws(()=>validateEnrollment(scope,'provision',baseline,row,['one@example.test','two@example.test']),/enrollment/);
}));
