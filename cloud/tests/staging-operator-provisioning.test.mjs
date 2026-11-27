import test from 'node:test';import {tmpdir} from 'node:os';import {lstat,mkdir,mkdtemp as makeTemp,realpath,rm,rmdir} from 'node:fs/promises';import {join as pathJoin} from 'node:path';import {fileURLToPath} from 'node:url';
const temporary=[];async function temp(prefix){const dir=await realpath(await makeTemp(pathJoin(tmpdir(),prefix)));temporary.push(dir);return dir;}test.after(async()=>{await Promise.all(temporary.map(dir=>rm(dir,{recursive:true,force:true})));});
import assert from 'node:assert/strict';
import {validateEnrollment,scopedEnvironment,publicationEnvironment} from '../scripts/staging-migration-operator-helper.mjs';
import * as operator from '../scripts/staging-migration-operator-helper.mjs';
import {createHash} from 'node:crypto';
const id=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0');
const scope={teamID:id(1),vaultID:id(2),actorUserID:id(3),actorDeviceID:id(4),name:'TEST-ONLY-CODEX-run-1-vault',attemptID:null};
const baseline={scope:{shared:[],users:[],teams:[],personal:[]}};
const row={id:scope.vaultID,team_id:scope.teamID,name:scope.name,user_id:scope.actorUserID,device_id:scope.actorDeviceID,email:'one@example.test',format_state:'V1_ACTIVE'};
test('enrollment excludes every baseline ID including test looking names and validates DB tuple',()=>{
 assert.deepEqual(validateEnrollment(scope,'run-1',baseline,row,['one@example.test','two@example.test']),scope);
 for(const [kind,key] of [['shared','vaultID'],['users','actorUserID'],['teams','teamID']])assert.throws(()=>validateEnrollment(scope,'run-1',{scope:{...baseline.scope,[kind]:[scope[key]]}},row,['one@example.test','two@example.test']));
 for(const patch of [{name:'TEST-ONLY-CODEX-other'},{email:'ordinary@example.test'},{device_id:id(9)},{team_id:id(9)}])assert.throws(()=>validateEnrollment(scope,'run-1',baseline,{...row,...patch},['one@example.test','two@example.test']));
});
test('scoped enable changes exactly reviewed flags and two canonical emails',()=>{
 const before='DATABASE_URL=postgres://secret\nALLOW_REGISTRATION=false\nPUBLICATION_ENVIRONMENT=staging\nPUBLICATION_READER_ENABLED=false\nWHOLE_PUBLICATION_ENABLED=false\n';
 const after=scopedEnvironment(before,['one@example.test','two@example.test']);assert.match(after,/DATABASE_URL=postgres:\/\/secret\n/);assert.match(after,/WHOLE_PUBLICATION_ENABLED=false/);const published=publicationEnvironment(after.replace('ALLOW_REGISTRATION=true','ALLOW_REGISTRATION=false'),[id(2)],{cursorSecret:'a'.repeat(64),previewSecret:'b'.repeat(64)});assert.match(published,/WHOLE_PUBLICATION_ENABLED=true/);assert.match(published,new RegExp('PUBLICATION_ALLOWED_VAULT_IDS='+id(2)));
 for(const emails of [[],['one@example.test'],['One@example.test','two@example.test'],['one@example.test','one@example.test']])assert.throws(()=>scopedEnvironment(before,emails));
 assert.throws(()=>scopedEnvironment(before.replace('ALLOW_REGISTRATION=false','ALLOW_REGISTRATION=true'),['one@example.test','two@example.test']));
});

