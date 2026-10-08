import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID,createHash} from 'node:crypto';
import {mkdtemp,realpath,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createServer} from 'node:net';
import pg from 'pg';
import {applyMigrations} from '../src/migrations.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {VaultMigrationStore} from '../src/vault-migration-store.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
import {prepareMigrationInventory,prepareLegacyMigration} from '../public/vault-v2-migration.js';
import {legacy,record} from './vault-v2-migration-fixtures.mjs';
import {runStagingMigration} from '../scripts/vault-v2-migration-staging.mjs';
import {verifyDeploymentCompatibility,currentCapabilities} from '../src/deployment-compatibility.mjs';

const database=process.env.TEST_DATABASE_URL;
const options={skip:!database,timeout:120000};
// Same import-only stdin adapter selected by the installed root helper. No UID override.
async function invoke(config,request,activationFault){
 const code="try{const {runStagingMigrationInput}=await import("+JSON.stringify(new URL('../scripts/vault-v2-migration-staging.mjs',import.meta.url).href)+");await runStagingMigrationInput("+JSON.stringify(activationFault===undefined?{}:{activationFault})+");}catch(error){process.stderr.write(error.message+'\\n');process.exitCode=1;}";
 const child=spawn(process.execPath,['--input-type=module','-e',code],{env:{PATH:process.env.PATH,MIGRATION_ENVIRONMENT:config.environment,MIGRATION_SYNTHETIC_ENABLED:'YES',
  MIGRATION_SYNTHETIC_VAULT_IDS:config.allowedVaultIDs.join(','),MIGRATION_STAGING_DATABASE_URL:config.databaseURL,MIGRATION_FENCE_PATH:config.fencePath,
  MIGRATION_ACTIVATION_POLICY_PATH:config.policyPath,MIGRATION_CONTROLLER_IDENTITY_PATH:config.controllerIdentityPath}});
 let stdout='',stderr='';child.stdout.on('data',bytes=>stdout+=bytes);child.stderr.on('data',bytes=>stderr+=bytes);child.stdin.end(JSON.stringify(request));
 const [codeValue,signal]=await once(child,'exit');assert.equal(signal,null);
 if(codeValue!==0)throw Error(stderr.trim());assert.equal(stderr,'');return JSON.parse(stdout);
}

async function fixture(work){
 const target=new URL(database);
 assert.ok(['postgres:','postgresql:'].includes(target.protocol)&&['127.0.0.1','localhost','[::1]'].includes(target.hostname)&&target.pathname.endsWith('_test')&&!target.search);
 const admin=new pg.Pool({connectionString:database,max:1}),name=`activation_${randomUUID().replaceAll('-','')}_test`;
 const directory=await realpath(await mkdtemp(join(tmpdir(),'activation-failure-')));
 let pool,created=false;
 try{
  assert.match((await admin.query('SHOW server_version')).rows[0].server_version,/^16\./);
  await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created=true;target.pathname='/'+name;
  pool=new pg.Pool({connectionString:target.href,max:3});
  await applyMigrations(pool,fileURLToPath(new URL('../migrations/',import.meta.url)),{info(){}});
  const f=await seedMigration(pool),ordinary=await seedMigration(pool),store=new VaultMigrationStore(pool,f.config);
  const vaultName='TEST-ONLY-CODEX-failure-vault';
  await pool.query('UPDATE shared_vaults SET name=$2 WHERE id=$1',[f.input.vaultID,vaultName]);
  const preview=await store.preview(f.input),document=legacy([record('host',{title:'failure injection fixture'})]);
  const scope={...f.scope,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
  const inventory=await prepareMigrationInventory({...f,scope,document,persistCheckpoint:async()=>{}});
  const started=await store.start({...f.input,resources:inventory.resources});
  const out=await prepareLegacyMigration({...f,scope:started.scope,document,policy:started.policy,checkpoint:inventory.checkpoint,
   recipientTargets:(r,p)=>started.recipients[r.id][p],persistCheckpoint:async()=>{},
   readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:[f.deviceID],custodianTargets:[f.recipient],
    verifyIdentityReservations:resources=>store.verifyIdentityReservations({...f.input,resources})}});
  for(const object of out.objects)await store.putPart(f.input,object);
  await store.putReaderProjection(f.input,out.readerProjection,out.administrativeSidecar);
  await store.validate(f.input,out.manifest);
  const manifestHash=await store.manifestHash(f.input),fencePath=join(directory,'journal');
  await writeFile(fencePath,'',{mode:0o600});
  const fence=new MigrationFence(fencePath),controllerIdentity={sourceSHA:'a'.repeat(40),imageDigest:'sha256:'+'b'.repeat(64),controllerDigest:'c'.repeat(64)};
  const backupPath=join(directory,'backup.dump'),attestationPath=join(directory,'restore.json'),policyPath=join(directory,'policy.json'),controllerIdentityPath=join(directory,'identity.json');
  // Synthetic protected evidence exercises the actual guard; this is not an actual restore claim.
  const backup=Buffer.from('nonempty synthetic local-only backup fixture'),sha256=createHash('sha256').update(backup).digest('hex');
  await writeFile(backupPath,backup,{mode:0o600});
  await writeFile(attestationPath,JSON.stringify({formatVersion:1,isolatedRestoreVerified:true,backupSHA256:sha256,controllerIdentity}),{mode:0o600});
  const policy={formatVersion:1,environment:'staging',runID:'failure',namePrefix:'TEST-ONLY-CODEX-failure',vaults:[{teamID:f.input.teamID,vaultID:f.input.vaultID,name:vaultName}],
   confirmation:{attemptID:f.input.attemptID,manifestHash},oldClientGateEnabled:true,controllerIdentity,backup:{path:backupPath,sha256,restoreAttestationPath:attestationPath}};
  await writeFile(policyPath,JSON.stringify(policy),{mode:0o600});
  await writeFile(controllerIdentityPath,JSON.stringify(controllerIdentity),{mode:0o600});
  const socket=createServer();await new Promise(resolve=>socket.listen(0,'127.0.0.1',resolve));const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
  const config={port,environment:'staging',enabled:true,allowedVaultIDs:[f.input.vaultID],databaseURL:target.href,fencePath,policyPath,controllerIdentityPath};
  const request={operation:'activate',input:f.input,manifestHash};
  const state=async()=>({vault:(await pool.query('SELECT * FROM shared_vaults WHERE id=$1',[f.input.vaultID])).rows[0],
   attempts:(await pool.query('SELECT * FROM vault_migration_attempts WHERE vault_id=$1 ORDER BY id',[f.input.vaultID])).rows,
   projections:(await pool.query('SELECT * FROM vault_publication_projections WHERE vault_id=$1 ORDER BY attempt_id',[f.input.vaultID])).rows,
   ordinary:(await pool.query('SELECT * FROM shared_vaults WHERE id=$1',[ordinary.input.vaultID])).rows[0]});
  const baseline=await state();
  await work({pool,f,config,request,fence,state,baseline,policy,backupPath});
  assert.deepEqual((await state()).ordinary,baseline.ordinary,'ordinary baseline must stay unchanged');
 }finally{try{await pool?.end();if(created)await admin.query(`DROP DATABASE "${name}"`);}finally{await admin.end();await rm(directory,{recursive:true,force:true});}}
}

