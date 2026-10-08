import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,chmod,rm,mkdir,symlink,realpath,access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {validateRunConfig,validateOperatorRequest,redactedEvidence,readProtectedJSON,operatorArguments,createOperatorBridge,createProtectedRunDirectory,assertProtectedDirectory} from '../scripts/staging-publication-acceptance.mjs';
const id=()=>randomUUID(),hash='a'.repeat(64);
function config(){return {version:1,runID:'20261003-a1',origin:'https://cloud.pastfly.ru',emails:['owner@example.test','member@example.test'],expectedSourceSHA:'a'.repeat(40),approvedVaultIDs:[],moduleHashes:{'/vault-sync.js':hash,'/team-vault-crypto.js':hash,'/team-vault-sync.js':hash,'/device-trust-flow.js':hash,'/device-trust-v1.js':hash,'/vault-v2-migration.js':hash,'/vault-publication-client.js':hash},operator:{sshHost:'root@142.252.220.33',remoteWrapperPath:'/opt/selective-remote-controller/scripts/staging-migration-operator.sh',identityFile:'/Users/kadaevleonid/.ssh/id_ed25519_selectiveremote'}};}
function scope(){return {teamID:id(),vaultID:id(),attemptID:id(),actorUserID:id(),actorDeviceID:id(),name:'TEST-ONLY-CODEX-20261003-a1-populated'};}
test('real runner requires exact origin fixed operator and explicit scoped enrollment',()=>{
 const c=config();assert.equal(validateRunConfig(c).runID,c.runID);
 for(const patch of [{origin:'http://cloud.pastfly.ru'},{origin:'https://cloud.pastfly.ru.evil.test'},{runID:'../escape'},{emails:[c.emails[0],c.emails[0]]},{operator:{...c.operator,remoteWrapperPath:'/bin/sh'}},{operator:{...c.operator,sshHost:'evil.test'}},{password:'never-read'}])assert.throws(()=>validateRunConfig({...c,...patch}));
 const s=scope(),request={operation:'preview',input:{...s,schemaVersion:2,capability:'resource_acl_v2'}};delete request.input.name;
 assert.throws(()=>validateOperatorRequest(c,s,request),/scope_not_enrolled/);
 c.approvedVaultIDs=[s.vaultID];assert.deepEqual(validateOperatorRequest(c,s,request),request);
 for(const patch of [{vaultID:id()},{teamID:id()},{actorUserID:id()},{attemptID:id()}])assert.throws(()=>validateOperatorRequest(c,s,{...request,input:{...request.input,...patch}}),/operator_scope/);
 assert.throws(()=>validateOperatorRequest(c,{...s,name:'ordinary'},request),/operator_scope/);
});
test('config rejects case-folded duplicate accounts and coercible version/hash/run IDs',()=>{
 const c=config();
 for(const patch of [{emails:[c.emails[0],c.emails[0].toUpperCase()]},{runID:[c.runID]},{expectedSourceSHA:[c.expectedSourceSHA]},{moduleHashes:{...c.moduleHashes,'/vault-sync.js':[hash]}}])assert.throws(()=>validateRunConfig({...c,...patch}));
});
test('scope applies inside encrypted bundles and incomplete operation bodies never cross SSH',()=>{
 const c=config(),s=scope();c.approvedVaultIDs=[s.vaultID];const input={...s,schemaVersion:2,capability:'resource_acl_v2'};delete input.name;
 assert.throws(()=>validateOperatorRequest(c,s,{operation:'upload',input,object:{envelope:{context:{vaultID:id()}}}}),/operator_scope/);
 for(const operation of ['start','verify-identities','upload','upload-reader','validate'])assert.throws(()=>validateOperatorRequest(c,s,{operation,input}));
});
test('SSH failure diagnostics are consumed without appearing in the typed rejection',async()=>{
 const c=config(),s=scope();c.approvedVaultIDs=[s.vaultID];const input={...s,schemaVersion:2,capability:'resource_acl_v2'};delete input.name;
 let args,stdin='';
 const bridge=createOperatorBridge({config:c,scope:s,spawnValue:(command,values)=>{
  assert.equal(command,'/usr/bin/ssh');args=values;const child=new EventEmitter();child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();child.kill=()=>{};
  child.stdin.on('data',chunk=>{stdin+=chunk;});child.stdin.on('finish',()=>{child.stderr.write('PASSWORD_AND_PRIVATE_KEY_DO_NOT_LOG');child.stdout.write('untrusted response');child.emit('close',1);});return child;
 }});
 await assert.rejects(bridge({operation:'preview',input}),{message:'operator_bridge_failed'});
 assert.equal(JSON.parse(stdin).input.vaultID,s.vaultID);assert.deepEqual(args,operatorArguments(c));
});
test('operator bridge refuses plaintext caller proof arbitrary operations and extra input',()=>{
 const c=config(),s=scope();c.approvedVaultIDs=[s.vaultID];const input={...s,schemaVersion:2,capability:'resource_acl_v2'};delete input.name;
 for(const request of [{operation:'exec',input},{operation:'preview',input,command:'id'},{operation:'preview',input:{...input,password:'private'}},{operation:'upload',input,object:{envelope:{plaintext:'private'}}},{operation:'reconcile-fence',intentID:id(),confirmed:true},{operation:'activate',input,manifestHash:hash}])assert.throws(()=>validateOperatorRequest(c,s,request));
 assert.equal(validateOperatorRequest(c,s,{operation:'activate',input,manifestHash:hash},{activation:true}).manifestHash,hash);
 const args=operatorArguments(c);for(const value of ['BatchMode=yes','IdentitiesOnly=yes','StrictHostKeyChecking=yes','ForwardAgent=no','ClearAllForwardings=yes'])assert.ok(args.includes(value));
 assert.equal(args.at(-1),c.operator.remoteWrapperPath);assert.equal(args.includes('-A'),false);
});
test('evidence projection never forwards unexpected values or raw errors',()=>{
 const input={phase:'prepared',accountID:id(),vaultID:id(),count:4,manifestHash:hash,email:'private@example.test',password:'secret',error:{stack:'secret'},ciphertext:'opaque-not-for-evidence'};
 assert.deepEqual(Object.keys(redactedEvidence(input)).sort(),['accountID','count','manifestHash','phase','vaultID']);
 assert.throws(()=>redactedEvidence({...input,phase:'secret\nvalue'}));
 assert.throws(()=>redactedEvidence({...input,manifestHash:'raw-secret'}));
});
test('run configuration must be a protected regular local file',async t=>{
 const dir=await realpath(await mkdtemp(join(tmpdir(),'real-run-config-')));t.after(()=>rm(dir,{recursive:true,force:true}));const path=join(dir,'config');
 await writeFile(path,JSON.stringify(config()),{mode:0o600});assert.equal((await readProtectedJSON(path)).version,1);
 await chmod(path,0o644);await assert.rejects(readProtectedJSON(path),/protected_config_required/);
});