test('public V1 emergency closure only flips registration and updates the exact pinned override',()=>{
 assert.equal(typeof operator.disablePublicRegistration,'function');
 const path='/var/lib/selective-remote-controller/operator/registration-compose.json';
 const before='DATABASE_URL=postgres://synthetic\nALLOW_REGISTRATION=true\nNODE_ENV=production\nPUBLICATION_ENVIRONMENT=production\nPUBLICATION_READER_ENABLED=false\nWHOLE_PUBLICATION_ENABLED=false\n';
 const content=JSON.stringify({services:{cloud:{environment:{ALLOW_REGISTRATION:'true'}}}}),hash=x=>createHash('sha256').update(x).digest('hex');
 const settings={registrationMode:'production-v1',composeFiles:[{path,sha256:hash(content)}]};
 const result=operator.disablePublicRegistration(before,settings,content);
 assert.equal(result.nextEnv,before.replace('ALLOW_REGISTRATION=true','ALLOW_REGISTRATION=false'));
 assert.deepEqual(JSON.parse(result.pendingCompose.content),{services:{cloud:{environment:{ALLOW_REGISTRATION:'false'}}}});
 assert.equal(result.pendingCompose.path,path);assert.equal(result.nextSettings.composeFiles[0].sha256,hash(result.pendingCompose.content));
 for(const [env,s,override] of [
  [before.replace('ALLOW_REGISTRATION=true','ALLOW_REGISTRATION=false'),settings,content],
  [before+'ALLOW_REGISTRATION=true\n',settings,content],
  [before.replace('WHOLE_PUBLICATION_ENABLED=false','WHOLE_PUBLICATION_ENABLED=true'),settings,content],
  [before.replace('PUBLICATION_READER_ENABLED=false\n',''),settings,content],
  [before+'STAGING_REGISTRATION_EMAIL_ALLOWLIST=one@example.test,two@example.test\n',settings,content],
  [before,{...settings,registrationMode:'staging'},content],
  [before,settings,content+' '],
  [before,{...settings,composeFiles:[]},content],
 ])assert.throws(()=>operator.disablePublicRegistration(env,s,override));
});

test('public V1 controller mode refuses every staging migration and provisioning operation',()=>{
 assert.equal(typeof operator.assertOperatorMode,'function');
 const prod={registrationMode:'production-v1'};
 assert.doesNotThrow(()=>operator.assertOperatorMode(prod,['--disable-public-registration']));
 for(const args of [[],['--enable-publication'],['--enable-scoped'],['--enroll'],['--activation-fault','after_commit'],['--disable-registration']])assert.throws(()=>operator.assertOperatorMode(prod,args),/environment/);
 assert.doesNotThrow(()=>operator.assertOperatorMode({},['--enable-scoped']));
 assert.throws(()=>operator.assertOperatorMode({},['--disable-public-registration']),/environment/);
});

test('public V1 emergency config closes actual registration service before database work',async()=>{
 const {loadConfig}=await import('../src/config.mjs'),{CloudService}=await import('../src/service.mjs');
 const env={NODE_ENV:'production',CLOUD_PUBLIC_ORIGIN:'https://cloud.example.test',DATABASE_URL:'postgres://example.invalid/selective_remote',SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),SMTP_HOST:'smtp.example.test',SMTP_PORT:'465',SMTP_SECURE:'true',SMTP_USER:'test',SMTP_PASSWORD:'z'.repeat(32),SMTP_FROM:'sender@example.test',PUBLICATION_ENVIRONMENT:'production',ALLOW_REGISTRATION:'true',PUBLICATION_READER_ENABLED:'false',WHOLE_PUBLICATION_ENABLED:'false'};
 const before=Object.entries(env).map(([k,v])=>k+'='+v).join('\n')+'\n',path='/var/lib/selective-remote-controller/operator/registration-compose.json';
 const content=JSON.stringify({services:{cloud:{environment:{ALLOW_REGISTRATION:'true'}}}}),settings={registrationMode:'production-v1',composeFiles:[{path,sha256:createHash('sha256').update(content).digest('hex')}]};
 const {nextEnv}=operator.disablePublicRegistration(before,settings,content),after=Object.fromEntries(nextEnv.trimEnd().split('\n').map(line=>{const i=line.indexOf('=');return [line.slice(0,i),line.slice(i+1)];}));
 assert.equal(loadConfig(env).allowRegistration,true);const config=loadConfig(after);assert.equal(config.allowRegistration,false);
 const service=new CloudService(new Proxy({},{get(){throw Error('unexpected_store_work');}}),config);
 await assert.rejects(service.register({email:'synthetic@example.test'}),/registration_disabled/);
});

