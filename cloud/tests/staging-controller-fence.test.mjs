import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';

test('checkout launcher delegates only to the retained controller',async()=>{
  const script=await readFile(new URL('../scripts/start-staging-guarded.sh',import.meta.url),'utf8');
  assert.match(script,/exec \/opt\/selective-remote-controller\/scripts\/staging-controller\.sh/);
  assert.doesNotMatch(script,/exec "\$\{compose\[@\]\}" up/);
});

import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,mkdir,copyFile,rm} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import pg from 'pg';
import {verifyControllerFixture,validateControllerSettings,validateCandidateIdentity,validateControllerCompose,validateControllerProject} from '../scripts/verify-staging-controller.mjs';
import {verifyDeploymentCompatibility,currentCapabilities} from '../src/deployment-compatibility.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {applyMigrations,loadMigrations} from '../src/migrations.mjs';
import {seedPublishedTeam,storeFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
const execute=promisify(execFile),database=process.env.TEST_DATABASE_URL;
const migrations=fileURLToPath(new URL('../migrations/',import.meta.url));
const settings=()=>({version:1,sourceSHA:'a'.repeat(40),imageDigest:'sha256:'+'b'.repeat(64),controllerDigest:'c'.repeat(64),
 cloudDirectory:'/opt/selective-remote/cloud',envPath:'/opt/selective-remote/cloud/.env',envDigest:'d'.repeat(64),network:'cloud_private',
 fencePath:'/var/lib/selective-remote-controller/publication/journal',backupDirectory:'/var/backups/selective-remote',
 composeFiles:[{path:'/opt/selective-remote/cloud/compose.yaml',sha256:'e'.repeat(64)},{path:'/opt/selective-remote/cloud/compose.publication-fence.yaml',sha256:'170dd70074fb4735fc15b17d1609101cb283961fb2b1bdbe1d83a16c7b8d9576'}],
 storage:{POSTGRES_DATA_MOUNT_ROOT:'/mnt/pg',POSTGRES_DATA_HOST_PATH:'/mnt/pg/data',POSTGRES_DATA_EXPECTED_SOURCE:'/dev/pg',POSTGRES_DATA_EXPECTED_FSTYPE:'ext4',POSTGRES_DATA_UID:'70',POSTGRES_DATA_GID:'70'}});
const imageEnvironment=['NODE_ENV=production','PATH=/usr/local/bin:/usr/bin:/bin'];
const dockerEnvironment=[...imageEnvironment,'DATABASE_URL=postgres://synthetic@postgres/checked','SESSION_TOKEN_PEPPER=synthetic-protected-value'];
const environmentEvidence={imageEnvironment,dockerEnvironment,envFiles:[{path:'/opt/selective-remote/cloud/.env',required:true}]};
function compose(s){return {name:'cloud',networks:{private:{name:s.network}},services:{
 cloud:{image:s.imageDigest,pull_policy:'never',environment:{DATABASE_URL:'postgres://synthetic@postgres/checked',SESSION_TOKEN_PEPPER:'synthetic-protected-value',PUBLICATION_FENCE_PATH:'/publication-fence/journal',ALLOW_REGISTRATION:'false'},restart:'on-failure:3',networks:{private:{}},volumes:[{type:'bind',source:'/var/lib/selective-remote-controller/publication',target:'/publication-fence',bind:{create_host_path:false}}]},
 postgres:{restart:'on-failure:3',networks:{private:{}},volumes:[{type:'bind',source:'/mnt/pg/data',target:'/var/lib/postgresql/data',bind:{create_host_path:false}}]},
 caddy:{restart:'on-failure:3',networks:{private:{}}},
}};}
async function fixtureController({query,fence,metadata=currentCapabilities,maintenance=false,command=async()=>{}}){
 const stages=[],queries=[];
 const promise=verifyControllerFixture({candidate:settings(),maintenance,runCommand:async event=>{
  stages.push(event.stage);await command(event);if(event.stage==='candidate-metadata')return metadata;
  if(event.stage==='check')return verifyDeploymentCompatibility({candidate:event.metadata,mode:event.mode,fence,query:(sql,values)=>{queries.push(sql);return query(sql,values);}});
 }});return {promise,stages,queries};
}
const emptyFence={snapshot:async()=>({schemaFloor:19,pending:[],committed:[],outcomes:[]}),verifySchemaFloor:async()=>true,verify:async()=>true};
const emptyDB=async sql=>({rows:sql.includes('schema_migrations')?[{version:'22'}]:[]});
test('protected identity/settings and rendered mounts reject alternate images, independent-history loss and startup overrides',()=>{
 const s=settings();assert.equal(validateControllerSettings(s),s);validateCandidateIdentity(s,{Id:s.imageDigest,Config:{Labels:{'org.opencontainers.image.revision':s.sourceSHA}}});
 for(const image of [{Id:'sha256:'+'f'.repeat(64)},{Id:s.imageDigest,Config:{Labels:{'org.opencontainers.image.revision':'f'.repeat(40)}}}])assert.throws(()=>validateCandidateIdentity(s,image),/deployment_candidate_digest/);
 for(const change of [{backupDirectory:'/var/lib'},{fencePath:'/opt/selective-remote/fence'},{imageDigest:'latest'},{controllerDigest:'bad'},{sourceSHA:'main'},{composeFiles:[s.composeFiles[0],s.composeFiles[0]]}])assert.throws(()=>validateControllerSettings({...s,...change}));
 validateControllerCompose(compose(s),s,environmentEvidence);
 for(const mutate of [m=>m.services.cloud.command=['node','old-server'],m=>m.services.cloud.image='old:latest',m=>m.services.cloud.volumes[0].source='/mnt/pg/data',m=>m.services.cloud.volumes[0].bind.create_host_path=true,m=>m.services.cloud.ports=['8080:8080'],m=>m.services.cloud.restart='always',m=>m.services.cloud.networks={other:{}},m=>m.services.postgres.volumes[0].source='/var/lib/selective-remote-controller/publication',m=>m.services.cloud.privileged=true]){const m=compose(s);mutate(m);assert.throws(()=>validateControllerCompose(m,s,environmentEvidence));}
});
test('old image metadata denies before checker, migration, or traffic commands',async()=>{
 for(const metadata of [null,{}, {...currentCapabilities,fenceVersion:1},{...currentCapabilities,maxSchemaVersion:19}]){
  const f=await fixtureController({query:emptyDB,fence:emptyFence,metadata});await assert.rejects(f.promise,/deployment_code_floor/);
  assert.deepEqual(f.stages,['attest','candidate-metadata']);assert.deepEqual(f.queries,[]);
 }
});
test('ordinary old-schema startup never queries publications, migrates or starts services',async()=>{
 const f=await fixtureController({query:async()=>({rows:[{version:'12'}]}),fence:emptyFence});await assert.rejects(f.promise,/deployment_schema_floor/);
 assert.equal(f.queries.length,1);assert.match(f.queries[0],/schema_migrations/);assert.ok(!f.stages.includes('migrate'));assert.ok(!f.stages.includes('open-traffic'));
});
test('explicit initial maintenance closes traffic before schema12 check and repeats check after migrations',async()=>{
 let schema='12';const f=await fixtureController({maintenance:true,fence:emptyFence,query:async sql=>({rows:sql.includes('schema_migrations')?[{version:schema}]:[]}),command:async e=>{if(e.stage==='migrate')schema='22';}});
 await f.promise;assert.deepEqual(f.stages,['attest','candidate-metadata','storage','assert-project','close-traffic','assert-closed','check','migrate','check','attest','open-traffic']);
 assert.equal(f.queries.filter(sql=>sql.includes('vault_migration_attempts')).length,1);
});
test('failure to close traffic, second attestation or post-migration pending prevents any up command',async()=>{
 for(const point of ['assert-closed','post-pending','second-attest']){
  let checked=0,attested=0;const fence={...emptyFence,snapshot:async()=>({...await emptyFence.snapshot(),pending:point==='post-pending'&&checked>=3?[{}]:[]})};
  const f=await fixtureController({query:emptyDB,fence,command:async e=>{if(e.stage==='check')checked++;if(e.stage==='attest')attested++;if(e.stage===point||point==='second-attest'&&e.stage==='attest'&&attested===2)throw Error('synthetic_denial');}});
  await assert.rejects(f.promise);assert.ok(!f.stages.includes('open-traffic'));
 }
});
async function withDatabases(work){
 const base=new URL(database);assert.ok(['127.0.0.1','localhost','[::1]'].includes(base.hostname));
 const admin=new pg.Pool({connectionString:database,max:1}),created=[],pools=[],directory=await mkdtemp(join(tmpdir(),'prc-controller-restore-'));
 const make=async()=>{const name='prc_ctrl_'+randomUUID().replaceAll('-','');await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created.push(name);const url=new URL(base);url.pathname='/'+name;const pool=new pg.Pool({connectionString:url.href,max:4});pools.push(pool);return {pool,url};};
 const pgEnv=url=>({...process.env,PGHOST:url.hostname,PGPORT:url.port,PGUSER:decodeURIComponent(url.username),PGPASSWORD:decodeURIComponent(url.password),PGDATABASE:url.pathname.slice(1)});
 const dump=async(url,file)=>execute(process.env.PG_DUMP_PATH??'pg_dump',['--format=custom','--file',file],{env:pgEnv(url),maxBuffer:1024*1024});
 const restore=async file=>{const target=await make();await execute(process.env.PG_RESTORE_PATH??'pg_restore',['--exit-on-error','--dbname',target.url.pathname.slice(1),file],{env:pgEnv(target.url),maxBuffer:1024*1024});return target;};
 try{assert.match((await admin.query('SHOW server_version')).rows[0].server_version,/^16\./);await work({make,dump,restore,directory});}
 finally{try{await Promise.all(pools.map(pool=>pool.end()));for(const name of created)await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`);}finally{await admin.end();await rm(directory,{recursive:true,force:true});}}
}
async function checkerCLI(databaseURL,fencePath,maintenance=false){
 const candidateFile=join(dirname(fencePath),'candidate-'+randomUUID()+'.json');
 await writeFile(candidateFile,JSON.stringify(currentCapabilities),{mode:0o600});
 const env={...process.env,DATABASE_URL:databaseURL,PUBLICATION_FENCE_PATH:fencePath,
  SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),
  TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),
  PUBLICATION_READER_ENABLED:'false',WHOLE_PUBLICATION_ENABLED:'false'};
 try{
  const result=await execute(process.execPath,[fileURLToPath(new URL('../scripts/check-deployment-compatibility.mjs',import.meta.url)),
   '--candidate',candidateFile,...(maintenance?['--maintenance-upgrade']:[])],{env,timeout:15000,maxBuffer:65536});
  return {status:0,...result};
 }catch(error){return {status:error.code,stdout:error.stdout,stderr:error.stderr};}
 finally{await rm(candidateFile);}
}
async function denyActual(pool,fencePath,errorCode,{maintenance=false,publicationQueries}={}){
 const before=await readFile(fencePath),beforeVaults=(await pool.query('SELECT to_jsonb(v) AS row FROM shared_vaults v ORDER BY id')).rows;
 const cli=await checkerCLI(pool.options.connectionString,fencePath,maintenance);assert.equal(cli.status,1);assert.equal(cli.stderr.trim(),errorCode);assert.equal(cli.stdout,'');
 const f=await fixtureController({query:(sql,values)=>pool.query(sql,values),fence:new MigrationFence(fencePath),maintenance});await assert.rejects(f.promise,error=>error.message===errorCode);
 assert.ok(!f.stages.includes('migrate'));assert.ok(!f.stages.includes('open-traffic'));
 if(publicationQueries!==undefined)assert.equal(f.queries.filter(sql=>sql.includes('vault_migration_attempts')).length,publicationQueries);
 assert.deepEqual(await readFile(fencePath),before);assert.deepEqual((await pool.query('SELECT to_jsonb(v) AS row FROM shared_vaults v ORDER BY id')).rows,beforeVaults);return f;
}
async function successor(pool,f,fence,request){const store=storeFor(pool,f,{fence}),preview=await store.preview(f.input,request),out=await prepareWholeFixture(f,preview);await uploadWholeFixture(store,f,preview,out);return store.commit(f.input,request.operationID,preview.token,request);}
test('actual PG16 dump/restore of schema12 and missing-Vault schema22 are denied by the newer external journal',
 {skip:!database,timeout:120000},()=>withDatabases(async({make,dump,restore,directory})=>{
  const source=await make(),prefix=join(directory,'migrations');await mkdir(prefix);
  for(const m of (await loadMigrations(migrations)).filter(m=>m.version<=12))await copyFile(join(migrations,m.name),join(prefix,m.name));
  await applyMigrations(source.pool,prefix,{info(){}});const old=join(directory,'schema12.dump');await dump(source.url,old);
  await applyMigrations(source.pool,migrations,{info(){}});const ordinary=await seedMigration(source.pool);
  await source.pool.query("UPDATE shared_vaults SET name='ORDINARY-SYNTHETIC-UNCHANGED' WHERE id=$1",[ordinary.input.vaultID]);
  const empty=join(directory,'empty22.dump');await dump(source.url,empty);
  const path=join(directory,'retained.fence');await writeFile(path,'',{mode:0o600});const fence=new MigrationFence(path);
  const {f,request}=await seedPublishedTeam(source.pool,2,{fence});await successor(source.pool,f,fence,request);
  const older=await restore(old);await denyActual(older.pool,path,'deployment_schema_floor',{publicationQueries:0});await denyActual(older.pool,path,'deployment_schema_floor',{maintenance:true,publicationQueries:0});
  const missing=await restore(empty);await denyActual(missing.pool,path,'deployment_fence_mismatch',{publicationQueries:1});
 }));
test('actual PG16 predecessor restore and independently committed same-sequence fork cannot serve the retained successor',
 {skip:!database,timeout:120000},()=>withDatabases(async({make,dump,restore,directory})=>{
  const source=await make();await applyMigrations(source.pool,migrations,{info(){}});const path=join(directory,'retained.fence');await writeFile(path,'',{mode:0o600});const fence=new MigrationFence(path);
  const {f,request}=await seedPublishedTeam(source.pool,2,{fence}),previousBytes=await readFile(path),backup=join(directory,'predecessor.dump');await dump(source.url,backup);
  const receipt=await successor(source.pool,f,fence,request),older=await restore(backup);await denyActual(older.pool,path,'deployment_fence_mismatch',{publicationQueries:1});
  const branch=await restore(backup),branchPath=join(directory,'fork-only.fence');await writeFile(branchPath,previousBytes,{mode:0o600});
  const forkReceipt=await successor(branch.pool,f,new MigrationFence(branchPath),{...request,operationID:randomUUID()});
  assert.deepEqual(forkReceipt.vaults.map(v=>v.sequence),receipt.vaults.map(v=>v.sequence));assert.notDeepEqual(forkReceipt.vaults.map(v=>v.headerHash),receipt.vaults.map(v=>v.headerHash));
  await denyActual(branch.pool,path,'deployment_fence_mismatch',{publicationQueries:1});
  const good=await fixtureController({query:(sql,values)=>source.pool.query(sql,values),fence});await good.promise;assert.ok(good.stages.includes('open-traffic'));
 }));
test('actual PG16 missing active pointer remains visible and denies even with an empty retained journal',
 {skip:!database,timeout:120000},()=>withDatabases(async({make,directory})=>{
  const {pool}=await make();await applyMigrations(pool,migrations,{info(){}});const f=await seedMigration(pool);
  await pool.query("UPDATE shared_vaults SET revision=0,format_state='V2_ACTIVE',format_schema_version=2,envelope_version=NULL,ciphertext=NULL,nonce=NULL,auth_tag=NULL,content_hash=NULL,updated_by_device_id=NULL WHERE id=$1",[f.input.vaultID]);
  const path=join(directory,'empty.fence');await writeFile(path,'',{mode:0o600});await denyActual(pool,path,'deployment_fence_mismatch',{publicationQueries:1});
 }));
test('missing/corrupt journal and complete unresolved multi-Vault intent deny before database access',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'prc-controller-negative-'));
 try{const path=join(directory,'journal');for(const bytes of [null,'not-json\n']){if(bytes!==null)await writeFile(path,bytes,{mode:0o600});const f=await fixtureController({query:emptyDB,fence:new MigrationFence(path)});await assert.rejects(f.promise);assert.equal(f.queries.length,0);assert.ok(!f.stages.includes('migrate'));assert.ok(!f.stages.includes('open-traffic'));}
  await writeFile(path,'',{mode:0o600});const fence=new MigrationFence(path),teamID=randomUUID();
  await fence.append({version:2,type:'PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),kind:'PUBLICATION',schemaFloor:22,vaults:[1,2].map(()=>({teamID,vaultID:randomUUID(),generationID:randomUUID(),sequence:2,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)}))});
  const before=await readFile(path),f=await fixtureController({query:emptyDB,fence});await assert.rejects(f.promise,/deployment_fence_pending/);assert.equal(f.queries.length,0);assert.ok(!f.stages.includes('open-traffic'));assert.deepEqual(await readFile(path),before);
 }finally{await rm(directory,{recursive:true,force:true});}
});


test('review regression: changed effective DB or security env never reaches migration/up',async()=>{
 for(const [key,value] of [['DATABASE_URL','postgres://synthetic@postgres/unchecked'],['SESSION_TOKEN_PEPPER','different'],['UNREVIEWED_ENV','new']]){
  const s=settings(),model=compose(s);model.services.cloud.environment[key]=value;
  const f=await fixtureController({query:emptyDB,fence:emptyFence,command:async e=>{
   if(e.stage==='storage')validateControllerCompose(model,s,environmentEvidence);
  }});
  await assert.rejects(f.promise,/deployment_environment_mismatch/);assert.ok(!f.stages.includes('migrate'));assert.ok(!f.stages.includes('open-traffic'));
 }
});
test('review regression: another Compose project is rejected and existing old project must be checked',async()=>{
 const s=settings(),model=compose(s);model.name='drifted-project';
 assert.throws(()=>validateControllerCompose(model,s,environmentEvidence),/deployment_project_mismatch/);
 const f=await fixtureController({query:emptyDB,fence:emptyFence,command:async e=>{if(e.stage==='assert-project')throw Error('deployment_project_mismatch');}});
 await assert.rejects(f.promise,/deployment_project_mismatch/);assert.ok(!f.stages.includes('migrate'));assert.ok(!f.stages.includes('open-traffic'));
});
test('review regression: normalized bind omission is valid, true or unknown bind options remain denied',()=>{
 const s=settings(),model=compose(s);model.services.cloud.volumes[0].bind={};model.services.postgres.volumes[0].bind={};
 assert.doesNotThrow(()=>validateControllerCompose(model,s,environmentEvidence));
 for(const name of ['cloud','postgres'])for(const bind of [null,undefined,{create_host_path:true},{propagation:'rshared'}]){
  const changed=structuredClone(model);changed.services[name].volumes[0].bind=bind;
  assert.throws(()=>validateControllerCompose(changed,s,environmentEvidence));
 }
});

test('observed old project or public listener cannot survive a newly selected project closure',()=>{
 const network={Name:'cloud_private',Labels:{'com.docker.compose.project':'cloud','com.docker.compose.network':'private'}};
 const container=(service,project='cloud',net='cloud_private',ports={})=>({State:{Running:true},Config:{Labels:{'com.docker.compose.project':project,'com.docker.compose.service':service}},NetworkSettings:{Networks:{[net]:{}},Ports:ports}});
 const pg=container('postgres'),cloud=container('cloud'),caddy=container('caddy','cloud','cloud_private',{'443/tcp':[{HostPort:'443'}]});
 validateControllerProject(network,[pg,cloud,caddy]);validateControllerProject(network,[pg]);
 for(const containers of [[pg,container('cloud','old-project')],[pg,container('caddy','old-project','old_private',{'443/tcp':[{HostPort:'443'}]})],
  [pg,container('cloud','cloud','different_private')],[pg,cloud,{...cloud}],[pg,container('cloud','cloud','cloud_private',{'8080/tcp':[{HostPort:'443'}]})],[]])
  assert.throws(()=>validateControllerProject(network,containers),/deployment_project_mismatch/);
 assert.throws(()=>validateControllerProject({...network,Labels:{}},[pg]),/deployment_project_mismatch/);
});
test('effective environment preserves image defaults, binds secrets and allows only exact protected staging registration scope',()=>{
 const s=settings(),model=compose(s),effective=validateControllerCompose(model,s,environmentEvidence);
 assert.equal(effective.NODE_ENV,'production');assert.equal(effective.DATABASE_URL,'postgres://synthetic@postgres/checked');
 for(const value of ['bad\nvalue','bad\rvalue','bad\0value']){
  const m=compose(s);m.services.cloud.environment.SESSION_TOKEN_PEPPER=value;
  assert.throws(()=>validateControllerCompose(m,s,environmentEvidence),/deployment_environment_mismatch/);
 }
 const registration={...environmentEvidence,dockerEnvironment:[...dockerEnvironment,'ALLOW_REGISTRATION=true','PUBLICATION_ENVIRONMENT=staging','STAGING_REGISTRATION_EMAIL_ALLOWLIST=one@example.test,two@example.test']};
 const scoped=compose(s);Object.assign(scoped.services.cloud.environment,{ALLOW_REGISTRATION:'true',PUBLICATION_ENVIRONMENT:'staging',STAGING_REGISTRATION_EMAIL_ALLOWLIST:'one@example.test,two@example.test'});
 assert.equal(validateControllerCompose(scoped,s,registration).ALLOW_REGISTRATION,'true');
 scoped.services.cloud.environment.ALLOW_REGISTRATION='false';assert.equal(validateControllerCompose(scoped,s,registration).ALLOW_REGISTRATION,'false');
 for(const list of ['', 'one@example.test','One@example.test,two@example.test','one@example.test,one@example.test']){
  const bad=structuredClone(scoped);bad.services.cloud.environment.ALLOW_REGISTRATION='true';bad.services.cloud.environment.STAGING_REGISTRATION_EMAIL_ALLOWLIST=list;
  const badEvidence={...registration,dockerEnvironment:[...dockerEnvironment,'ALLOW_REGISTRATION=true','PUBLICATION_ENVIRONMENT=staging','STAGING_REGISTRATION_EMAIL_ALLOWLIST='+list]};
  assert.throws(()=>validateControllerCompose(bad,s,badEvidence),/deployment_registration_scope/);
 }
 const broaden=compose(s);broaden.services.cloud.environment.ALLOW_REGISTRATION='true';
 assert.throws(()=>validateControllerCompose(broaden,s,environmentEvidence),/deployment_environment_mismatch/);
});

test('additional env-file dependencies are rejected even when their present values match',()=>{
 const s=settings(),model=compose(s);
 for(const envFiles of [undefined,[],[{path:s.envPath,required:true},{path:'/opt/unpinned.env',required:true}], [{path:s.envPath,format:'raw'}]])
  assert.throws(()=>validateControllerCompose(model,s,{...environmentEvidence,envFiles}),/deployment_environment_mismatch/);
});