function server(config){
 const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),env:{
  PATH:process.env.PATH,DATABASE_URL:config.databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(config.port),CLOUD_PUBLIC_ORIGIN:'http://127.0.0.1:'+config.port,
  SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),
  TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_FENCE_PATH:config.fencePath,
 }});
 let output='';child.stdout.on('data',bytes=>output+=bytes);child.stderr.on('data',bytes=>output+=bytes);
 return {child,origin:'http://127.0.0.1:'+config.port,exit:once(child,'exit'),output:()=>output};
}
async function readyServer(config){
 const running=server(config);
 try{for(let n=0;n<100;n++){
  if(running.child.exitCode!==null)throw Error('server_start_failed: '+running.output());
  try{if((await fetch(running.origin+'/readyz')).status===200)return running;}catch{}
  await new Promise(resolve=>setTimeout(resolve,20));
 }throw Error('server_start_timeout');}catch(error){running.child.kill();await running.exit;throw error;}
}

test('before_commit operator option proves real rollback, no pointer, and retry on the same signed generation',options,()=>fixture(async f=>{
 await assert.rejects(invoke(f.config,f.request,'before_commit'),/migration_activation_fault_before_commit/);
 assert.deepEqual(await f.state(),f.baseline);
 const records=await f.fence.readRecords();assert.deepEqual(records.map(event=>event.type),['PENDING_INTENT','PROVEN_ABORT']);
 assert.equal(records[0].vaults[0].generationID,f.f.input.attemptID);assert.equal((await f.fence.snapshot()).pending.length,0);
 await runStagingMigration(f.config,f.request);
 const committed=await f.state();assert.equal(committed.vault.format_state,'V2_ACTIVE');assert.equal(committed.vault.active_publication_attempt_id,f.f.input.attemptID);
 assert.equal(committed.attempts.length,1);assert.equal(committed.projections.length,1);
 const journal=await readFile(f.config.fencePath);await runStagingMigration(f.config,f.request);
 assert.deepEqual(await f.state(),committed);assert.deepEqual(await readFile(f.config.fencePath),journal);
}));

