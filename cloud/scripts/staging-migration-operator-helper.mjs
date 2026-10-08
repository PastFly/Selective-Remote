import {readFile,lstat,realpath,mkdir,mkdtemp,writeFile,rename,open,rm} from 'node:fs/promises';
import {createHash,randomBytes} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const execute=promisify(execFile),root='/opt/selective-remote-controller',operator='/var/lib/selective-remote-controller/operator';
const fenceDirectory='/var/lib/selective-remote-controller/publication';
const operations=['preview','start','upload','upload-reader','verify-identities','validate','discard','activate','check-compatibility','reconcile-fence'];
const fail=code=>{throw Error('staging_operator_'+code);};
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const validIdentity=value=>object(value)&&/^[a-f0-9]{40}$/.test(value.sourceSHA)&&/^sha256:[a-f0-9]{64}$/.test(value.imageDigest)&&/^[a-f0-9]{64}$/.test(value.controllerDigest);
const sameIdentity=(a,b)=>validIdentity(a)&&validIdentity(b)&&['sourceSHA','imageDigest','controllerDigest'].every(key=>a[key]===b[key]);
function validateContext(context,identity){
 if(!object(context)||context.version!==1||!sameIdentity(context.controllerIdentity,identity)||!/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(context.runID)
  ||context.activationPolicyPath!==operator+'/'+context.runID+'-activation-policy.json'
  ||!Array.isArray(context.allowedOperations)||!context.allowedOperations.length||new Set(context.allowedOperations).size!==context.allowedOperations.length||context.allowedOperations.some(op=>!operations.includes(op))
  ||!Array.isArray(context.scopes)||!context.scopes.length||context.scopes.length>10||new Set(context.scopes.map(scope=>scope?.vaultID)).size!==context.scopes.length)fail('context');
 for(const scope of context.scopes)if(!object(scope)||['teamID','vaultID','actorUserID','actorDeviceID'].some(key=>!uuid(scope[key]))
  ||scope.attemptID!==null&&!uuid(scope.attemptID)||typeof scope.name!=='string'||!scope.name.startsWith('TEST-ONLY-CODEX-'+context.runID+'-')||scope.name.length>120)fail('context');
 return context;
}
export function validateOperatorRequest(context,request,identity){
 validateContext(context,identity);
 if(!object(request)||!context.allowedOperations.includes(request.operation)||Object.keys(request).some(key=>!['operation','input','object','projection','sidecar','checkpoint','manifest','manifestHash','intentID'].includes(key)))fail('request');
 if(request.operation==='check-compatibility'){
  if(Object.keys(request).length!==1)fail('request');return structuredClone(request);
 }
 if(request.operation==='reconcile-fence'){
  if(Object.keys(request).sort().join(',')!=='intentID,operation'||typeof request.intentID!=='string'||!(uuid(request.intentID)||/^legacy:[a-f0-9]{64}$/.test(request.intentID)))fail('request');return structuredClone(request);
 }
 const input=request.input;if(!object(input))fail('scope');
 const scope=context.scopes.find(scope=>['teamID','vaultID','actorUserID','actorDeviceID'].every(key=>input[key]===scope[key]));
 if(!scope)fail('scope');
 if(scope.attemptID===null){if(request.operation!=='preview'||input.attemptID!=null)fail('scope');}
 else if(input.attemptID!==scope.attemptID)fail('scope');
 return structuredClone(request);
}
export function bindOperatorAttempt(context,update,identity){
 validateContext(context,identity);
 if(!object(update)||!object(update.scope)||!uuid(update.attemptID))fail('scope');
 const scope=context.scopes.find(scope=>['teamID','vaultID','actorUserID','actorDeviceID','name'].every(key=>update.scope[key]===scope[key]));
 if(!scope||scope.attemptID!==update.expectedAttemptID)fail('scope');
 const copy=structuredClone(context);copy.scopes.find(entry=>entry.vaultID===scope.vaultID).attemptID=update.attemptID;return copy;
}
async function protectedBytes(path,privateParent=true){
 if(await realpath(path)!==path)fail('permissions');const st=await lstat(path),parent=await lstat(dirname(path));
 if(!st.isFile()||st.uid!==0||(st.mode&0o777)!==0o600||parent.uid!==0||(privateParent?(parent.mode&0o777)!==0o700:(parent.mode&0o022)!==0))fail('permissions');return readFile(path);
}
async function input(){const chunks=[];let size=0;for await(const chunk of process.stdin){size+=chunk.length;if(size>96*1024*1024)fail('input_limit');chunks.push(chunk);}try{return JSON.parse(Buffer.concat(chunks));}catch{fail('request');}}
function canonicalEmails(emails){
 if(!Array.isArray(emails)||emails.length!==2||new Set(emails).size!==2||emails.some(email=>typeof email!=='string'||email!==email.toLowerCase()||!/^[-a-z0-9._+]+@[-a-z0-9.]+\.[a-z]{2,}$/.test(email)))fail('emails');return emails;
}
export function scopedEnvironment(bytes,emails){
 canonicalEmails(emails);const entries=bytes.trimEnd().split('\n'),env={};
 for(const entry of entries){const pos=entry.indexOf('=');if(pos<1||/[\r\0]/.test(entry)||Object.hasOwn(env,entry.slice(0,pos)))fail('environment');env[entry.slice(0,pos)]=entry.slice(pos+1);}
 if(env.PUBLICATION_ENVIRONMENT!=='staging'||['ALLOW_REGISTRATION','PUBLICATION_READER_ENABLED','WHOLE_PUBLICATION_ENABLED'].some(k=>env[k]!=='false')||Object.hasOwn(env,'STAGING_REGISTRATION_EMAIL_ALLOWLIST'))fail('environment');
 env.ALLOW_REGISTRATION='true';env.STAGING_REGISTRATION_EMAIL_ALLOWLIST=emails.join(',');return Object.entries(env).map(([k,v])=>k+'='+v).join('\n')+'\n';
}
export function validateEnrollment(scope,runID,baseline,row,emails){
 canonicalEmails(emails);
 if(!/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/.test(runID)||!object(scope)||Object.keys(scope).sort().join(',')!=='actorDeviceID,actorUserID,attemptID,name,teamID,vaultID'
  ||['teamID','vaultID','actorUserID','actorDeviceID'].some(k=>!uuid(scope[k]))||scope.attemptID!==null
  ||typeof scope.name!=='string'||!scope.name.startsWith('TEST-ONLY-CODEX-'+runID+'-')||scope.name.length>120
  ||!object(baseline?.scope)||[['shared','vaultID'],['users','actorUserID'],['teams','teamID']].some(([kind,key])=>!Array.isArray(baseline.scope[kind])||baseline.scope[kind].includes(scope[key]))
  ||!row||row.id!==scope.vaultID||row.team_id!==scope.teamID||row.name!==scope.name||row.user_id!==scope.actorUserID||row.device_id!==scope.actorDeviceID||!emails.includes(row.email)||row.format_state!=='V1_ACTIVE')fail('enrollment');
 return structuredClone(scope);
}
export function publicationEnvironment(bytes,vaultIDs,{cursorSecret,previewSecret}){
 if(!Array.isArray(vaultIDs)||!vaultIDs.length||vaultIDs.some(id=>!uuid(id))||new Set(vaultIDs).size!==vaultIDs.length||![cursorSecret,previewSecret].every(s=>typeof s==='string'&&/^[a-f0-9]{64}$/.test(s))||cursorSecret===previewSecret)fail('environment');
 const env=Object.fromEntries(bytes.trimEnd().split('\n').map(line=>{const i=line.indexOf('=');return [line.slice(0,i),line.slice(i+1)];}));
 if(env.ALLOW_REGISTRATION!=='false'||env.PUBLICATION_ENVIRONMENT!=='staging'||env.PUBLICATION_READER_ENABLED!=='false'||env.WHOLE_PUBLICATION_ENABLED!=='false')fail('environment');
 for(const key of ['PUBLICATION_READER_ENABLED','WHOLE_PUBLICATION_ENABLED'])env[key]='true';
 Object.assign(env,{PUBLICATION_ALLOWED_VAULT_IDS:vaultIDs.join(','),PUBLICATION_CURSOR_SECRET:cursorSecret,WHOLE_PUBLICATION_PREVIEW_SECRET:previewSecret});
 return Object.entries(env).map(([k,v])=>k+'='+v).join('\n')+'\n';
}
async function replaceProtected(path,value){
 const next=path+'.next',file=await open(next,'wx',0o600);
 try{await file.writeFile(typeof value==='string'?value:JSON.stringify(value));await file.sync();}finally{await file.close();}
 await rename(next,path);const directory=await open(dirname(path),'r');try{await directory.sync();}finally{await directory.close();}
}
async function backupEvidence(settings,identity){
 const base=settings.backupDirectory,proof=JSON.parse(await protectedBytes(base+'/backup-proof.json')),attestation=JSON.parse(await protectedBytes(base+'/restore-attestation.json'));
 if(proof.verified!==true||proof.baselineVerified!==true||!sameIdentity(proof.identity,identity)||proof.backupSHA256!==digest(await protectedBytes(base+'/backup.dump'))
  ||proof.baselineSHA256!==digest(await protectedBytes(base+'/ordinary.json'))||attestation.isolatedRestoreVerified!==true||attestation.backupSHA256!==proof.backupSHA256||!sameIdentity(attestation.controllerIdentity,identity))fail('backup');
 return {baseline:JSON.parse(await protectedBytes(base+'/ordinary.json')),backup:{path:base+'/backup.dump',sha256:proof.backupSHA256,restoreAttestationPath:base+'/restore-attestation.json'}};
}
// Only the root-only host path calls this transport. SQL is fixed here and the
// request supplies bounded UUID values, never SQL, command or environment text.
export async function queryPublicScope(query,s){
 if(s.registrationEmails){const r=await query('SELECT id,email FROM users WHERE email=ANY($1::text[])',[s.registrationEmails]);return {users:r.rows};}
 const result=await query("SELECT v.id,v.team_id,v.name,v.format_state,u.id AS user_id,u.email,d.id AS device_id FROM shared_vaults v JOIN team_memberships m ON m.team_id=v.team_id AND m.user_id=$3 AND m.revoked_at IS NULL JOIN users u ON u.id=m.user_id JOIN devices d ON d.user_id=u.id AND d.id=$4 AND d.revoked_at IS NULL WHERE v.id=$1 AND v.team_id=$2",[s.vaultID,s.teamID,s.actorUserID,s.actorDeviceID]);
 if(result.rows.length!==1)throw Error('staging_operator_database_scope');
 let attempt=null;if(s.attemptID){const a=await query('SELECT id,team_id,vault_id,actor_user_id,actor_device_id,state,manifest_hash FROM vault_migration_attempts WHERE id=$1',[s.attemptID]);if(a.rows.length!==1)throw Error('staging_operator_database_scope');attempt=a.rows[0];}
 return {row:result.rows[0],attempt};
}
async function publicScopeRow(settings,identity,scope,attemptID=null){
 const code="import pg from 'pg';const queryPublicScope="+queryPublicScope.toString()+";let input='';for await(const c of process.stdin)input+=c;const db=new pg.Client({connectionString:process.env.DATABASE_URL});try{await db.connect();process.stdout.write(JSON.stringify(await queryPublicScope((sql,values)=>db.query(sql,values),JSON.parse(input))));}catch{process.exitCode=1;}finally{await db.end();}";
 const result=execute('/usr/bin/docker',['run','--rm','-i','--pull=never','--network','cloud_private','--read-only','--user','0:0','--cap-drop','ALL','--security-opt','no-new-privileges','--env-file',settings.envPath,'--entrypoint','node',identity.imageDigest,'--input-type=module','-e',code],{encoding:'utf8',timeout:30000,maxBuffer:65536});
 result.child.stdin.on('error',()=>{});result.child.stdin.end(JSON.stringify({...scope,attemptID}));try{return JSON.parse((await result).stdout);}catch{fail('database_scope');}
}
export async function applyReviewedConfiguration({settings,nextSettings,nextEnv,pendingCompose,run=execute,read=protectedBytes,settingsPath=root+'/settings.json'}){
 if(digest(await read(settings.envPath,false))!==settings.envDigest||JSON.stringify(JSON.parse(await read(settingsPath)))!==JSON.stringify(settings))fail('environment');
 let closed=false;try{
  closed=true;await run('/usr/bin/docker',['stop','cloud-cloud-1','cloud-caddy-1']);
  for(const c of ['cloud-cloud-1','cloud-caddy-1'])if((await run('/usr/bin/docker',['inspect','--format','{{.State.Running}}',c],{encoding:'utf8'})).stdout.trim()!=='false')fail('traffic');
  if(pendingCompose)await replaceProtected(pendingCompose.path,pendingCompose.content);
  await replaceProtected(settings.envPath,nextEnv);await replaceProtected(settingsPath,{...nextSettings,envDigest:digest(nextEnv)});
  await run('/bin/bash',[root+'/scripts/staging-controller.sh'],{timeout:600000,maxBuffer:1024*1024});
 }catch(error){if(closed)await run('/usr/bin/docker',['stop','cloud-cloud-1','cloud-caddy-1']).catch(()=>{});throw error;}
}
async function provision(args,request,settings,identity){
 const lock=operator+'/operator-context.json.lock';try{await mkdir(lock,{mode:0o700});}catch{fail('context_locked');}
 try{
  if(digest(await protectedBytes(settings.envPath,false))!==settings.envDigest)fail('environment');
  await execute('/usr/bin/sha256sum',['--strict','--status','-c','bundle.sha256'],{cwd:root});
  const current=JSON.parse(await protectedBytes(root+'/settings.json'));if(JSON.stringify(current)!==JSON.stringify(settings))fail('identity');
  const image=JSON.parse((await execute('/usr/bin/docker',['image','inspect','--format','{{json .}}',identity.imageDigest],{encoding:'utf8'})).stdout);
  const source=(await execute('/usr/bin/git',['-C','/opt/selective-remote','rev-parse','HEAD'],{encoding:'utf8'})).stdout.trim();
  if(source!==identity.sourceSHA||image.Id!==identity.imageDigest||image.Config?.Labels?.['org.opencontainers.image.revision']!==source)fail('identity');
  const evidence=await backupEvidence(settings,identity),path=operator+'/operator-context.json';
  if(['--enable-scoped','--enable-publication','--disable-registration'].includes(args[0])){
   if(args.length!==1)fail('request');
   const before=(await protectedBytes(settings.envPath,false)).toString();let nextEnv,pendingCompose,nextSettings={...settings};
   if(args[0]==='--enable-scoped'){
    if(Object.keys(request).join(',')!=='emails')fail('request');nextEnv=scopedEnvironment(before,request.emails);nextSettings.testEmails=canonicalEmails(request.emails);const override=operator+'/registration-compose.json',content=JSON.stringify({services:{cloud:{environment:{ALLOW_REGISTRATION:'true'}}}});pendingCompose={path:override,content};nextSettings.composeFiles=[...settings.composeFiles.slice(0,-1),{path:override,sha256:digest(content)},settings.composeFiles.at(-1)];const {users}=await publicScopeRow(settings,identity,{registrationEmails:request.emails});if(users.length)fail('emails_existing');
   }else if(args[0]==='--disable-registration'){
    if(Object.keys(request).length)fail('request');canonicalEmails(settings.testEmails);const {users}=await publicScopeRow(settings,identity,{registrationEmails:settings.testEmails});if(users.length!==2||users.some(u=>evidence.baseline.scope.users.includes(u.id)))fail('registration_incomplete');
    if(!before.includes('\nALLOW_REGISTRATION=true\n'))fail('environment');nextEnv=before.replace('\nALLOW_REGISTRATION=true\n','\nALLOW_REGISTRATION=false\n');const override=operator+'/registration-compose.json',content=JSON.stringify({services:{cloud:{environment:{ALLOW_REGISTRATION:'false'}}}});if(settings.composeFiles.filter(f=>f.path===override).length!==1)fail('environment');pendingCompose={path:override,content};nextSettings.composeFiles=settings.composeFiles.map(f=>f.path===override?{path:override,sha256:digest(content)}:f);
   }else{
    if(Object.keys(request).join(',')!=='vaultIDs')fail('request');const context=JSON.parse(await protectedBytes(path));validateContext(context,identity);
    if(!Array.isArray(request.vaultIDs)||JSON.stringify([...request.vaultIDs].sort())!==JSON.stringify(context.scopes.map(s=>s.vaultID).sort()))fail('scope');
    for(const scope of context.scopes){const {row}=await publicScopeRow(settings,identity,scope);validateEnrollment({...scope,attemptID:null},context.runID,evidence.baseline,row,settings.testEmails);}
    nextEnv=publicationEnvironment(before,request.vaultIDs,{cursorSecret:randomBytes(32).toString('hex'),previewSecret:randomBytes(32).toString('hex')});
   }
   await applyReviewedConfiguration({settings,nextSettings,nextEnv,pendingCompose});
   process.stdout.write(JSON.stringify({[args[0]==='--enable-scoped'?'scopedEnabled':args[0]==='--enable-publication'?'publicationEnabled':'registrationDisabled']:true})+'\n');return;
  }
  canonicalEmails(settings.testEmails);
  if(args[0]==='--enroll'){
   if(args.length!==1||Object.keys(request).sort().join(',')!=='runID,scope')fail('request');
   const {row}=await publicScopeRow(settings,identity,request.scope);const scope=validateEnrollment(request.scope,request.runID,evidence.baseline,row,settings.testEmails);
   let context;try{context=JSON.parse(await protectedBytes(path));}catch(error){if(error.code!=='ENOENT')throw error;}
   if(context){validateContext(context,identity);if(context.runID!==request.runID||context.scopes.some(s=>s.vaultID===scope.vaultID))fail('context');context={...context,scopes:[...context.scopes,scope]};}
   else context={version:1,runID:request.runID,controllerIdentity:identity,activationPolicyPath:operator+'/'+request.runID+'-activation-policy.json',allowedOperations:operations,scopes:[scope]};
   validateContext(context,identity);await replaceProtected(path,context);process.stdout.write('{"scopeEnrolled":true}\n');return;
  }
  if(args[0]==='--bind-attempt'){
   if(args.length!==1)fail('arguments');const context=JSON.parse(await protectedBytes(path));const next=bindOperatorAttempt(context,request,identity);const scope=next.scopes.find(s=>s.vaultID===request.scope.vaultID);const {row}=await publicScopeRow(settings,identity,scope);validateEnrollment({...scope,attemptID:null},context.runID,evidence.baseline,row,settings.testEmails);await replaceProtected(path,next);process.stdout.write('{"attemptBound":true}\n');return;
  }
  if(args[0]==='--confirm'){
   if(args.length!==3||!uuid(args[1])||!/^[a-f0-9]{64}$/.test(args[2])||Object.keys(request).sort().join(',')!=='expectedAttemptID,scope')fail('confirmation');
   const context=JSON.parse(await protectedBytes(path));validateContext(context,identity);
   const scope=context.scopes.find(s=>['teamID','vaultID','actorUserID','actorDeviceID','name'].every(k=>s[k]===request.scope[k]));
   if(!scope||scope.attemptID!==request.expectedAttemptID)fail('scope');
   const {row,attempt}=await publicScopeRow(settings,identity,scope,args[1]);validateEnrollment({...scope,attemptID:null},context.runID,evidence.baseline,row,settings.testEmails);
   if(!attempt||attempt.id!==args[1]||attempt.manifest_hash!==args[2]||attempt.state!=='V2_READY'||[['team_id','teamID'],['vault_id','vaultID'],['actor_user_id','actorUserID'],['actor_device_id','actorDeviceID']].some(([key,k])=>attempt[key]!==scope[k]))fail('confirmation');
   const next=bindOperatorAttempt(context,{scope,attemptID:args[1],expectedAttemptID:request.expectedAttemptID},identity);
   const policy={formatVersion:1,environment:'staging',runID:context.runID,namePrefix:'TEST-ONLY-CODEX-'+context.runID,oldClientGateEnabled:true,controllerIdentity:identity,vaults:[{teamID:scope.teamID,vaultID:scope.vaultID,name:scope.name}],confirmation:{attemptID:args[1],manifestHash:args[2]},backup:evidence.backup};
   await replaceProtected(path,next);await replaceProtected(context.activationPolicyPath,policy);process.stdout.write('{"policyConfirmed":true}\n');return;
  }
  fail('arguments');
 }finally{await rm(lock,{recursive:true});}
}

