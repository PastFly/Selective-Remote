// Opt-in orchestration only. Never imported by the public server.
import {constants} from 'node:fs';
import {open,lstat,realpath,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {isAbsolute,resolve,dirname,join,relative,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {lifecycleDiagnosticStages,lifecycleDiagnosticCodes,lifecycleRootStatuses} from './staging-lifecycle-diagnostics.mjs';

export const STAGING_ORIGIN='https://cloud.pastfly.ru';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const hash=/^[a-f0-9]{64}$/,sha=/^[a-f0-9]{40}$/;
const runIDPattern=/^[a-z0-9][a-z0-9-]{5,39}$/;
export const lifecycleModules=['vault-sync','team-vault-crypto','team-vault-sync','device-trust-flow','device-trust-v1','vault-v2-migration','vault-publication-client','whole-publication-flow','whole-publication-client','whole-publication-api','vault-publication-v1','resource-crypto-v2','access-model','legacy-resource-mapping'];
const fail=code=>{throw Error(code);};
const object=value=>value&&typeof value==='object'&&!Array.isArray(value);
const exact=(value,keys)=>object(value)&&Object.keys(value).every(key=>keys.includes(key));
export function validateRunConfig(value){
 if(!exact(value,['version','runID','origin','emails','expectedSourceSHA','approvedVaultIDs','moduleHashes','operator'])||value.version!==1
  ||typeof value.runID!=='string'||!runIDPattern.test(value.runID)||value.origin!==STAGING_ORIGIN||typeof value.expectedSourceSHA!=='string'||!sha.test(value.expectedSourceSHA)
  ||!Array.isArray(value.emails)||value.emails.length!==2||new Set(value.emails.map(email=>typeof email==='string'?email.toLowerCase():email)).size!==2
  ||value.emails.some(email=>typeof email!=='string'||email.length>254||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
  ||!Array.isArray(value.approvedVaultIDs)||value.approvedVaultIDs.some(id=>typeof id!=='string'||!uuid.test(id))||new Set(value.approvedVaultIDs).size!==value.approvedVaultIDs.length
  ||!object(value.moduleHashes)||lifecycleModules.some(name=>!hash.test(value.moduleHashes[`/${name}.js`]))
  ||Object.entries(value.moduleHashes).some(([path,digest])=>!/^\/[a-z0-9-]+\.js$/.test(path)||typeof digest!=='string'||!hash.test(digest)))fail('invalid_real_run_config');
 const op=value.operator;
 if(!exact(op,['sshHost','remoteWrapperPath','identityFile'])||op.sshHost!=='root@142.252.220.33'
  ||op.remoteWrapperPath!=='/opt/selective-remote-controller/scripts/staging-migration-operator.sh'
  ||op.identityFile!=='/Users/kadaevleonid/.ssh/id_ed25519_selectiveremote')fail('invalid_operator_bridge');
 return structuredClone(value);
}
export async function assertProtectedDirectory(path){
 if(!isAbsolute(path)||resolve(path)!==path)fail('protected_config_required');
 const stat=await lstat(path);
 if(!stat.isDirectory()||stat.isSymbolicLink()||stat.uid!==process.getuid()||(stat.mode&0o777)!==0o700
  ||await realpath(path)!==path)fail('protected_config_required');
 return path;
}
export async function createProtectedRunDirectory(path){
 if(!isAbsolute(path))fail('protected_config_required');
 // macOS exposes its user temp directory through /var. Normalize only this
 // known system alias at creation; arbitrary symlink ancestors remain invalid.
 const temporary=resolve(tmpdir()),canonicalTemporary=await realpath(temporary);
 if(path===temporary||path.startsWith(temporary+sep))path=join(canonicalTemporary,relative(temporary,path));
 await assertProtectedDirectory(dirname(path));
 await mkdir(path,{mode:0o700});await assertProtectedDirectory(path);return path;
}
export async function readProtectedBytes(path){
 if(!isAbsolute(path)||resolve(path)!==path)fail('protected_config_required');
 await assertProtectedDirectory(dirname(path));
 if(await realpath(path)!==path)fail('protected_config_required');
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{const stat=await file.stat();if(!stat.isFile()||stat.nlink!==1||(stat.mode&0o777)!==0o600||stat.uid!==process.getuid()||stat.size>1024*1024)fail('protected_config_required');return await file.readFile();}
 finally{await file.close();}
}
export async function readProtectedJSON(path){return JSON.parse((await readProtectedBytes(path)).toString('utf8'));}
function publicBundle(value,scope,depth=0,budget={nodes:0}){
 if(++budget.nodes>250000||depth>32)fail('operator_bundle_limit');
 if(value===null||typeof value==='boolean'||typeof value==='number')return;
 if(typeof value==='string')return;
 if(!object(value)&&!Array.isArray(value))fail('operator_bundle_invalid');
 for(const [key,item]of Object.entries(value)){
  if(/^(password|passphrase|privateKey|secret|plaintext|document|token|authorization|identity|checkpointKey|d)$/i.test(key))fail('operator_plaintext_forbidden');
  if(['teamID','vaultID','attemptID'].includes(key)&&item!==scope[key]||key==='generationID'&&item!==scope.attemptID)fail('operator_scope');
  publicBundle(item,scope,depth+1,budget);
 }
}
export function validateOperatorRequest(config,scope,request,{activation=false}={}){
 validateRunConfig(config);
 if(!object(scope)||!['teamID','vaultID','attemptID','actorUserID','actorDeviceID'].every(key=>uuid.test(scope[key]))
  ||!['populated','empty'].some(kind=>scope.name===`TEST-ONLY-CODEX-${config.runID}-${kind}`))fail('operator_scope');
 if(!config.approvedVaultIDs.includes(scope.vaultID))fail('scope_not_enrolled');
 const allowed={preview:[],start:['resources'],'verify-identities':['resources'],upload:['object','checkpoint'],'upload-reader':['projection','sidecar','checkpoint'],validate:['manifest'],activate:['manifestHash']};
 if(!object(request)||!Object.hasOwn(allowed,request.operation))fail('operator_operation');
 const fields=allowed[request.operation],inputExtras=request.operation==='start'?['resources','policy']:request.operation==='verify-identities'?['resources']:[];
 if(!exact(request,['operation','input',...fields.filter(key=>key!=='resources')])||!exact(request.input,['teamID','vaultID','attemptID','actorUserID','actorDeviceID','schemaVersion','capability',...inputExtras])
  ||!['teamID','vaultID','attemptID','actorUserID','actorDeviceID'].every(key=>request.input[key]===scope[key])
  ||request.input.schemaVersion!==2||request.input.capability!=='resource_acl_v2')fail('operator_scope');
 if(request.operation==='activate'&&(!activation||!hash.test(request.manifestHash)))fail('activation_policy_pending');
 publicBundle(request,scope);
 if(request.operation==='start'&&Object.hasOwn(request.input,'policy'))validateMigrationPolicy(request.input.policy,scope,request.input.resources);
 if(fields.some(key=>key==='resources'?!Array.isArray(request.input.resources)||request.input.resources.length>1000:
  key==='manifestHash'?typeof request[key]!=='string'||!hash.test(request[key]):key!=='checkpoint'&&!object(request[key])))fail('operator_bundle_invalid');
 if(Buffer.byteLength(JSON.stringify(request))>64*1024*1024)fail('operator_bundle_limit');
 return structuredClone(request);
}
export function validateMigrationPolicy(policy,scope,resources){
 if(!Array.isArray(policy)||policy.length>1000||!Array.isArray(resources))fail('operator_policy_invalid');
 const ids=new Set();
 for(const p of policy){
  const base=['id','teamID','vaultID','principalKind','principalID','targetKind','targetID','mask','revokedAt'];
  if(!object(p)||!exact(p,p.principalKind==='USER'?[...base,'membershipID','membershipEpoch']:base)||base.some(k=>!Object.hasOwn(p,k))
   ||!uuid.test(p.id)||ids.has(p.id)||p.teamID!==scope.teamID||p.vaultID!==scope.vaultID||!uuid.test(p.principalID)||p.revokedAt!==null
   ||!Number.isSafeInteger(p.mask)||p.mask<1||p.mask>63||!['USER','GROUP'].includes(p.principalKind)
   ||p.principalKind==='USER'&&(!uuid.test(p.membershipID)||!Number.isSafeInteger(p.membershipEpoch)||p.membershipEpoch<1)
   ||!['VAULT','FOLDER','RESOURCE'].includes(p.targetKind)||!uuid.test(p.targetID)
   ||(p.targetKind==='VAULT'?p.targetID!==scope.vaultID:!resources.some(r=>r.id===p.targetID&&(p.targetKind==='FOLDER')===(r.kind==='FOLDER'))))fail('operator_policy_invalid');
  ids.add(p.id);
 }
 return policy;
}
const exactRequired=(v,keys)=>exact(v,keys)&&keys.every(k=>Object.hasOwn(v,k));
export function validateOrdinaryBaseline(value){
 if(!exactRequired(value,['unchanged','vaultCount','personalVaultCount','userCount','sha256'])||value.unchanged!==true||typeof value.sha256!=='string'||!hash.test(value.sha256)
  ||['vaultCount','personalVaultCount','userCount'].some(k=>!Number.isSafeInteger(value[k])||value[k]<0))fail('ordinary_baseline_invalid');
 return structuredClone(value);
}
export function validateOperatorProof(value,pending,baseline){
 validateOrdinaryBaseline(baseline);
 const keys=['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256','ordinary','outbox'];
 if(!exactRequired(value,keys)||value.version!==1||!uuid.test(value.launchNonce)||!uuid.test(value.checkpointID)||!hash.test(value.checkpointSHA256)
  ||keys.slice(0,8).some(k=>value[k]!==pending[k]))fail('operator_proof_mismatch');
 validateOrdinaryBaseline(value.ordinary);
 if(Object.keys(baseline).some(k=>baseline[k]!==value.ordinary[k]))fail('ordinary_baseline_changed');
 if(pending.operationID){
  const out=value.outbox;
  if(!exactRequired(out,['operationID','effectiveDeltaCount','revocationRows'])||out.operationID!==pending.operationID
   ||!['effectiveDeltaCount','revocationRows'].every(k=>Number.isSafeInteger(out[k])&&out[k]>=0)
   ||pending.expectedDeltaCount!==null&&out.effectiveDeltaCount!==pending.expectedDeltaCount
   ||pending.expectedDeltaCount===0&&out.revocationRows!==0)fail('operator_outbox_mismatch');
 }else if(value.outbox!==null)fail('operator_outbox_mismatch');
 return structuredClone(value);
}
export function validateNegativeInvariantProof(value,pending,stage,before=null){
 const binding=['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'];
 const keys=[...binding,'teamID','vaultIDs','stage','snapshot','beforeCheckpointID','beforeCheckpointSHA256'];
 const expected=pending.publicState.vaults.map(v=>v.vaultID).sort();
 if(!exactRequired(value,keys)||value.version!==1||binding.some(k=>value[k]!==pending[k])||!uuid.test(value.checkpointID)||!uuid.test(value.launchNonce)||!hash.test(value.checkpointSHA256)
  ||!['BEFORE','AFTER'].includes(stage)||value.stage!==stage||value.teamID!==pending.publicState.teamID||!uuid.test(value.teamID)
  ||!Array.isArray(value.vaultIDs)||expected.length!==2||new Set(expected).size!==2||value.vaultIDs.length!==2||value.vaultIDs.some((id,i)=>!uuid.test(id)||id!==expected[i]))fail('negative_proof_mismatch');
 const categories=['legacy','pointers','receipts','outbox','resources','parts','wrappers'];
 if(!exactRequired(value.snapshot,categories)||categories.some(k=>!exactRequired(value.snapshot[k],['count','sha256'])||!Number.isSafeInteger(value.snapshot[k].count)||value.snapshot[k].count<0||typeof value.snapshot[k].sha256!=='string'||!hash.test(value.snapshot[k].sha256)))fail('negative_snapshot_invalid');
 if(stage==='BEFORE'){
  if(value.beforeCheckpointID!==null||value.beforeCheckpointSHA256!==null)fail('negative_interval_mismatch');
 }else if(!before||before.stage!=='BEFORE'||value.beforeCheckpointID!==before.checkpointID||value.beforeCheckpointSHA256!==before.checkpointSHA256
  ||value.checkpointID===before.checkpointID||['runID','origin','sourceSHA','teamID'].some(k=>value[k]!==before[k])
  ||value.vaultIDs.some((id,i)=>id!==before.vaultIDs[i])||categories.some(k=>value.snapshot[k].count!==before.snapshot[k].count||value.snapshot[k].sha256!==before.snapshot[k].sha256))fail('rejected_request_mutated_state');
 return structuredClone(value);
}
export function operatorArguments(config){
 validateRunConfig(config);return ['-T','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-i',config.operator.identityFile,config.operator.sshHost,config.operator.remoteWrapperPath];
}
export function redactedEvidence(value){
 const out={};
 for(const [key,item]of Object.entries(value)){
  if(key==='phase'){if(typeof item!=='string'||!/^[a-z][a-z0-9_-]{0,63}$/.test(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='stage'){if(!lifecycleDiagnosticStages.includes(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='failureCode'){if(!lifecycleDiagnosticCodes.includes(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='rootStatus'){if(!lifecycleRootStatuses.includes(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='accountMatch'){if(!['expected','other_approved','unknown'].includes(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='browserIndex'){if(item!==0&&item!==1)fail('invalid_evidence');out[key]=item;}
  else if(key==='evidenceClass'){if(!['DIAGNOSTIC_ONLY_NO_ACCEPTANCE','REGISTERED_BY_OWNER_SERVER_VERIFIED','PARTIAL_BOOTSTRAP_SOURCE_RECOVERY'].includes(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='runID'){if(typeof item!=='string'||!runIDPattern.test(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='expectedSourceSHA'){if(!sha.test(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='publicKeyFingerprint'){if(typeof item!=='string'||!/^[a-f0-9]{4}(?:-[a-f0-9]{4}){15}$/.test(item))fail('invalid_evidence');out[key]=item;}
  else if(['accountID','deviceID','teamID','vaultID','attemptID','resourceID','invitationID','generationID','operationID','launchNonce','previousLaunchNonce','checkpointID','processID','previousProcessID'].includes(key)){if(!uuid.test(item))fail('invalid_evidence');out[key]=item;}
  else if(['manifestHash','headerHash','rootFingerprint','checkpointSHA256','sha256','sourceDigest'].includes(key)){if(!hash.test(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='checkpointDigest'){if(typeof item!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(item)||Buffer.from(item,'base64url').toString('base64url')!==item)fail('invalid_evidence');out[key]=item;}
  else if(['count','sequence','revision','pid','checkCount','effectiveMask','pathCount','effectiveDeltaCount','revocationRows'].includes(key)){if(!Number.isSafeInteger(item)||item<0)fail('invalid_evidence');out[key]=item;}
  else if(['offlineVerified','networkReloadVerified','ordinaryUnchanged','allVaults','secretVerified','responseDiscarded','refreshRecovered','hasRoot','hasPin','signedDirectoryVerified','certificateVerified'].includes(key)){if(typeof item!=='boolean')fail('invalid_evidence');out[key]=item;}
  else if(key==='outcome'){if(!['PASS','DENIED','NOT_RUN','PENDING'].includes(item))fail('invalid_evidence');out[key]=item;}
  else if(['testSessionMode','browserOrigin','localhost','fileURL','apiMode','authSession'].includes(key)){
   const allowed={testSessionMode:['FRESH_ANONYMOUS','PRESERVE_TRUSTED_STATE'],browserOrigin:[STAGING_ORIGIN],localhost:['NO'],fileURL:['NO'],apiMode:['REAL_STAGING'],authSession:['REAL_STAGING','ANONYMOUS']};
   if(!allowed[key].includes(item))fail('invalid_evidence');out[key]=item;
  }
 }
 if(['phase_completed','operator_checkpoint_verified','session_gate','process_started','process_closed','native_admitted'].includes(out.phase)&&!out.outcome)fail('invalid_evidence');
 if(!out.phase)fail('invalid_evidence');return out;
}
export function createOperatorBridge({config,scope,activation=false,spawnValue=spawn}){
 // No shell, forwarded agent, arbitrary command or browser-provided environment.
 return async request=>{
  const checked=validateOperatorRequest(config,scope,request,{activation});
  return new Promise((resolveResult,reject)=>{
   const child=spawnValue('/usr/bin/ssh',operatorArguments(config),{stdio:['pipe','pipe','pipe']});
   let chunks=[],length=0,failed=false;
   const rejectSafe=()=>{if(failed)return;failed=true;child.kill();reject(Error('operator_bridge_failed'));};
   const timer=setTimeout(rejectSafe,120000);
   child.on('error',rejectSafe);child.stdin.on('error',rejectSafe);
   child.stdout.on('data',chunk=>{length+=chunk.length;if(length>64*1024*1024)rejectSafe();else chunks.push(chunk);});
   child.stderr.on('data',()=>{}); // Never print remote diagnostics or bundle contents.
   child.on('close',code=>{clearTimeout(timer);if(failed)return;if(code!==0)return rejectSafe();try{resolveResult(JSON.parse(Buffer.concat(chunks).toString('utf8')));}catch{rejectSafe();}finally{chunks=[];}});
   child.stdin.end(JSON.stringify(checked));
  });
 };
}
async function runCLI(args){
 try{
  if(args.length!==7||args[0]!=='--execute'||args[1]!=='--config'||args[3]!=='--run-directory'||args[5]!=='--phase')fail('real_run_opt_in_required');
  const {runStagingBrowserLifecycle}=await import('../tests/browser/staging-real-lifecycle.mjs');
  await runStagingBrowserLifecycle({configPath:resolve(args[2]),runDirectory:resolve(args[4]),phase:args[6]});
 }catch{process.stderr.write('staging_real_lifecycle_stopped; inspect redacted phase evidence and prerequisites\n');process.exitCode=1;}
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))void runCLI(process.argv.slice(2));