test('after_commit operator option leaves pending actual commit, denies HTTP reads/startup, then immutable reconciliation recovers once',options,()=>fixture(async f=>{
 await assert.rejects(invoke(f.config,f.request,'before_commit'),/migration_activation_fault_before_commit/);
 assert.deepEqual(await f.state(),f.baseline);
 const running=await readyServer(f.config);
 try{
  await assert.rejects(invoke(f.config,f.request,'after_commit'),/migration_activation_fault_after_commit/);
  const committed=await f.state();assert.equal(committed.vault.format_state,'V2_ACTIVE');assert.equal(committed.attempts[0].state,'V2_ACTIVE');
  assert.equal(committed.vault.active_publication_attempt_id,f.f.input.attemptID);assert.equal(committed.attempts.length,1);assert.equal(committed.projections.length,1);
  assert.deepEqual((await f.fence.readRecords()).map(event=>event.type),['PENDING_INTENT','PROVEN_ABORT','PENDING_INTENT']);
  const pending=(await f.fence.snapshot()).pending[0],journal=await readFile(f.config.fencePath);
  for(const path of ['/v1/meta',`/v1/teams/${f.f.input.teamID}/vaults/${f.f.input.vaultID}/publication/header`]){
   const denied=await fetch(running.origin+path);assert.equal(denied.status,503);assert.equal((await denied.json()).error,'publication_guard_unavailable');
  }
  await invoke(f.config,f.request);assert.deepEqual(await f.state(),committed);assert.deepEqual(await readFile(f.config.fencePath),journal);
  await assert.rejects(verifyDeploymentCompatibility({query:(sql,values)=>f.pool.query(sql,values),fence:f.fence,candidate:currentCapabilities}),/deployment_fence_pending/);
  running.child.kill();await running.exit;
  const restart=server(f.config);const [code]=await restart.exit;assert.equal(code,1);assert.match(restart.output(),/Deployment compatibility preflight failed/);
  assert.deepEqual(await readFile(f.config.fencePath),journal);
  const reconcile={operation:'reconcile-fence',intentID:pending.intentID};
  assert.deepEqual(await runStagingMigration(f.config,reconcile),{status:'confirmed',intentID:pending.intentID});
  const confirmed=await readFile(f.config.fencePath);assert.deepEqual((await f.fence.readRecords()).map(event=>event.type),['PENDING_INTENT','PROVEN_ABORT','PENDING_INTENT','CONFIRMED_COMMIT']);
  await runStagingMigration(f.config,reconcile);await runStagingMigration(f.config,f.request);
  assert.deepEqual(await readFile(f.config.fencePath),confirmed);assert.deepEqual(await f.state(),committed);
  const recovered=await readyServer(f.config);recovered.child.kill();await recovered.exit;
 }finally{if(running.child.exitCode===null){running.child.kill();await running.exit;}}
}));

test('fault option rejects unknown/extra/nonactivate/nonstaging input and preserves every guard before any activation effects',options,()=>fixture(async f=>{
 const pristine=await readFile(f.config.fencePath);
 for(const [config,request,option,want] of [
  [f.config,f.request,{activationFault:'active_pointer'},/invalid_migration_activation_fault/],
  [f.config,f.request,Object.create({activationFault:'active_pointer'}),/invalid_migration_activation_fault/],
  [f.config,f.request,{activationFault:undefined},/invalid_migration_activation_fault/],
  [f.config,f.request,{activationFault:'before_commit',other:true},/invalid_migration_activation_fault/],
  [f.config,{operation:'preview',input:f.f.input},{activationFault:'before_commit'},/invalid_migration_activation_fault/],
  [{...f.config,environment:'production'},f.request,{activationFault:'before_commit'},/migration_staging_only/],
  [f.config,{...f.request,activationFault:'before_commit'},{},/invalid_migration_operation/],
  [{...f.config,allowedVaultIDs:[]},f.request,{activationFault:'before_commit'},/migration_staging_only/],
  [{...f.config,policyPath:null},f.request,{activationFault:'before_commit'},/staging_activation_policy_required/],
 ])await assert.rejects(runStagingMigration(config,request,option),want);
 assert.deepEqual(await f.state(),f.baseline);assert.deepEqual(await readFile(f.config.fencePath),pristine);
 // Exercise independent guard regressions, resetting only our synthetic fixture each time.
 const originalPolicy=structuredClone(f.policy),backup=await readFile(f.backupPath),identity=await readFile(f.config.controllerIdentityPath);
 for(const change of [
  async()=>{f.policy.confirmation.manifestHash='f'.repeat(64);await writeFile(f.config.policyPath,JSON.stringify(f.policy));},
  async()=>{f.policy.oldClientGateEnabled=false;await writeFile(f.config.policyPath,JSON.stringify(f.policy));},
  async()=>{await writeFile(f.config.controllerIdentityPath,JSON.stringify({...f.policy.controllerIdentity,sourceSHA:'f'.repeat(40)}));},
  async()=>{await writeFile(f.backupPath,'corrupted backup');},
  async()=>{await f.pool.query("UPDATE shared_vaults SET name='ordinary' WHERE id=$1",[f.f.input.vaultID]);},
 ]){
  f.policy=structuredClone(originalPolicy);await writeFile(f.config.policyPath,JSON.stringify(f.policy));
  await writeFile(f.backupPath,backup);await writeFile(f.config.controllerIdentityPath,identity);
  await f.pool.query('UPDATE shared_vaults SET name=$2 WHERE id=$1',[f.f.input.vaultID,originalPolicy.vaults[0].name]);
  await change();await assert.rejects(invoke(f.config,f.request,'before_commit'),/staging_activation_/);
  const current=await f.state();assert.equal(current.vault.active_publication_attempt_id,null);assert.equal(current.attempts[0].state,'V2_READY');
  assert.deepEqual(await readFile(f.config.fencePath),pristine);
 }
}));
