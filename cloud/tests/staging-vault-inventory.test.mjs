import assert from 'node:assert/strict';
import test from 'node:test';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {randomUUID} from 'node:crypto';
import {mkdtemp,realpath,mkdir,copyFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import pg from 'pg';
import {applyMigrations,loadMigrations} from '../src/migrations.mjs';
const execute=promisify(execFile),database=process.env.TEST_DATABASE_URL;
const script=fileURLToPath(new URL('../scripts/staging-vault-inventory.mjs',import.meta.url));
const migrations=fileURLToPath(new URL('../migrations/',import.meta.url));
const allowlist={allowedNewVaults:[],allowedNewPersonalVaults:[]};
async function cli(args,{input='',url='postgres://synthetic-sensitive-password@127.0.0.1:1/invalid',environment='staging'}={}){
 const child=execute(process.execPath,[script,...args],{env:{...process.env,MIGRATION_ENVIRONMENT:environment,DATABASE_URL:url},encoding:'utf8',timeout:15000,maxBuffer:65536});
 child.child.stdin.on('error',()=>{});child.child.stdin.end(input);
 try{return {status:0,...await child};}catch(error){return {status:error.code,stdout:error.stdout,stderr:error.stderr};}
}
test('inventory CLI rejects environment, arguments and non-allowlist stdin before connecting',async()=>{
 const cases=[{args:['capture','/tmp/a'],environment:'production',error:'staging_inventory_environment'},
  {args:['capture','relative'],error:'staging_inventory_arguments'},{args:['capture','/tmp/a','--replace'],error:'staging_inventory_arguments'},
  {args:['capture','/tmp/a'],input:'{}',error:'staging_inventory_input'},
  {args:['verify','/tmp/a'],input:'',error:'staging_inventory_input'},
  {args:['verify','/tmp/a'],input:JSON.stringify({...allowlist,password:'never-print-this'}),error:'staging_inventory_input'},
  {args:['verify','/tmp/a'],input:JSON.stringify({...allowlist,allowedNewVaults:[{teamID:randomUUID(),vaultID:randomUUID(),name:'TEST-ONLY-CODEX-new',token:'never-print-this'}]}),error:'staging_inventory_input'},
  {args:['verify','/tmp/a'],input:'x'.repeat(65537),error:'staging_inventory_input'}];
 for(const c of cases){const result=await cli(c.args,c);assert.equal(result.status,1);assert.equal(result.stdout,'');assert.equal(result.stderr.trim(),c.error);assert.doesNotMatch(result.stderr,/never-print|sensitive-password|127\.0\.0\.1/);}
});
async function fresh(work){
 const admin=new pg.Pool({connectionString:database,max:1}),name='prc_inventory_'+randomUUID().replaceAll('-','');
 const directory=await realpath(await mkdtemp(join(tmpdir(),'prc-inventory-cli-')));let created=false,pool;
 try{assert.match((await admin.query('SHOW server_version')).rows[0].server_version,/^16\./);await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created=true;
  const url=new URL(database);url.pathname='/'+name;pool=new pg.Pool({connectionString:url.href,max:2});const prefix=join(directory,'prefix');await mkdir(prefix);
  for(const m of (await loadMigrations(migrations)).filter(m=>m.version<=12))await copyFile(join(migrations,m.name),join(prefix,m.name));
  await applyMigrations(pool,prefix,{info(){}});await work({pool,url:url.href,path:join(directory,'baseline.json')});
 }finally{try{await pool?.end();if(created)await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`);}finally{await admin.end();await rm(directory,{recursive:true,force:true});}}
}
async function seed(pool){
 const user=randomUUID(),device=randomUUID(),team=randomUUID(),member=randomUUID(),vault=randomUUID();
 await pool.query('INSERT INTO users(id,email,username) VALUES($1,$2,$3)',[user,user+'@example.test','i_'+user.replaceAll('-','').slice(0,24)]);
 await pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'synthetic','test')",[device,user]);
 await pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'ordinary',$2)",[team,user]);
 await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'owner')",[member,team,user]);
 await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id) VALUES($1,$2,'ordinary-never-print-row',$3)",[vault,team,user]);
 await pool.query("INSERT INTO shared_vault_key_wrappers(vault_id,key_generation,membership_id,membership_epoch,device_id,wrapper_version,ephemeral_public_key,ciphertext,nonce,auth_tag,context_hash,created_by_device_id) VALUES($1,1,$2,1,$3,1,'{}',$4,$5,$6,$7,$3)",[vault,member,device,'A'.repeat(43),'B'.repeat(16),'C'.repeat(22),'D'.repeat(43)]);
 return {user,device,team,member,vault};
}
test('real CLI captures schema12, verifies schema22, refuses overwrite and detects original row/wrapper/auth changes',
 {skip:!database,timeout:120000},()=>fresh(async({pool,url,path})=>{
  const f=await seed(pool),captured=await cli(['capture',path],{url});assert.equal(captured.status,0,captured.stderr);
  const before=JSON.parse(captured.stdout);assert.deepEqual(Object.keys(before).sort(),['personalVaultCount','sha256','userCount','vaultCount']);assert.equal(before.vaultCount,1);assert.equal(before.userCount,1);assert.match(before.sha256,/^[a-f0-9]{64}$/);
  const bytes=await readFile(path),repeat=await cli(['capture',path],{url});assert.equal(repeat.status,1);assert.equal(repeat.stderr.trim(),'non_test_snapshot_file_invalid');assert.deepEqual(await readFile(path),bytes);
  await applyMigrations(pool,migrations,{info(){}});
  const verify=()=>cli(['verify',path],{url,input:JSON.stringify(allowlist)});
  const good=await verify();assert.equal(good.status,0,good.stderr);assert.deepEqual(JSON.parse(good.stdout),{unchanged:true,...before});
  for(const [query,values,restore,restored] of [
   ["UPDATE shared_vaults SET name='changed-row' WHERE id=$1",[f.vault],"UPDATE shared_vaults SET name='ordinary-never-print-row' WHERE id=$1",[f.vault]],
   ['UPDATE shared_vault_key_wrappers SET ciphertext=$2 WHERE vault_id=$1',[f.vault,'E'.repeat(43)],'UPDATE shared_vault_key_wrappers SET ciphertext=$2 WHERE vault_id=$1',[f.vault,'A'.repeat(43)]],
   ['UPDATE devices SET revoked_at=now() WHERE id=$1',[f.device],null,null],
  ]){
   await pool.query(query,values);const bad=await verify();assert.equal(bad.status,1);assert.equal(bad.stdout,'');assert.equal(bad.stderr.trim(),'non_test_snapshot_changed');assert.deepEqual(await readFile(path),bytes);
   if(restore){await pool.query(restore,restored);assert.equal((await verify()).status,0);}
  }
  assert.doesNotMatch(captured.stdout+good.stdout,/ordinary-never-print|example\.test|AAAAAAAA|DATABASE_URL/);
 }));