test('scoped transition loads real config and service rejects unlisted registration before any work',async()=>{
 const {loadConfig}=await import('../src/config.mjs'),{CloudService}=await import('../src/service.mjs');
 const env={DATABASE_URL:'postgres://example.invalid/selective_remote',SESSION_TOKEN_PEPPER:'s'.repeat(32),EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),SMTP_HOST:'smtp.example.test',SMTP_PORT:'465',SMTP_SECURE:'true',SMTP_USER:'test',SMTP_PASSWORD:'z'.repeat(32),SMTP_FROM:'sender@example.test',PUBLICATION_ENVIRONMENT:'staging',ALLOW_REGISTRATION:'false',PUBLICATION_READER_ENABLED:'false',WHOLE_PUBLICATION_ENABLED:'false'};
 const text=Object.entries(env).map(([k,v])=>k+'='+v).join('\n')+'\n';
 const enabled=scopedEnvironment(text,['one@example.test','two@example.test']),actual=Object.fromEntries(enabled.trimEnd().split('\n').map(line=>{const i=line.indexOf('=');return [line.slice(0,i),line.slice(i+1)];})),config=loadConfig(actual);
 assert.equal(config.allowRegistration,true);assert.deepEqual(config.registrationEmailAllowlist,['one@example.test','two@example.test']);
 const service=new CloudService(new Proxy({},{get(){throw Error('unexpected_store_work');}}),config);
 await assert.rejects(service.register({email:'ordinary@example.test'}),/registration_disabled/);
 await assert.rejects(service.register({email:'one@example.test'}),/smtp_not_configured/);
 const closed=loadConfig({...actual,ALLOW_REGISTRATION:'false'}),disabled=new CloudService({},closed);
 await assert.rejects(disabled.register({email:'one@example.test'}),/registration_disabled/);
});

