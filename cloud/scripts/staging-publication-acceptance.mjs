// Opt-in orchestration only. Never imported by the public server.
import {constants} from 'node:fs';
import {open,lstat,realpath,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {isAbsolute,resolve,dirname,join,relative,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';

export const STAGING_ORIGIN='https://cloud.pastfly.ru';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const hash=/^[a-f0-9]{64}$/,sha=/^[a-f0-9]{40}$/;
const modules=['vault-sync','team-vault-crypto','team-vault-sync','device-trust-flow','device-trust-v1','vault-v2-migration','vault-publication-client'];
const fail=code=>{throw Error(code);};
const object=value=>value&&typeof value==='object'&&!Array.isArray(value);
const exact=(value,keys)=>object(value)&&Object.keys(value).every(key=>keys.includes(key));
export function validateRunConfig(value){
 if(!exact(value,['version','runID','origin','emails','expectedSourceSHA','approvedVaultIDs','moduleHashes','operator'])||value.version!==1
  ||typeof value.runID!=='string'||!/^[a-z0-9][a-z0-9-]{5,39}$/.test(value.runID)||value.origin!==STAGING_ORIGIN||typeof value.expectedSourceSHA!=='string'||!sha.test(value.expectedSourceSHA)
  ||!Array.isArray(value.emails)||value.emails.length!==2||new Set(value.emails.map(email=>typeof email==='string'?email.toLowerCase():email)).size!==2
  ||value.emails.some(email=>typeof email!=='string'||email.length>254||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
  ||!Array.isArray(value.approvedVaultIDs)||value.approvedVaultIDs.some(id=>typeof id!=='string'||!uuid.test(id))||new Set(value.approvedVaultIDs).size!==value.approvedVaultIDs.length
  ||!object(value.moduleHashes)||modules.some(name=>!hash.test(value.moduleHashes[`/${name}.js`]))
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
export async function readProtectedJSON(path){
 if(!isAbsolute(path)||resolve(path)!==path)fail('protected_config_required');
 await assertProtectedDirectory(dirname(path));
 if(await realpath(path)!==path)fail('protected_config_required');
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{const stat=await file.stat();if(!stat.isFile()||(stat.mode&0o077)!==0||stat.uid!==process.getuid()||stat.size>1024*1024)fail('protected_config_required');return JSON.parse(await file.readFile('utf8'));}
 finally{await file.close();}
}
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
 const fields=allowed[request.operation],inputExtras=['start','verify-identities'].includes(request.operation)?['resources']:[];
 if(!exact(request,['operation','input',...fields.filter(key=>key!=='resources')])||!exact(request.input,['teamID','vaultID','attemptID','actorUserID','actorDeviceID','schemaVersion','capability',...inputExtras])
  ||!['teamID','vaultID','attemptID','actorUserID','actorDeviceID'].every(key=>request.input[key]===scope[key])
  ||request.input.schemaVersion!==2||request.input.capability!=='resource_acl_v2')fail('operator_scope');
 if(request.operation==='activate'&&(!activation||!hash.test(request.manifestHash)))fail('activation_policy_pending');
 publicBundle(request,scope);
 if(fields.some(key=>key==='resources'?!Array.isArray(request.input.resources)||request.input.resources.length>1000:
  key==='manifestHash'?typeof request[key]!=='string'||!hash.test(request[key]):key!=='checkpoint'&&!object(request[key])))fail('operator_bundle_invalid');
 if(Buffer.byteLength(JSON.stringify(request))>64*1024*1024)fail('operator_bundle_limit');
 return structuredClone(request);
}
export function operatorArguments(config){
 validateRunConfig(config);return ['-T','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-i',config.operator.identityFile,config.operator.sshHost,config.operator.remoteWrapperPath];
}
export function redactedEvidence(value){
 const out={};
 for(const [key,item]of Object.entries(value)){
  if(key==='phase'){if(typeof item!=='string'||!/^[a-z][a-z0-9_]{0,63}$/.test(item))fail('invalid_evidence');out[key]=item;}
  else if(['accountID','deviceID','teamID','vaultID','attemptID','resourceID','invitationID','generationID'].includes(key)){if(!uuid.test(item))fail('invalid_evidence');out[key]=item;}
  else if(['manifestHash','headerHash','rootFingerprint'].includes(key)){if(!hash.test(item))fail('invalid_evidence');out[key]=item;}
  else if(key==='checkpointDigest'){if(typeof item!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(item)||Buffer.from(item,'base64url').toString('base64url')!==item)fail('invalid_evidence');out[key]=item;}
  else if(['count','sequence','revision'].includes(key)){if(!Number.isSafeInteger(item)||item<0)fail('invalid_evidence');out[key]=item;}
 }
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
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{
  const args=process.argv.slice(2);
  if(args.length!==7||args[0]!=='--execute'||args[1]!=='--config'||args[3]!=='--run-directory'||args[5]!=='--phase')fail('real_run_opt_in_required');
  const {runStagingBrowserLifecycle}=await import('../tests/browser/staging-real-lifecycle.mjs');
  await runStagingBrowserLifecycle({configPath:resolve(args[2]),runDirectory:resolve(args[4]),phase:args[6]});
 }catch{process.stderr.write('staging_real_lifecycle_stopped; inspect redacted phase evidence and prerequisites\n');process.exitCode=1;}
}
