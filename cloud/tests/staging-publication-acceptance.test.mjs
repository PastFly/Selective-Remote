import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,chmod,rm,mkdir,symlink,realpath,access,link} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {validateRunConfig,validateOperatorRequest,redactedEvidence,readProtectedJSON,operatorArguments,createOperatorBridge,createProtectedRunDirectory,assertProtectedDirectory,lifecycleModules} from '../scripts/staging-publication-acceptance.mjs';
const id=()=>randomUUID(),hash='a'.repeat(64);
function config(){return {version:1,runID:'20261003-a1',origin:'https://cloud.pastfly.ru',emails:['owner@example.test','member@example.test'],expectedSourceSHA:'a'.repeat(40),approvedVaultIDs:[],moduleHashes:Object.fromEntries(lifecycleModules.map(name=>['/'+name+'.js',hash])),operator:{sshHost:'root@142.252.220.33',remoteWrapperPath:'/opt/selective-remote-controller/scripts/staging-migration-operator.sh',identityFile:'/Users/kadaevleonid/.ssh/id_ed25519_selectiveremote'}};}
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
 const old=process.env.PLAYWRIGHT_MODULE,oldMode=process.env.TEST_SESSION_MODE;process.env.PLAYWRIGHT_MODULE=modulePath;process.env.TEST_SESSION_MODE='PRESERVE_TRUSTED_STATE';t.after(()=>{if(old===undefined)delete process.env.PLAYWRIGHT_MODULE;else process.env.PLAYWRIGHT_MODULE=old;if(oldMode===undefined)delete process.env.TEST_SESSION_MODE;else process.env.TEST_SESSION_MODE=oldMode;});
 for(const kind of ['symlink','unprotected']){
  const run=join(dir,kind);await mkdir(run,{mode:0o700});
  await writeFile(join(run,'owner.json'),JSON.stringify({version:1,runID:c.runID,sourceSHA:c.expectedSourceSHA}),{mode:0o600});await writeFile(join(run,'evidence.json'),'[]',{mode:0o600});
  await writeFile(join(run,'journal.json'),JSON.stringify({version:1,completed:['bootstrap'],pending:null,processes:[]}),{mode:0o600});await writeFile(join(run,'scope.json'),'{}',{mode:0o600});
  const profile=join(run,'edge-0');if(kind==='symlink')await symlink(dir,profile);else await mkdir(profile,{mode:0o755});
  await assert.rejects(runStagingBrowserLifecycle({configPath,runDirectory:run,phase:'enroll'}));
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

test('explicit migration policy crosses only enrolled start and rejects malformed or foreign rows',()=>{
 const c=config(),s=scope();c.approvedVaultIDs=[s.vaultID];const input={...s,schemaVersion:2,capability:'resource_acl_v2',resources:[]};delete input.name;
 const row={id:id(),teamID:s.teamID,vaultID:s.vaultID,principalKind:'USER',principalID:s.actorUserID,membershipID:id(),membershipEpoch:1,targetKind:'VAULT',targetID:s.vaultID,mask:1,revokedAt:null};
 assert.deepEqual(validateOperatorRequest(c,s,{operation:'start',input:{...input,policy:[row]}}).input.policy,[row]);
 for(const policy of [[{...row,teamID:id()}],[{...row,vaultID:id()}],[{...row,mask:0}],[{...row,membershipEpoch:0}],[{...row,privateKey:'forbidden'}],[{...row,principalKind:'GROUP'}],Array(1001).fill(row)])assert.throws(()=>validateOperatorRequest(c,s,{operation:'start',input:{...input,policy}}));
 assert.throws(()=>validateOperatorRequest(c,s,{operation:'verify-identities',input:{...input,policy:[row]}}));
});

test('operator proof binds exact pending invocation and immutable ordinary baseline',async()=>{
 const api=await import('../scripts/staging-publication-acceptance.mjs');
 assert.equal(typeof api.validateOperatorProof,'function');
 const checkpoint={version:1,runID:'20261003-a1',origin:config().origin,sourceSHA:'a'.repeat(40),launchNonce:id(),phase:'alternate-revoke',checkpointID:id(),checkpointSHA256:hash,operationID:id(),expectedDeltaCount:0};
 const baseline={unchanged:true,vaultCount:2,personalVaultCount:1,userCount:2,sha256:hash};
 const proof={version:1,runID:checkpoint.runID,origin:checkpoint.origin,sourceSHA:checkpoint.sourceSHA,launchNonce:checkpoint.launchNonce,phase:checkpoint.phase,checkpointID:checkpoint.checkpointID,checkpointSHA256:hash,ordinary:baseline,outbox:{operationID:checkpoint.operationID,effectiveDeltaCount:0,revocationRows:0}};
 assert.deepEqual(api.validateOperatorProof(proof,checkpoint,baseline),proof);
 for(const patch of [{launchNonce:id()},{checkpointID:id()},{checkpointSHA256:'b'.repeat(64)},{ordinary:{...baseline,sha256:'b'.repeat(64)}},{ordinary:{...baseline,unchanged:1}},{outbox:null},{outbox:{...proof.outbox,revocationRows:1}},{outbox:{...proof.outbox,operationID:id()}},{password:'forbidden'}])assert.throws(()=>api.validateOperatorProof({...proof,...patch},checkpoint,baseline));
});

test('phase selection requires explicit fresh or preserved product session mode and complete predecessors',async()=>{
 const api=await import('./browser/staging-real-lifecycle.mjs');assert.equal(typeof api.validateLifecyclePhase,'function');
 assert.equal(api.validateLifecyclePhase('bootstrap','FRESH_ANONYMOUS',[]),'bootstrap');
 assert.throws(()=>api.validateLifecyclePhase('bootstrap','PRESERVE_TRUSTED_STATE',[]));
 assert.equal(api.validateLifecyclePhase('bootstrap','PRESERVE_TRUSTED_STATE',[],{pendingResume:true}),'bootstrap');assert.throws(()=>api.validateLifecyclePhase('bootstrap','FRESH_ANONYMOUS',[],{pendingResume:true}));
 assert.throws(()=>api.validateLifecyclePhase('empty-prepare','PRESERVE_TRUSTED_STATE',['bootstrap']));
 assert.equal(api.validateLifecyclePhase('empty-prepare','PRESERVE_TRUSTED_STATE',['bootstrap','enroll']),'empty-prepare');
 assert.throws(()=>api.validateLifecyclePhase('group-create','FRESH_ANONYMOUS',['bootstrap','enroll','empty-prepare','empty-activate']));
});
test('recovery keeps semantic checkpoint digest but a renewed process rejects the prior proof',async()=>{
 const {checkpointDigest}=await import('./browser/staging-real-lifecycle.mjs'),{validateOperatorProof}=await import('../scripts/staging-publication-acceptance.mjs');
 const body={version:1,runID:'20261003-a1',origin:config().origin,sourceSHA:'a'.repeat(40),phase:'rotate',checkpointID:id(),launchNonce:id(),publicState:{operationID:id(),vaults:[{vaultID:id(),generationID:id()}]}};
 const digest=checkpointDigest(body),next={...body,launchNonce:id()};assert.equal(checkpointDigest(next),digest);assert.notEqual(checkpointDigest({...next,publicState:{...next.publicState,operationID:id()}}),digest);
 const baseline={unchanged:true,vaultCount:2,personalVaultCount:1,userCount:2,sha256:hash};
 const proof={version:1,runID:body.runID,origin:body.origin,sourceSHA:body.sourceSHA,phase:body.phase,checkpointID:body.checkpointID,launchNonce:body.launchNonce,checkpointSHA256:digest,ordinary:baseline,outbox:null};
 assert.throws(()=>validateOperatorProof(proof,{...next,checkpointSHA256:digest},baseline));
});
test('protected root proof cannot be replaced by a hardlink or overwritten for the same invocation',async t=>{
 const dir=await realpath(await mkdtemp(join(tmpdir(),'root-proof-')));t.after(()=>rm(dir,{recursive:true,force:true}));
 const path=join(dir,'operator-proof-'+id()+'-'+id()+'.json');await writeFile(path,'{}',{mode:0o600,flag:'wx'});await assert.rejects(writeFile(path,'{}',{mode:0o600,flag:'wx'}),{code:'EEXIST'});
 await link(path,join(dir,'other'));await assert.rejects(readProtectedJSON(path),/protected_config_required/);
});
test('native v2 metadata accepts actual Swift UUID casing and rejects stale or partial acceptance',async()=>{
 const {validateNativePublic}=await import('./browser/staging-real-lifecycle.mjs');const accountID=id(),teamID=id(),vaultID=id(),runID='20261003-a1',deviceID=id();
 const value={formatVersion:2,nativeGuiTestHost:true,productGuiAcceptance:false,runID:'TEST-ONLY-CODEX-'+runID,phase:'first',launchNonce:id().toUpperCase(),pid:123,processID:id().toUpperCase(),previousProcessID:'',accountID:accountID.toUpperCase(),teamID:teamID.toUpperCase(),vaultID:vaultID.toUpperCase(),deviceID:deviceID.toUpperCase(),generationID:id().toUpperCase(),publicKey:{kty:'EC',crv:'P-256',x:Buffer.alloc(32).toString('base64url'),y:Buffer.alloc(32).toString('base64url'),ext:true,key_ops:[]},publicKeyFingerprint:hash,status:'MATERIALIZED',sequence:1,headerHash:hash,manifestSHA256:hash,acceptedAttemptID:id(),counts:{hosts:1,snippets:1,credentials:1,forwardings:1,folders:1},binary:{executablePath:'/tmp/test',executableSHA256:hash,testBundlePath:'/tmp/bundle',testBundleSHA256:hash},ownPin:{accountID:accountID.toUpperCase(),rootFingerprint:hash,highWater:1,checkpointDigest:Buffer.alloc(32).toString('base64url')},offlineVerified:false,networkReloadVerified:true,secretsVerified:1};
 const expected={runID,accountID,teamID,vaultID,status:['MATERIALIZED']};assert.equal(validateNativePublic(value,expected).deviceID,deviceID);
 for(const patch of [{accountID:id()},{networkReloadVerified:false},{acceptedAttemptID:''},{formatVersion:1},{ownPin:null},{token:'forbidden'},{publicKey:{...value.publicKey,d:'forbidden'}},{counts:{...value.counts,secret:'forbidden'}}])assert.throws(()=>validateNativePublic({...value,...patch},expected));
});
test('runner lock denies a live invocation and recovers only an actually exited local process',async t=>{
 const {acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs'),{spawn}=await import('node:child_process'),{once}=await import('node:events');
 const dir=await realpath(await mkdtemp(join(tmpdir(),'runner-lock-')));t.after(()=>rm(dir,{recursive:true,force:true}));const lock=join(dir,'lock');await acquireLifecycleLock(lock);await assert.rejects(acquireLifecycleLock(lock),/runner_already_active/);
 const child=spawn(process.execPath,['-e','']);await once(child,'exit');await writeFile(join(lock,'owner.json'),JSON.stringify({version:1,pid:child.pid,processID:id()}),{mode:0o600});await acquireLifecycleLock(lock);await assert.rejects(acquireLifecycleLock(lock),/runner_already_active/);
});

test('negative invariant proof binds actual scoped before/after observations and renewed invocation',async()=>{
 const api=await import('../scripts/staging-publication-acceptance.mjs');assert.equal(typeof api.validateNegativeInvariantProof,'function');
 const pending={version:1,runID:'20261003-a1',origin:config().origin,sourceSHA:'a'.repeat(40),launchNonce:id(),phase:'protocol-negatives',checkpointID:id(),checkpointSHA256:hash,publicState:{teamID:id(),vaults:[{vaultID:id()},{vaultID:id()}]}};
 const snapshot=Object.fromEntries(['legacy','pointers','receipts','outbox','resources','parts','wrappers'].map(k=>[k,{count:0,sha256:hash}]));
 const before={...Object.fromEntries(['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'].map(k=>[k,pending[k]])),teamID:pending.publicState.teamID,vaultIDs:pending.publicState.vaults.map(v=>v.vaultID).sort(),stage:'BEFORE',snapshot,beforeCheckpointID:null,beforeCheckpointSHA256:null};
 assert.deepEqual(api.validateNegativeInvariantProof(before,pending,'BEFORE'),before);assert.throws(()=>api.validateNegativeInvariantProof({...before,snapshot:{...snapshot,legacy:{count:0,sha256:[hash]}}},pending,'BEFORE'));
 const afterPending={...pending,checkpointID:id(),launchNonce:id()};const after={...before,checkpointID:afterPending.checkpointID,launchNonce:afterPending.launchNonce,stage:'AFTER',beforeCheckpointID:before.checkpointID,beforeCheckpointSHA256:before.checkpointSHA256};assert.deepEqual(api.validateNegativeInvariantProof(after,afterPending,'AFTER',before),after);
 for(const patch of [{launchNonce:id()},{vaultIDs:[id(),id()]},{stage:'BEFORE'},{snapshot:{...snapshot,outbox:{count:1,sha256:hash}}},{snapshot:{...snapshot,legacy:{count:0,sha256:'b'.repeat(64)}}},{unchanged:true},{snapshot:{...snapshot,outbox:{count:0,sha256:hash,unchanged:true}}}])assert.throws(()=>api.validateNegativeInvariantProof({...after,...patch},afterPending,'AFTER',before));
});

test('pending revoke checkpoint renews the same semantic state using only surviving authenticated profiles',async()=>{
 const api=await import('./browser/staging-real-lifecycle.mjs');
 assert.equal(typeof api.lifecycleBrowserPlan,'function');assert.equal(typeof api.renewLifecycleCheckpoint,'function');
 assert.deepEqual(api.lifecycleBrowserPlan('revoke-device',false),{indexes:[0,1,2],authenticated:[0,1,2]});
 assert.deepEqual(api.lifecycleBrowserPlan('revoke-device',true),{indexes:[0,1],authenticated:[0,1]});
 const pending={version:1,runID:'20261003-a1',origin:config().origin,sourceSHA:'a'.repeat(40),phase:'revoke-device',checkpointID:id(),launchNonce:id(),publicState:{teamID:id(),vaults:[{vaultID:id()},{vaultID:id()}],native:null,operationID:null,expectedDeltaCount:null}};
 pending.checkpointSHA256=api.checkpointDigest(pending);pending.operationID=null;pending.expectedDeltaCount=null;
 const journal={pending:structuredClone(pending)},nonce=id();api.renewLifecycleCheckpoint(journal,'revoke-device',nonce);
 assert.equal(journal.pending.checkpointID,pending.checkpointID);assert.equal(journal.pending.checkpointSHA256,pending.checkpointSHA256);assert.deepEqual(journal.pending.publicState,pending.publicState);assert.equal(journal.pending.launchNonce,nonce);
 assert.deepEqual(journal.renewals,[{checkpointID:pending.checkpointID,previousLaunchNonce:pending.launchNonce,launchNonce:nonce}]);
 assert.throws(()=>api.renewLifecycleCheckpoint(journal,'rotate',id()));assert.throws(()=>api.renewLifecycleCheckpoint(journal,'revoke-device','../invalid'));
 const bad=structuredClone(journal);bad.pending.publicState.teamID=id();assert.throws(()=>api.renewLifecycleCheckpoint(bad,'revoke-device',id()));
});