async function main(){
 if(process.getuid?.()!==0||resolve(dirname(fileURLToPath(import.meta.url)),'..')!==root)fail('owner');
 const args=process.argv.slice(2);if(args.length&&!['--bind-attempt','--enroll','--confirm','--enable-scoped','--enable-publication','--disable-registration'].includes(args[0]))fail('arguments');
 const settings=JSON.parse(await protectedBytes(root+'/settings.json')),identity=JSON.parse(await protectedBytes(operator+'/controller-identity.json'));
 if(!sameIdentity(settings,identity)||digest(await readFile(root+'/bundle.sha256'))!==identity.controllerDigest)fail('identity');
 const request=await input();
 if(['--bind-attempt','--enroll','--confirm','--enable-scoped','--enable-publication','--disable-registration'].includes(args[0]))return provision(args,request,settings,identity);
 const contextPath=operator+'/operator-context.json',context=JSON.parse(await protectedBytes(contextPath));
 validateContext(context,identity);
 const scoped=validateOperatorRequest(context,request,identity);
 if(digest(await protectedBytes(settings.envPath,false))!==settings.envDigest)fail('environment');
 if(request.operation==='activate')await protectedBytes(context.activationPolicyPath);
 const image=JSON.parse((await execute('/usr/bin/docker',['image','inspect','--format','{{json .}}',identity.imageDigest],{encoding:'utf8',maxBuffer:4*1024*1024})).stdout);
 if(image.Id!==identity.imageDigest||image.Config?.Labels?.['org.opencontainers.image.revision']!==identity.sourceSHA)fail('identity');
 const temp=await mkdtemp(operator+'/request-');
 try{
  const envFile=join(temp,'operator.env');await writeFile(envFile,[
   'MIGRATION_ENVIRONMENT=staging','MIGRATION_SYNTHETIC_ENABLED=YES','MIGRATION_SYNTHETIC_VAULT_IDS='+context.scopes.map(scope=>scope.vaultID).join(','),
   'MIGRATION_FENCE_PATH='+fenceDirectory+'/journal','MIGRATION_ACTIVATION_POLICY_PATH='+context.activationPolicyPath,'MIGRATION_CONTROLLER_IDENTITY_PATH='+operator+'/controller-identity.json',
  ].join('\n')+'\n',{mode:0o600});
  const code="process.env.MIGRATION_STAGING_DATABASE_URL=process.env.DATABASE_URL;process.argv[1]='/app/scripts/vault-v2-migration-staging.mjs';await import('/app/scripts/vault-v2-migration-staging.mjs');";
  const running=execute('/usr/bin/docker',['run','--rm','-i','--pull=never','--network','cloud_private','--read-only','--user','0:0','--cap-drop','ALL','--security-opt','no-new-privileges',
   '--env-file',settings.envPath,'--env-file',envFile,'--mount',`type=bind,src=${fenceDirectory},dst=${fenceDirectory}`,
   '--mount',`type=bind,src=${operator},dst=${operator},readonly`,'--mount',`type=bind,src=${settings.backupDirectory},dst=${settings.backupDirectory},readonly`,
   '--entrypoint','node',identity.imageDigest,'--input-type=module','-e',code],{encoding:'utf8',timeout:120000,maxBuffer:96*1024*1024});
  running.child.stdin.on('error',()=>{});running.child.stdin.end(JSON.stringify(scoped));
  try{const result=await running;JSON.parse(result.stdout);process.stdout.write(result.stdout);}
  catch(error){const code=error.stderr?.trim();if(/^[a-z_]+$/.test(code??''))throw Error(code);fail('failed');}
 }finally{await rm(temp,{recursive:true,force:true});}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(error=>{
 process.stderr.write(/^[a-z_]+$/.test(error?.message??'')?error.message+'\n':'staging_operator_failed\n');process.exitCode=1;
});