test('reviewed registration override preserves final PostgreSQL bind profile',async()=>{
 const {mkdtemp,writeFile}=await import('node:fs/promises'),{spawnSync}=await import('node:child_process'),{join,resolve}=await import('node:path');
 const directory=await temp('staging-compose-'),override=join(directory,'registration.json');
 await writeFile(override,JSON.stringify({services:{cloud:{environment:{ALLOW_REGISTRATION:'true'}}}}),{mode:0o600});
 const result=spawnSync(process.execPath,[fileURLToPath(new URL('../scripts/validate-postgres-bind-source.mjs',import.meta.url)),fileURLToPath(new URL('../compose.yaml',import.meta.url)),fileURLToPath(new URL('../compose.small-host.yaml',import.meta.url)),override,fileURLToPath(new URL('../compose.postgres-bind.yaml',import.meta.url))],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
});

test('actual file adapter pins scoped config before guarded restart and closes on failure or unrelated env edits',async()=>{
 const {applyReviewedConfiguration}=await import('../scripts/staging-migration-operator-helper.mjs'),{mkdtemp,writeFile,readFile}=await import('node:fs/promises'),{resolve,join}=await import('node:path'),{createHash}=await import('node:crypto');
 const hash=x=>createHash('sha256').update(x).digest('hex');
 const directory=await temp('staging-reconfigure-'),envPath=join(directory,'effective.env'),settingsPath=join(directory,'settings.json');
 const before='DATABASE_URL=postgres://unchanged\nALLOW_REGISTRATION=false\nPUBLICATION_ENVIRONMENT=staging\nPUBLICATION_READER_ENABLED=false\nWHOLE_PUBLICATION_ENABLED=false\n',settings={envPath,envDigest:hash(before)};
 const reset=async()=>{await writeFile(envPath,before);await writeFile(settingsPath,JSON.stringify(settings));};await reset();
 const nextEnv=scopedEnvironment(before,['one@example.test','two@example.test']),stages=[];
 const run=async(file,args)=>{if(args[0]==='stop'){stages.push('closed');return {};}if(args[0]==='inspect')return {stdout:'false\n'};stages.push('guarded-restart');const current=JSON.parse(await readFile(settingsPath));assert.equal(current.envDigest,hash(await readFile(envPath)));assert.equal((await readFile(envPath)).toString(),nextEnv);return {};};
 await applyReviewedConfiguration({settings,nextSettings:settings,nextEnv,settingsPath,read:path=>readFile(path),run});assert.deepEqual(stages,['closed','guarded-restart']);
 await reset();const failures=[];await assert.rejects(applyReviewedConfiguration({settings,nextSettings:settings,nextEnv,settingsPath,read:path=>readFile(path),run:async(file,args)=>{if(file==='/bin/bash')throw Error('guard_denied');if(args[0]==='stop')failures.push('closed');return {stdout:'false\n'};}}),/guard_denied/);assert.deepEqual(failures,['closed','closed']);
 await reset();await writeFile(envPath,before+'UNREVIEWED=value\n');let dispatched=false;await assert.rejects(applyReviewedConfiguration({settings,nextSettings:settings,nextEnv,settingsPath,read:path=>readFile(path),run:async()=>{dispatched=true;}}),/environment/);assert.equal(dispatched,false);
});

test('Team recovery selects the protected staging identity, anchor and a stopped deployment',async()=>{
 const identity={sourceSHA:'a'.repeat(40),imageDigest:'sha256:'+'b'.repeat(64),controllerDigest:'c'.repeat(64)};
 const settings={version:1,...identity,network:'cloud_private',teamSafetyStopVersion:1,
  fencePath:'/var/lib/selective-remote-controller/publication/journal',envPath:'/protected/staging.env',
  anchorProtocol:1,anchorDeploymentID:id(501)};
 const request={operation:'reconcile-team-authorization',intentID:id(502)};
 const response={status:'confirmed',intentID:request.intentID};
 const context={version:1,runID:'run-1',controllerIdentity:identity,
  activationPolicyPath:'/var/lib/selective-remote-controller/operator/run-1-activation-policy.json',
  allowedOperations:['reconcile-fence'],scopes:[scope]};
 assert.throws(()=>operator.validateOperatorRequest(context,request,identity),/staging_operator_request/);
 const containerID='e'.repeat(64),postgresID='f'.repeat(64);
 const network={Name:'cloud_private',Labels:{'com.docker.compose.project':'cloud','com.docker.compose.network':'private'}};
 const postgres={State:{Running:true},Config:{Labels:{'com.docker.compose.project':'cloud','com.docker.compose.service':'postgres'}},
  NetworkSettings:{Networks:{cloud_private:{}}}};
 const runFor=({cloudRunning=false,caddyRunning=false,cloudImage=identity.imageDigest,sourceSHA=identity.sourceSHA,
  receipt=response,unexpectedContainer,cleanupFails=false}={})=>{
  const calls=[];let input;
  return {calls,input:()=>input,run(command,args){
   calls.push({command,args});
   if(args[0]==='image')return Promise.resolve({stdout:JSON.stringify({
    Id:identity.imageDigest,Config:{Labels:{'org.opencontainers.image.revision':sourceSHA}},
   })});
   if(args[0]==='inspect'&&args[1]==='--format')return Promise.resolve({stdout:args.at(-1)==='cloud-cloud-1'
    ? [cloudRunning,cloudImage].join(' ') : String(caddyRunning)});
   if(args[0]==='network')return Promise.resolve({stdout:JSON.stringify(network)});
   if(args[0]==='ps')return Promise.resolve({stdout:postgresID+(unexpectedContainer?'\n'+'1'.repeat(64):'')});
   if(args[0]==='inspect')return Promise.resolve({stdout:JSON.stringify(unexpectedContainer?[postgres,unexpectedContainer]:[postgres])});
   if(args[0]==='create')return Promise.resolve({stdout:containerID});
   if(args[0]==='rm'){
    assert.deepEqual(args,['rm','--force',containerID]);
    if(cleanupFails)return Promise.reject(Error('synthetic_cleanup_failed'));
    return Promise.resolve({stdout:containerID});
   }
   assert.deepEqual(args,['start','--attach','--interactive',containerID]);
   const child=Promise.resolve({stdout:JSON.stringify(receipt)});
   child.child={stdin:{on(){},end(data){input=JSON.parse(data);}}};return child;
  }};
 };
 for(const patch of [{version:2},{registrationMode:'production-v1'},{anchorProtocol:undefined},{anchorDeploymentID:'wrong'},
  {teamSafetyStopVersion:undefined},{network:'host'},{fencePath:'/tmp/other'}]){
  const mock=runFor();
  await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
   settings:{...settings,...patch},identity,request,run:mock.run,
  }),/staging_operator_team_recovery_scope/);
  assert.equal(mock.calls.length,0);
 }
 for(const badRequest of [{...request,confirmed:true},{...request,operation:'reconcile-fence'}]){
  const mock=runFor();
  await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
   settings,identity,request:badRequest,run:mock.run,
  }),/staging_operator_team_recovery_scope/);
  assert.equal(mock.calls.length,0);
 }
 for(const condition of [{cloudRunning:true},{caddyRunning:true},{cloudImage:'sha256:'+'d'.repeat(64)}]){
  const mock=runFor(condition);
  await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
   settings,identity,request,run:mock.run,
  }),/staging_operator_team_recovery_traffic/);
  assert.ok(mock.calls.every(call=>['image','inspect'].includes(call.args[0])));
 }
 const wrongImage=runFor({sourceSHA:'d'.repeat(40)});
 await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
  settings,identity,request,run:wrongImage.run,
 }),/staging_operator_identity/);
 assert.equal(wrongImage.calls.length,1);
 const foreign=runFor({unexpectedContainer:{...postgres,Config:{Labels:{}}}});
 await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
  settings,identity,request,run:foreign.run,
 }),/deployment_project_mismatch/);
 assert.ok(!foreign.calls.some(call=>call.args[0]==='create'));
 const extraCloud=runFor({unexpectedContainer:{...postgres,Config:{Labels:{
  'com.docker.compose.project':'cloud','com.docker.compose.service':'cloud',
 }}}});
 await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
  settings,identity,request,run:extraCloud.run,
 }),/staging_operator_team_recovery_traffic/);
 assert.ok(!extraCloud.calls.some(call=>call.args[0]==='create'));
 const mock=runFor();
 assert.deepEqual(await operator.runTeamAuthorizationRecoveryContainer({settings,identity,request,run:mock.run}),response);
 const invocation=mock.calls.find(call=>call.args[0]==='create');
 assert.equal(invocation.command,'/usr/bin/docker');
 assert.ok(invocation.args.includes('--pull=never')&&invocation.args.includes(identity.imageDigest));
 assert.ok(invocation.args.includes('type=bind,src=/var/lib/selective-remote-controller/publication,dst=/publication-fence'));
 assert.ok(invocation.args.includes('type=bind,src=/var/lib/selective-remote-controller/operator,dst=/var/lib/selective-remote-controller/operator,readonly'));
 assert.equal(invocation.args.at(-2),'/app/scripts/staging-team-authorization-recovery.mjs');
 assert.deepEqual(JSON.parse(invocation.args.at(-1)),{identity,
  identityPath:'/var/lib/selective-remote-controller/operator/controller-identity.json',
  anchorDeploymentID:settings.anchorDeploymentID,fencePath:'/publication-fence/journal'});
 assert.deepEqual(mock.input(),request);
 assert.deepEqual(mock.calls.at(-1).args,['rm','--force',containerID]);
 const wrong=runFor({receipt:{...response,intentID:id(503)}});
 await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
  settings,identity,request,run:wrong.run,
 }),/staging_operator_team_recovery_receipt/);
 const unfinished=runFor({cleanupFails:true});
 await assert.rejects(()=>operator.runTeamAuthorizationRecoveryContainer({
  settings,identity,request,run:unfinished.run,
 }),/staging_operator_team_recovery_cleanup/);
});

