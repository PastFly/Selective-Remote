import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp, realpath, mkdir, copyFile, readFile, writeFile, chmod, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import pg from 'pg';
import {applyMigrations,loadMigrations} from '../src/migrations.mjs';
import {captureNonTestVaultSnapshot,verifyNonTestVaultSnapshot} from '../src/non-test-vault-snapshot.mjs';

const database=process.env.TEST_DATABASE_URL;
const migrations=fileURLToPath(new URL('../migrations/',import.meta.url));
async function fresh(work){
  const admin=new pg.Pool({connectionString:database,max:1});
  const name=`prc_task6_${randomUUID().replaceAll('-','')}_test`;
  const directory=await realpath(await mkdtemp(join(tmpdir(),'ordinary-vaults-')));
  let created=false,pool;
  try{
    assert.match((await admin.query('SHOW server_version')).rows[0].server_version,/^16\./);
    assert.equal((await admin.query('SELECT rolcreatedb OR rolsuper AS allowed FROM pg_roles WHERE rolname=current_user')).rows[0].allowed,true);
    await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created=true;
    const url=new URL(database);url.pathname=`/${name}`;pool=new pg.Pool({connectionString:url.href,max:2});
    const prefix=join(directory,'prefix');await mkdir(prefix);
    for(const migration of (await loadMigrations(migrations)).filter(m=>m.version<=12))await copyFile(join(migrations,migration.name),join(prefix,migration.name));
    await applyMigrations(pool,prefix,{info(){}});
    await work({pool,directory,path:join(directory,'ordinary.json')});
  } finally {await pool?.end();if(created)await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`);await admin.end();await rm(directory,{recursive:true,force:true});}
}
async function transaction(pool,work){
  const client=await pool.connect();
  try{await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');return await work(client.query.bind(client));}
  finally{await client.query('ROLLBACK');client.release();}
}
async function seed(pool){
  const user=randomUUID(),teamID=randomUUID(),vaultID=randomUUID(),device=randomUUID(),member=randomUUID();
  await pool.query('INSERT INTO users(id,email,username) VALUES($1,$2,$3)',[user,`${user}@example.test`,'s_'+user.replaceAll('-','').slice(0,24)]);
  await pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'fixture','test')",[device,user]);
  await pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'fixture',$2)",[teamID,user]);
  await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'owner')",[member,teamID,user]);
  await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id) VALUES($1,$2,'TEST-ONLY-CODEX-preexisting-still-protected',$3)",[vaultID,teamID,user]);
  await pool.query("INSERT INTO shared_vault_key_wrappers(vault_id,key_generation,membership_id,membership_epoch,device_id,wrapper_version,ephemeral_public_key,ciphertext,nonce,auth_tag,context_hash,created_by_device_id) VALUES($1,1,$2,1,$3,1,'{}',$4,$5,$6,$7,$3)",[vaultID,member,device,'A'.repeat(43),'B'.repeat(16),'C'.repeat(22),'D'.repeat(43)]);
  return {user,teamID,vaultID,device,member};
}

test('ordinary baseline survives additive schema12→22 but detects row, wrapper, format and scope changes',{skip:!database},()=>fresh(async({pool,directory,path})=>{
  const original=await seed(pool);
  await assert.rejects(captureNonTestVaultSnapshot({query:pool.query.bind(pool),path}),/non_test_snapshot_transaction_required/);
  const before=await transaction(pool,query=>captureNonTestVaultSnapshot({query,path}));
  assert.equal(before.vaultCount,1);
  const bytes=await readFile(path,'utf8');
  assert.equal(bytes.includes('preexisting-still-protected'),false);
  assert.equal(bytes.includes('A'.repeat(43)),false);
  await assert.rejects(transaction(pool,query=>captureNonTestVaultSnapshot({query,path})),/non_test_snapshot_/);
  await applyMigrations(pool,migrations,{info(){}});
  const verify=options=>transaction(pool,query=>verifyNonTestVaultSnapshot({query,path,...options}));
  assert.equal((await verify()).unchanged,true);
  await pool.query('UPDATE shared_vaults SET access_policy_version=1 WHERE id=$1',[original.vaultID]);
  await assert.rejects(verify(),/non_test_snapshot_changed/,'a newly added policy field must retain its dormant default');
  await pool.query('UPDATE shared_vaults SET access_policy_version=0 WHERE id=$1',[original.vaultID]);
  await pool.query("UPDATE shared_vaults SET name='tampered' WHERE id=$1",[original.vaultID]);
  await assert.rejects(verify(),/non_test_snapshot_changed/);
  await pool.query("UPDATE shared_vaults SET name='TEST-ONLY-CODEX-preexisting-still-protected' WHERE id=$1",[original.vaultID]);
  await pool.query("UPDATE shared_vault_key_wrappers SET ciphertext=$2 WHERE vault_id=$1",[original.vaultID,'E'.repeat(43)]);
  await assert.rejects(verify(),/non_test_snapshot_changed/);
  await pool.query("UPDATE shared_vault_key_wrappers SET ciphertext=$2 WHERE vault_id=$1",[original.vaultID,'A'.repeat(43)]);
  await pool.query("UPDATE shared_vaults SET format_state='V2_PREPARING',format_schema_version=2 WHERE id=$1",[original.vaultID]);
  await assert.rejects(verify(),/non_test_snapshot_changed/);
  await pool.query("UPDATE shared_vaults SET format_state='V1_ACTIVE',format_schema_version=1 WHERE id=$1",[original.vaultID]);
  const freshID=randomUUID(),name='TEST-ONLY-CODEX-run-1-actual';
  await pool.query('INSERT INTO shared_vaults(id,team_id,name,created_by_user_id) VALUES($1,$2,$3,$4)',[freshID,original.teamID,name,original.user]);
  await assert.rejects(verify(),/non_test_snapshot_scope_changed/);
  const allowedNewVaults=[{teamID:original.teamID,vaultID:freshID,name}];
  assert.equal((await verify({allowedNewVaults})).unchanged,true);
  await assert.rejects(verify({allowedNewVaults:[...allowedNewVaults,...allowedNewVaults]}),/non_test_snapshot_scope_changed/);
  await assert.rejects(verify({allowedNewVaults:[{...allowedNewVaults[0],name:'wrong'}]}),/non_test_snapshot_scope_changed/);
  await pool.query("UPDATE shared_vaults SET name='ordinary-new' WHERE id=$1",[freshID]);
  await assert.rejects(verify({allowedNewVaults}),/non_test_snapshot_scope_changed/);
  assert.equal(await readFile(path,'utf8'),bytes,'verification never overwrites baseline');
  await chmod(path,0o644);await assert.rejects(verify({allowedNewVaults}),/non_test_snapshot_file_invalid/);
  await chmod(path,0o600);await writeFile(path,'{}');await assert.rejects(verify({allowedNewVaults}),/non_test_snapshot_invalid/);
  assert.equal((await readFile(join(directory,'ordinary.json'),'utf8')),'{}');
}));

test('row fingerprints preserve PostgreSQL bigint precision',{skip:!database},()=>fresh(async({pool,path})=>{
  const original=await seed(pool);
  await pool.query('UPDATE shared_vaults SET key_generation=9007199254740992 WHERE id=$1',[original.vaultID]);
  await transaction(pool,query=>captureNonTestVaultSnapshot({query,path}));
  await pool.query('UPDATE shared_vaults SET key_generation=9007199254740993 WHERE id=$1',[original.vaultID]);
  await assert.rejects(transaction(pool,query=>verifyNonTestVaultSnapshot({query,path})),/non_test_snapshot_changed/);
}));

test('resource/publication state cannot appear for an original Vault after schema upgrade',{skip:!database},()=>fresh(async({pool,path})=>{
  const original=await seed(pool);
  await transaction(pool,query=>captureNonTestVaultSnapshot({query,path}));
  await applyMigrations(pool,migrations,{info(){}});
  // Simulate a writer that changes format, writes a registry row and then hides
  // the format change. The ordinary row again says V1, but its inventory differs.
  await pool.query("UPDATE shared_vaults SET format_state='V2_PREPARING',format_schema_version=2 WHERE id=$1",[original.vaultID]);
  await pool.query("INSERT INTO vault_resource_registry(id,team_id,vault_id,policy_class,policy_kind) VALUES($1,$2,$3,'general','HOST')",[randomUUID(),original.teamID,original.vaultID]);
  await pool.query("UPDATE shared_vaults SET format_state='V1_ACTIVE',format_schema_version=1 WHERE id=$1",[original.vaultID]);
  await assert.rejects(transaction(pool,query=>verifyNonTestVaultSnapshot({query,path})),/non_test_snapshot_changed/);
}));

test('existing personal Vaults and users stay exact; fresh personal IDs need explicit account scope',{skip:!database},()=>fresh(async({pool,path})=>{
  const original=await seed(pool),personalID=randomUUID();
  await pool.query('INSERT INTO personal_vaults(id,user_id) VALUES($1,$2)',[personalID,original.user]);
  const before=await transaction(pool,query=>captureNonTestVaultSnapshot({query,path}));
  assert.equal(before.personalVaultCount,1);assert.equal(before.userCount,1);
  const verify=options=>transaction(pool,query=>verifyNonTestVaultSnapshot({query,path,...options}));
  await pool.query("UPDATE users SET display_name='changed' WHERE id=$1",[original.user]);
  await assert.rejects(verify(),/non_test_snapshot_changed/);
  await pool.query("UPDATE users SET display_name='' WHERE id=$1",[original.user]);
  await pool.query('UPDATE personal_vaults SET updated_by_device_id=$2 WHERE id=$1',[personalID,original.device]);
  await assert.rejects(verify(),/non_test_snapshot_changed/);
  await pool.query('UPDATE personal_vaults SET updated_by_device_id=NULL WHERE id=$1',[personalID]);
  const userID=randomUUID(),vaultID=randomUUID();
  await pool.query('INSERT INTO users(id,email,username) VALUES($1,$2,$3)',[userID,`${userID}@example.test`,'s_'+userID.replaceAll('-','').slice(0,24)]);
  await pool.query('INSERT INTO personal_vaults(id,user_id) VALUES($1,$2)',[vaultID,userID]);
  await assert.rejects(verify(),/non_test_snapshot_scope_changed/);
  await assert.rejects(verify({allowedNewPersonalVaults:[{userID:original.user,vaultID}]}),/non_test_snapshot_scope_changed/);
  assert.equal((await verify({allowedNewPersonalVaults:[{userID,vaultID}]})).unchanged,true);
  await applyMigrations(pool,migrations,{info(){}});
  const freshTeam=randomUUID(),freshVault=randomUUID(),freshDevice=randomUUID(),freshMembership=randomUUID();
  await pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'new-test-device','test')",[freshDevice,userID]);
  await pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'new-test-team',$2)",[freshTeam,userID]);
  await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'owner')",[freshMembership,freshTeam,userID]);
  await pool.query("INSERT INTO team_access_groups(team_id,name,created_by_user_id) VALUES($1,'new-test-group',$2)",[freshTeam,userID]);
  await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id) VALUES($1,$2,'TEST-ONLY-CODEX-new-vault',$3)",[freshVault,freshTeam,userID]);
  const allowedNewVaults=[{teamID:freshTeam,vaultID:freshVault,name:'TEST-ONLY-CODEX-new-vault'}];
  assert.equal((await verify({allowedNewVaults,allowedNewPersonalVaults:[{userID,vaultID}]})).unchanged,true,'fresh test Team and device do not change protected authorization scope');
  await pool.query('DELETE FROM personal_vaults WHERE id=$1',[personalID]);
  await assert.rejects(verify({allowedNewVaults,allowedNewPersonalVaults:[{userID,vaultID}]}),/non_test_snapshot_changed/);
}));

for(const kind of ['membership','admission','group edge','device','trust'])
test(`ordinary authorization context detects changed ${kind} without Vault row changes`,{skip:!database},()=>fresh(async({pool,path})=>{
  const original=await seed(pool),groupID=randomUUID(),edgeID=randomUUID();
  if(kind==='admission')await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[original.member,original.device]);
  if(kind==='group edge'){
    await applyMigrations(pool,migrations,{info(){}});
    await pool.query("INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,'ordinary-existing',$3)",[groupID,original.teamID,original.user]);
    await pool.query('INSERT INTO team_access_group_members(id,team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id) VALUES($1,$2,$3,$4,$5,1,$4)',[edgeID,original.teamID,groupID,original.user,original.member]);
  }
  await transaction(pool,query=>captureNonTestVaultSnapshot({query,path}));
  const vaultBefore=(await pool.query('SELECT to_jsonb(v) AS row FROM shared_vaults v WHERE id=$1',[original.vaultID])).rows;
  if(kind==='membership')await pool.query("UPDATE team_memberships SET role='viewer' WHERE id=$1",[original.member]);
  if(kind==='admission')await pool.query('DELETE FROM team_membership_device_admissions WHERE membership_id=$1',[original.member]);
  if(kind==='group edge')await pool.query('UPDATE team_access_group_members SET removed_at=now(),version=version+1 WHERE id=$1',[edgeID]);
  if(kind==='device')await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[original.device]);
  if(kind==='trust'){
    await applyMigrations(pool,migrations,{info(){}});
    await pool.query('INSERT INTO device_trust_roots_v1(account_id,root_public_key,fingerprint) VALUES($1,$2,$3)',[original.user,Buffer.alloc(65,1),Buffer.alloc(32,2)]);
  }
  const vaultAfter=(await pool.query('SELECT to_jsonb(v) AS row FROM shared_vaults v WHERE id=$1',[original.vaultID])).rows[0].row;
  assert.deepEqual(Object.fromEntries(Object.keys(vaultBefore[0].row).map(key=>[key,vaultAfter[key]])),vaultBefore[0].row);
  await assert.rejects(transaction(pool,query=>verifyNonTestVaultSnapshot({query,path})),/non_test_snapshot_changed/);
}));