test('configuration rejects symlink ancestors and an unprotected parent despite a 0600 inode',async t=>{
 const dir=await realpath(await mkdtemp(join(tmpdir(),'real-run-tree-')));t.after(()=>rm(dir,{recursive:true,force:true}));
 const privateDir=join(dir,'private');await mkdir(privateDir,{mode:0o700});const path=join(privateDir,'config');await writeFile(path,'{}',{mode:0o600});
 const alias=join(dir,'alias');await symlink(privateDir,alias);
 await assert.rejects(readProtectedJSON(join(alias,'config')),/protected_config_required/);
 await chmod(privateDir,0o755);await assert.rejects(readProtectedJSON(path),/protected_config_required/);
});
test('production trust pin checkpoint digest survives redacted evidence with canonical base64url',async()=>{
 const {deviceDirectoryDigest,advancePinnedTrust}=await import('../public/device-trust-v1.js');
 const checkpointDigest=await deviceDirectoryDigest({payload:{accountID:id(),version:1,entries:[]},signature:Buffer.alloc(64).toString('base64url')});
 const pin={endpoint:config().origin,accountID:id(),rootFingerprint:hash,highWater:1,checkpointDigest};
 assert.deepEqual(advancePinnedTrust(pin,pin),pin);
 assert.equal(redactedEvidence({phase:'owner_identity_verified',...pin}).checkpointDigest,checkpointDigest);
 for(const value of [hash,checkpointDigest+'=','A'.repeat(42)+'B',checkpointDigest.slice(0,-1)+'!',Buffer.alloc(31).toString('base64url')])assert.throws(()=>redactedEvidence({phase:'owner_identity_verified',checkpointDigest:value}));
});
test('resume rejects symlink and unprotected Edge profiles before any browser launch',async t=>{
 const {runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs');
 const dir=await realpath(await mkdtemp(join(tmpdir(),'real-run-profile-')));t.after(()=>rm(dir,{recursive:true,force:true}));
 const configPath=join(dir,'config'),c=config();await writeFile(configPath,JSON.stringify(c),{mode:0o600});
 const launched=join(dir,'launched'),modulePath=join(dir,'probe.mjs');
 await writeFile(modulePath,`import {writeFile} from 'node:fs/promises';export const chromium={async launchPersistentContext(){await writeFile(${JSON.stringify(launched)},'unexpected');throw Error('probe');}};`,{mode:0o600});
 const old=process.env.PLAYWRIGHT_MODULE;process.env.PLAYWRIGHT_MODULE=modulePath;t.after(()=>{if(old===undefined)delete process.env.PLAYWRIGHT_MODULE;else process.env.PLAYWRIGHT_MODULE=old;});
 for(const kind of ['symlink','unprotected']){
  const run=join(dir,kind);await mkdir(run,{mode:0o700});
  await writeFile(join(run,'owner.json'),JSON.stringify({runID:c.runID,sourceSHA:c.expectedSourceSHA}),{mode:0o600});await writeFile(join(run,'evidence.json'),'[]',{mode:0o600});
  const profile=join(run,'edge-0');if(kind==='symlink')await symlink(dir,profile);else await mkdir(profile,{mode:0o755});
  await assert.rejects(runStagingBrowserLifecycle({configPath,runDirectory:run,phase:'prepare'}));
  await assert.rejects(access(launched),{code:'ENOENT'},'unsafe profile reached Browser launcher');
 }
});

test('fresh run creation normalizes the system temp alias but refuses an unsafe parent or existing profile',async t=>{
 const raw=await mkdtemp(join(tmpdir(),'real-run-create-')),dir=await realpath(raw);t.after(()=>rm(dir,{recursive:true,force:true}));
 const canonical=await createProtectedRunDirectory(join(raw,'fresh'));
 assert.equal(canonical,join(dir,'fresh'));assert.equal(await assertProtectedDirectory(canonical),canonical);
 await assert.rejects(createProtectedRunDirectory(canonical),{code:'EEXIST'});
 await chmod(dir,0o755);await assert.rejects(createProtectedRunDirectory(join(dir,'unsafe')),/protected_config_required/);
 await assert.rejects(access(join(dir,'unsafe')),{code:'ENOENT'});
});
test('actual bootstrap record builder survives production Browser Team V1 encryption with all fields and IDs',async()=>{
 const {stagingV1Records}=await import('./browser/staging-real-lifecycle.mjs');
 const {createEmptyVaultDocument,upsertVaultRecord}=await import('../public/vault-model.js');
 const {encryptTeamVaultPayload,decryptTeamVaultPayload}=await import('../public/team-vault-crypto.js');
 const {generateVaultKey}=await import('../public/vault-crypto.js');
 assert.equal(stagingV1Records({installOnly:true}),undefined);
 const records=globalThis.__prcCreateV1Records();delete globalThis.__prcCreateV1Records;
 const deviceID=id();let document=createEmptyVaultDocument();for(const record of records)document=upsertVaultRecord(document,{...record,deviceID});
 const scope={type:'team',teamID:id(),vaultID:id()},vaultKey=await generateVaultKey();
 const envelope=await encryptTeamVaultPayload({vaultKey,payload:document,scope,keyGeneration:1,baseRevision:0});
 const restored=await decryptTeamVaultPayload({vaultKey,envelope,scope});assert.deepEqual(restored,document);
 assert.deepEqual(new Set(records.map(record=>record.type)),new Set(['host','credential','snippet','forwarding']));
 const forward=records.find(record=>record.type==='forwarding'),configuration=JSON.parse(Buffer.from(forward.data.configuration,'base64url'));
 assert.equal(configuration.id,forward.id);assert.equal(configuration.rule.id,forward.id);
});