test('Team recovery holds both existing operator locks and retains them when child cleanup is uncertain',async()=>{
 const state=await temp('sr-team-recovery-locks-');
 const operatorDirectory=pathJoin(state,'operator');
 await mkdir(operatorDirectory,{mode:0o700});
 const controllerLock=pathJoin(state,'controller.lock'),contextLock=pathJoin(operatorDirectory,'operator-context.json.lock');
 const unexpected=()=>assert.fail('recovery ran without exclusive controller access');
 await mkdir(controllerLock,{mode:0o700});
 await assert.rejects(()=>operator.withTeamAuthorizationRecoveryLocks(unexpected,state),/staging_operator_controller_locked/);
 await assert.rejects(lstat(contextLock),{code:'ENOENT'});
 await rmdir(controllerLock);
 await mkdir(contextLock,{mode:0o700});
 await assert.rejects(()=>operator.withTeamAuthorizationRecoveryLocks(unexpected,state),/staging_operator_context_locked/);
 await assert.rejects(lstat(controllerLock),{code:'ENOENT'});
 await rmdir(contextLock);
 assert.equal(await operator.withTeamAuthorizationRecoveryLocks(async()=>{
  assert.ok((await lstat(controllerLock)).isDirectory()&&(await lstat(contextLock)).isDirectory());
  return 'received';
 },state),'received');
 await assert.rejects(lstat(controllerLock),{code:'ENOENT'});
 await assert.rejects(lstat(contextLock),{code:'ENOENT'});
 await assert.rejects(()=>operator.withTeamAuthorizationRecoveryLocks(
  async()=>{throw Error('staging_operator_team_recovery_cleanup');},state,
 ),/staging_operator_team_recovery_cleanup/);
 assert.ok((await lstat(controllerLock)).isDirectory()&&(await lstat(contextLock)).isDirectory());
});
