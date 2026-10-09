import test from 'node:test';import {tmpdir} from 'node:os';import {mkdtemp as makeTemp,realpath,rm} from 'node:fs/promises';import {join as pathJoin} from 'node:path';import {fileURLToPath} from 'node:url';
const temporary=[];async function temp(prefix){const dir=await realpath(await makeTemp(pathJoin(tmpdir(),prefix)));temporary.push(dir);return dir;}test.after(async()=>{await Promise.all(temporary.map(dir=>rm(dir,{recursive:true,force:true})));});
import assert from 'node:assert/strict';
import {validateEnrollment,scopedEnvironment,publicationEnvironment} from '../scripts/staging-migration-operator-helper.mjs';
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
