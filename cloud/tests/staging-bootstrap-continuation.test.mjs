import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,readFile,rm,realpath,symlink,chmod,lstat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {captureNonTestVaultSnapshot} from '../src/non-test-vault-snapshot.mjs';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {lifecycleModules,redactedEvidence,validateOperatorProof} from '../scripts/staging-publication-acceptance.mjs';
const api=()=>import('../scripts/staging-bootstrap-continuation.mjs');
const id=()=>randomUUID(),hash=v=>createHash('sha256').update(v).digest('hex'),digest='a'.repeat(64);
const config=runID=>({version:1,runID,origin:'https://cloud.pastfly.ru',emails:['one@example.test','two@example.test'],expectedSourceSHA:'a'.repeat(40),approvedVaultIDs:[],moduleHashes:Object.fromEntries(lifecycleModules.map(v=>['/'+v+'.js',digest])),operator:{sshHost:'root@142.252.220.33',remoteWrapperPath:'/opt/selective-remote-controller/scripts/staging-migration-operator.sh',identityFile:'/Users/kadaevleonid/.ssh/id_ed25519_selectiveremote'}});
async function fixture(t){
 const dir=await realpath(await mkdtemp(join(tmpdir(),'bootstrap-continuation-')));t.after(()=>rm(dir,{recursive:true,force:true}));
 const original=join(dir,'original'),runDirectory=join(dir,'continued');for(const p of [original,runDirectory])await mkdir(p,{mode:0o700});
 for(const i of [0,1])await mkdir(join(original,'edge-'+i),{mode:0o700});
 const old=config('prc20261009-original'),current={...config('prc20261009-continued'),expectedSourceSHA:'b'.repeat(40)},nonce=id(),diagnosticNonce=id(),processID=id();
 const baseline={unchanged:true,vaultCount:2,personalVaultCount:3,userCount:4,sha256:digest};
 const identities=[0,1].map(i=>({accountID:id(),deviceID:id(),publicKeyFingerprint:Array(16).fill(i?'bbbb':'aaaa').join('-'),rootFingerprint:(i?'c':'d').repeat(64),outcome:'PASS',accountMatch:'expected',rootStatus:'CUSTODIAN',hasRoot:true,hasPin:true,signedDirectoryVerified:true,certificateVerified:true}));
 const diagnosticName='diagnostic-'+diagnosticNonce+'.json',events=[...identities.map((v,browserIndex)=>({...v,phase:'diagnostic_metadata',browserIndex,launchNonce:diagnosticNonce,processID,runID:old.runID,expectedSourceSHA:old.expectedSourceSHA,previousLaunchNonce:nonce,evidenceClass:'DIAGNOSTIC_ONLY_NO_ACCEPTANCE'})),{phase:'diagnostic_completed',launchNonce:diagnosticNonce,processID,runID:old.runID,expectedSourceSHA:old.expectedSourceSHA,previousLaunchNonce:nonce,evidenceClass:'DIAGNOSTIC_ONLY_NO_ACCEPTANCE',outcome:'NOT_RUN'}];
 const values={'config.json':old,'owner.json':{version:1,runID:old.runID,sourceSHA:old.expectedSourceSHA},'baseline.json':baseline,'journal.json':{version:1,completed:[],pending:null,processes:[],baseline},'evidence.json':[{phase:'session_gate',launchNonce:nonce,testSessionMode:'FRESH_ANONYMOUS',outcome:'PASS'},{phase:'stopped_without_acceptance',launchNonce:nonce,outcome:'DENIED'}],[diagnosticName]:events};
 const files={};for(const[name,value]of Object.entries(values)){const bytes=JSON.stringify(value)+'\n';await writeFile(join(original,name),bytes,{mode:0o600,flag:'wx'});files[name]=hash(bytes);}
 const configPath=join(runDirectory,'config.json');await writeFile(configPath,JSON.stringify(current)+'\n',{mode:0o600,flag:'wx'});
 const {continuationRunnerHashes,continuationConfigIdentity}=await api();
 const manifest={version:1,evidenceClass:'REGISTERED_BY_OWNER_SERVER_VERIFIED',originalRunDirectory:original,originalConfigPath:join(original,'config.json'),originalFiles:files,diagnosticName,configIdentitySHA256:continuationConfigIdentity(current),deployment:{sourceSHA:current.expectedSourceSHA,moduleHashesSHA256:hash(JSON.stringify(current.moduleHashes,Object.keys(current.moduleHashes).sort())),imageDigest:'sha256:'+digest,controllerSHA256:'e'.repeat(64)},runnerHashes:await continuationRunnerHashes(),registrationWindow:{absentAt:'2026-10-09T10:00:00.000Z',verifiedBy:'2026-10-09T10:10:00.000Z'}};
 await writeFile(join(runDirectory,'continuation.json'),JSON.stringify(manifest)+'\n',{mode:0o600,flag:'wx'});
 return {dir,original,runDirectory,configPath,config:current,manifest,baseline,identities,oldBytes:await Promise.all(Object.keys(values).map(n=>readFile(join(original,n))))};
}
function proofFor(request,baseline){
 const keys=['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'];
 return {operator:{...Object.fromEntries(keys.map(k=>[k,request[k]])),ordinary:baseline,outbox:null},evidenceClass:'REGISTERED_BY_OWNER_SERVER_VERIFIED',deployment:request.deployment,ownerAttestation:{registeredAndVerifiedViaProductGUI:true,registrationResponseNotObserved:true},registration:{absentBeforeWindow:true,accounts:request.accounts.map(v=>({...v,createdAt:'2026-10-09T10:02:00.000Z',verifiedAt:'2026-10-09T10:08:00.000Z',disabled:false})),noPartialScope:{ownedTeams:0,memberships:0,invitations:0,teamVaults:0,testNameMatches:0}}};
}
async function admission(t){const f=await fixture(t),a=await api(),link=await a.readContinuationLink(f),request=a.createContinuationRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:f.identities});return {...f,a,link,request,proof:proofFor(request,f.baseline)};}

test('continuation admits separately labelled proof without rewriting original files or fresh gate',async t=>{
 const f=await admission(t);assert.deepEqual(f.a.validateContinuationProof(f.proof,f.request,f.baseline),f.proof);
 assert.equal(f.request.phase,'continue-bootstrap');assert.equal(f.request.sourceSHA,f.config.expectedSourceSHA);assert.notEqual(f.request.sourceSHA,f.link.originalConfig.expectedSourceSHA);
 const {validateLifecyclePhase}=await import('./browser/staging-real-lifecycle.mjs');assert.throws(()=>validateLifecyclePhase('bootstrap','PRESERVE_TRUSTED_STATE',[]));assert.throws(()=>validateLifecyclePhase('continue-bootstrap','FRESH_ANONYMOUS',[]));
 for(const[n,i]of Object.keys(f.manifest.originalFiles).map((n,i)=>[n,i]))assert.deepEqual(await readFile(join(f.original,n)),f.oldBytes[i]);
 const event={phase:'continuation_registration_admitted',evidenceClass:f.manifest.evidenceClass,runID:f.config.runID,expectedSourceSHA:f.config.expectedSourceSHA,previousLaunchNonce:f.request.originalLaunchNonce,launchNonce:f.request.launchNonce,sha256:f.request.checkpointSHA256,outcome:'PASS'};assert.deepEqual(redactedEvidence(event),event);assert.equal(JSON.stringify(event).includes('@'),false);
});
test('continuation rejects changed original source baseline evidence and diagnostic identities',async t=>{
 const f=await fixture(t),a=await api();
 for(const file of ['owner.json','baseline.json','journal.json','evidence.json',f.manifest.diagnosticName]){const path=join(f.original,file),bytes=await readFile(path);await writeFile(path,bytes+' ');await assert.rejects(a.readContinuationLink(f));await writeFile(path,bytes);}
 const link=await a.readContinuationLink(f);
 for(const patch of [{accountID:id()},{deviceID:id()},{publicKeyFingerprint:Array(16).fill('ffff').join('-')},{rootFingerprint:'f'.repeat(64)},{rootStatus:'FIRST_DEVICE'},{accountMatch:'other_approved'},{hasRoot:false}])assert.throws(()=>a.createContinuationRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:[{...f.identities[0],...patch},f.identities[1]]}));
});
test('continuation proof rejects source module baseline replay account root and partial scope changes',async t=>{
 const f=await admission(t),mutations=[p=>p.operator.launchNonce=id(),p=>p.operator.sourceSHA='c'.repeat(40),p=>p.operator.ordinary.sha256='f'.repeat(64),p=>p.deployment.moduleHashesSHA256='f'.repeat(64),p=>p.registration.accounts[0].accountID=id(),p=>p.registration.accounts[0].emailSHA256='f'.repeat(64),p=>p.registration.accounts[0].rootFingerprint='f'.repeat(64),p=>p.registration.accounts[0].disabled=true,p=>p.registration.accounts[0].createdAt='2026-10-08T10:00:00.000Z',p=>p.registration.accounts[1].verifiedAt='2026-10-09T10:11:00.000Z',p=>p.registration.noPartialScope.ownedTeams=1,p=>p.ownerAttestation.registeredAndVerifiedViaProductGUI=false,p=>p.registration.absentBeforeWindow=false,p=>p.evidenceClass='FRESH_REGISTRATION_CAPTURED',p=>p.password='never']
 for(const mutate of mutations){const p=structuredClone(f.proof);mutate(p);assert.throws(()=>f.a.validateContinuationProof(p,f.request,f.baseline));}
});
test('exclusive original profile lock prevents concurrent continuation and claim rejects replay',async t=>{
 const f=await admission(t),{acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs'),lock=join(f.original,'runner.lock');
 await assert.rejects(f.a.claimContinuation({...f,proof:f.proof}),/continuation_lock_required/);
 await acquireLifecycleLock(lock);await assert.rejects(acquireLifecycleLock(lock),/runner_already_active/);
 await f.a.claimContinuation(f);await assert.rejects(f.a.claimContinuation(f),/continuation_already_claimed/);
 await f.a.assertContinuationClaim(f);await assert.rejects(f.a.assertContinuationClaim({...f,runDirectory:join(f.dir,'foreign')}));
 for(const[n,i]of Object.keys(f.manifest.originalFiles).map((n,i)=>[n,i]))assert.deepEqual(await readFile(join(f.original,n)),f.oldBytes[i]);
});
test('continuation rejects symlinked profiles partial scope changed candidate and incomplete diagnosis',async t=>{
 const f=await fixture(t),a=await api();
 await writeFile(join(f.original,'scope.json'),'{}',{mode:0o600});await assert.rejects(a.readContinuationLink(f));await rm(join(f.original,'scope.json'));
 await assert.rejects(a.readContinuationLink({...f,config:{...f.config,expectedSourceSHA:'f'.repeat(40)}}));
 await rm(join(f.original,'edge-1'),{recursive:true});await symlink(join(f.original,'edge-0'),join(f.original,'edge-1'));await assert.rejects(a.readContinuationLink(f));
});
test('partial cancelled old-source diagnostics require fresh sequential readiness under new source',async t=>{
 const f=await fixture(t),a=await api(),path=join(f.original,f.manifest.diagnosticName),events=JSON.parse(await readFile(path));events.splice(1,1);events.at(-1).phase='diagnostic_cancelled';
 const bytes=JSON.stringify(events)+'\n';await writeFile(path,bytes);f.manifest.originalFiles[f.manifest.diagnosticName]=hash(bytes);await writeFile(join(f.runDirectory,'continuation.json'),JSON.stringify(f.manifest)+'\n');
 const link=await a.readContinuationLink(f);assert.equal(link.identities[1],null);
 const actions=[];let count=0;
 const identities=await a.runContinuationReadiness({open:async i=>{actions.push('open'+i);return {};},inspect:async(_p,i)=>{actions.push('inspect'+i);return i===1&&count++===0?{outcome:'DENIED'}:f.identities[i];},showGUI:async(_p,i)=>actions.push('gui'+i),prompt:async i=>{actions.push('prompt'+i);return 'recheck';},close:async(_p,i)=>actions.push('close'+i)});
 assert.deepEqual(actions,['open0','inspect0','close0','open1','inspect1','gui1','prompt1','inspect1','close1']);
 assert.doesNotThrow(()=>a.createContinuationRequest({config:f.config,link,launchNonce:id(),processID:id(),identities}));
 const bad=[{...identities[0],rootStatus:'FIRST_DEVICE'},identities[1]];assert.throws(()=>a.createContinuationRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:bad}));
});
test('readiness quit closes only current profile and cannot manufacture admission',async()=>{
 const a=await api(),actions=[];
 await assert.rejects(a.runContinuationReadiness({open:async i=>{actions.push('open'+i);return {};},inspect:async()=>({outcome:'DENIED'}),showGUI:async()=>{},prompt:async()=> 'quit',close:async(_p,i)=>actions.push('close'+i)}),/continuation_readiness_cancelled/);assert.deepEqual(actions,['open0','close0']);
});
test('linked runner refuses active original lock before writing new run state or launching browsers',async t=>{
 const f=await fixture(t),{acquireLifecycleLock,runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs'),old=process.env.TEST_SESSION_MODE;process.env.TEST_SESSION_MODE='PRESERVE_TRUSTED_STATE';t.after(()=>{if(old===undefined)delete process.env.TEST_SESSION_MODE;else process.env.TEST_SESSION_MODE=old;});
 await acquireLifecycleLock(join(f.original,'runner.lock'));
 await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-bootstrap'}),/runner_already_active/);
 await assert.rejects(readFile(join(f.runDirectory,'owner.json')),{code:'ENOENT'});
});
test('linked pre-browser failure releases original lock and leaves original bytes and claim untouched',async t=>{
 const f=await fixture(t),{runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs'),oldMode=process.env.TEST_SESSION_MODE,oldModule=process.env.PLAYWRIGHT_MODULE;
 process.env.TEST_SESSION_MODE='PRESERVE_TRUSTED_STATE';delete process.env.PLAYWRIGHT_MODULE;t.after(()=>{if(oldMode===undefined)delete process.env.TEST_SESSION_MODE;else process.env.TEST_SESSION_MODE=oldMode;if(oldModule!==undefined)process.env.PLAYWRIGHT_MODULE=oldModule;});
 await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-bootstrap'}),/real_phase_failed/);
 await assert.rejects(readFile(join(f.original,'runner.lock','owner.json')),{code:'ENOENT'});await assert.rejects(readFile(join(f.original,'continuation-claim.json')),{code:'ENOENT'});
 for(const[n,i]of Object.keys(f.manifest.originalFiles).map((n,i)=>[n,i]))assert.deepEqual(await readFile(join(f.original,n)),f.oldBytes[i]);
 const events=JSON.parse(await readFile(join(f.runDirectory,'evidence.json')));assert.equal(events.at(-1).outcome,'DENIED');assert.equal(events.some(e=>e.phase==='continuation_registration_admitted'),false);
});
test('continuation rejects incomplete diagnostic, reordered accounts, changed deployment and candidate script',async t=>{
 const f=await fixture(t),a=await api(),path=join(f.runDirectory,'continuation.json'),original=await readFile(path);
 for(const mutate of [m=>m.runnerHashes['scripts/staging-bootstrap-continuation.mjs']='f'.repeat(64),m=>m.deployment.sourceSHA='f'.repeat(40),m=>m.deployment.moduleHashesSHA256='f'.repeat(64),m=>m.configIdentitySHA256='f'.repeat(64),m=>m.registrationWindow.verifiedBy=m.registrationWindow.absentAt]){const m=structuredClone(f.manifest);mutate(m);await writeFile(path,JSON.stringify(m)+'\n');await assert.rejects(a.readContinuationLink(f));await writeFile(path,original);}
 const diagnosticPath=join(f.original,f.manifest.diagnosticName),events=JSON.parse(await readFile(diagnosticPath));events.at(-1).phase='owner_trust_setup_pending';events.at(-1).outcome='PENDING';const bytes=JSON.stringify(events)+'\n';await writeFile(diagnosticPath,bytes);f.manifest.originalFiles[f.manifest.diagnosticName]=hash(bytes);await writeFile(path,JSON.stringify(f.manifest)+'\n');await assert.rejects(a.readContinuationLink(f),/continuation_diagnostic_required/);
});
test('post-admission identity check rejects root or device drift immediately before Team mutation',async()=>{
 const a=await api(),expected={accountID:id(),deviceID:id(),publicKeyFingerprint:Array(16).fill('aaaa').join('-'),rootFingerprint:digest},actual={...expected,publicPin:{rootFingerprint:digest}};
 assert.doesNotThrow(()=>a.assertContinuationIdentity(actual,expected));for(const patch of [{accountID:id()},{deviceID:id()},{publicKeyFingerprint:Array(16).fill('bbbb').join('-')},{publicPin:{rootFingerprint:'b'.repeat(64)}}])assert.throws(()=>a.assertContinuationIdentity({...actual,...patch},expected));
});
test('diagnostic lock admission rechecks a claim that appeared after initial inspection and releases the lock',async t=>{
 const f=await fixture(t),a=await api(),{acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs');
 await a.assertContinuationUnclaimed(f.original);
 await assert.rejects(a.acquireUnclaimedLifecycleLock(f.original,async lock=>{
  await writeFile(join(f.original,'continuation-claim.json'),'{}\n',{mode:0o600,flag:'wx'});await acquireLifecycleLock(lock);
 }),/continuation_already_claimed/);
 await assert.rejects(readFile(join(f.original,'runner.lock','owner.json')),{code:'ENOENT'});
});

// Synthetic database-side hashes; the real capture serializer defines the raw identity.
async function successorFixture(t){
 const f=await fixture(t),a=await api(),scopes={shared_vaults:[id(),id()].sort(),personal_vaults:[id(),id(),id()].sort(),users:[id(),id(),id(),id()].sort(),teams:[id()]};
 const originalName='ordinary-original-snapshot.json',successorName='ordinary-successor-snapshot.json',authorizationName='ordinary-successor-authorization.json';
 const summary=await captureNonTestVaultSnapshot({path:join(f.runDirectory,originalName),query:async(sql)=>{
  if(sql==='SHOW transaction_isolation')return {rows:[{transaction_isolation:'repeatable read'}]};
  if(sql==='SHOW transaction_read_only')return {rows:[{transaction_read_only:'on'}]};
  if(sql.startsWith('SET LOCAL'))return {rows:[]};
  if(sql.includes('information_schema.columns'))return {rows:[{column_name:'id'}]};
  const table=/^SELECT id FROM public\.(\w+) ORDER BY id$/.exec(sql)?.[1];if(table)return {rows:scopes[table].map(id=>({id}))};
  if(sql.startsWith('SELECT encode(digest'))return {rows:/FROM public\.(vault_resource_ciphertext_versions|vault_resource_key_wrappers_v2|vault_resource_manifest_pointers_v2|vault_publication_projections|team_publication_generations|team_publication_outbox) t/.test(sql)?[]:[{hash:digest}]};
  throw Error('unexpected synthetic query');
 }});
 f.baseline={unchanged:true,...summary};
 for(const name of ['baseline.json','journal.json']){
  const path=join(f.original,name),value=JSON.parse(await readFile(path));if(name==='journal.json')value.baseline=f.baseline;
  const bytes=JSON.stringify(name==='baseline.json'?f.baseline:value)+'\n';await writeFile(path,bytes);f.manifest.originalFiles[name]=hash(bytes);
 }
 const originalSnapshot=JSON.parse(await readFile(join(f.runDirectory,originalName))),successorSnapshot=structuredClone(originalSnapshot);successorSnapshot.tables.users.sha256='f'.repeat(64);
 const successorBytes=JSON.stringify(successorSnapshot);await writeFile(join(f.runDirectory,successorName),successorBytes,{mode:0o600,flag:'wx'});
 const successorBaseline={...f.baseline,sha256:hash(successorBytes)},failedPath=join(f.dir,'failed-comparison.json');
 const failureBytes=JSON.stringify({outcome:'DENIED',code:'ordinary_baseline_changed',expected:f.baseline,observed:successorBaseline})+'\n';await writeFile(failedPath,failureBytes,{mode:0o600,flag:'wx'});
 const now=Date.now(),authorization={version:1,kind:'OWNER_AUTHORIZED_SUCCESSOR_ORDINARY_BASELINE',approved:true,approvalID:id(),approvedAt:new Date(now-60000).toISOString(),interval:{startsAt:new Date(now-30000).toISOString(),endsAt:new Date(now+3600000).toISOString()},originalRunID:'prc20261009-original',originalSourceSHA:'a'.repeat(40),successorRunID:f.config.runID,successorSourceSHA:f.config.expectedSourceSHA,configIdentitySHA256:f.manifest.configIdentitySHA256,originalFiles:f.manifest.originalFiles,deployment:f.manifest.deployment,runnerHashes:f.manifest.runnerHashes,originalSnapshotSHA256:f.baseline.sha256,successorSnapshotSHA256:successorBaseline.sha256,failedComparisons:[{path:failedPath,sha256:hash(failureBytes)}]};
 const transition={version:1,originalSnapshot:{name:originalName,sha256:f.baseline.sha256},successorSnapshot:{name:successorName,sha256:successorBaseline.sha256},ownerAuthorization:{name:authorizationName,sha256:hash(JSON.stringify(authorization)+'\n')},failedComparisons:authorization.failedComparisons};
 f.manifest.successorBaseline=transition;await writeFile(join(f.runDirectory,authorizationName),JSON.stringify(authorization)+'\n',{mode:0o600,flag:'wx'});await writeFile(join(f.runDirectory,'continuation.json'),JSON.stringify(f.manifest)+'\n');
 f.oldBytes=await Promise.all(Object.keys(f.manifest.originalFiles).map(n=>readFile(join(f.original,n))));
 return {...f,a,originalSnapshot,successorSnapshot,successorBaseline,authorization,transition,failedPath,failureBytes};
}
async function successorAdmission(t){
 const f=await successorFixture(t),link=await f.a.readContinuationLink(f),request=f.a.createContinuationRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:f.identities});
 const proof=proofFor(request,f.successorBaseline);proof.successorBaseline={authorizationSHA256:f.transition.ownerAuthorization.sha256,approvalID:f.authorization.approvalID,originalSnapshotSHA256:f.baseline.sha256,observedSnapshotSHA256:f.successorBaseline.sha256,scopeSHA256:hash(canonicalMigrationJSON(f.originalSnapshot.scope)),observedAt:new Date().toISOString()};
 return {...f,link,request,proof};
}
async function rewriteSuccessor(f,{snapshot=f.successorSnapshot,authorization=f.authorization}={}){
 const bytes=JSON.stringify(snapshot);await writeFile(join(f.runDirectory,f.transition.successorSnapshot.name),bytes);f.transition.successorSnapshot.sha256=hash(bytes);authorization.successorSnapshotSHA256=hash(bytes);
 const approval=JSON.stringify(authorization)+'\n';await writeFile(join(f.runDirectory,f.transition.ownerAuthorization.name),approval);f.transition.ownerAuthorization.sha256=hash(approval);await writeFile(join(f.runDirectory,'continuation.json'),JSON.stringify(f.manifest)+'\n');
}

test('authorized successor admits new raw snapshot and preserves original bytes failed comparison and profiles',async t=>{
 const f=await successorAdmission(t);assert.deepEqual(f.link.baseline,f.successorBaseline);assert.notEqual(f.link.baseline.sha256,f.baseline.sha256);
 assert.deepEqual(f.a.validateContinuationProof(f.proof,f.request,f.link.baseline),f.proof);
 const {acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs');await acquireLifecycleLock(join(f.original,'runner.lock'));await f.a.claimContinuation(f);await f.a.assertContinuationClaim(f);
 await assert.rejects(f.a.claimContinuation(f),/continuation_already_claimed/);
 for(const[n,i]of Object.keys(f.manifest.originalFiles).map((n,i)=>[n,i]))assert.deepEqual(await readFile(join(f.original,n)),f.oldBytes[i]);
 assert.equal(await readFile(f.failedPath,'utf8'),f.failureBytes);for(const i of [0,1])assert.equal((await lstat(join(f.original,'edge-'+i))).isDirectory(),true);
});
test('ordinary drift remains denied without explicit successor transition',async t=>{
 const f=await admission(t),proof=structuredClone(f.proof);proof.operator.ordinary.sha256='f'.repeat(64);assert.throws(()=>f.a.validateContinuationProof(proof,f.request,f.baseline),/ordinary_baseline_changed/);
});
test('successor fails closed for missing false fabricated cross-run or source approval',async t=>{
 const f=await successorFixture(t);await f.a.readContinuationLink(f);
 for(const mutate of [a=>delete a.approved,a=>a.approved=false,a=>a.kind='APPROVED',a=>a.originalRunID='foreign-original',a=>a.successorRunID='foreign-continued',a=>a.originalSourceSHA='f'.repeat(40),a=>a.successorSourceSHA='f'.repeat(40),a=>a.originalSnapshotSHA256='f'.repeat(64),a=>a.deployment.imageDigest='sha256:'+'b'.repeat(64),a=>a.configIdentitySHA256='f'.repeat(64),a=>a.runnerHashes={},a=>a.originalFiles={},a=>a.failedComparisons=[],a=>a.interval.endsAt=a.interval.startsAt]){
  const approval=structuredClone(f.authorization);mutate(approval);await rewriteSuccessor(f,{authorization:approval});await assert.rejects(f.a.readContinuationLink(f));
 }
 await rewriteSuccessor(f);await rm(join(f.runDirectory,f.transition.ownerAuthorization.name));await assert.rejects(f.a.readContinuationLink(f));
});
test('successor compares every scope ID set even when all counts match',async t=>{
 const f=await successorFixture(t);await f.a.readContinuationLink(f);
 for(const kind of ['shared','personal','users','teams']){const snapshot=structuredClone(f.successorSnapshot);snapshot.scope[kind][0]=id();await rewriteSuccessor(f,{snapshot});await assert.rejects(f.a.readContinuationLink(f),/successor_scope_mismatch/);}
 const snapshot=structuredClone(f.successorSnapshot);snapshot.scope.users.push(f.identities[0].accountID);await rewriteSuccessor(f,{snapshot});await assert.rejects(f.a.readContinuationLink(f),/successor_scope_mismatch/);
});
test('successor checks exact raw digests both snapshot structures and protected artifacts',async t=>{
 const f=await successorFixture(t);await f.a.readContinuationLink(f);
 for(const file of [f.transition.originalSnapshot.name,f.transition.successorSnapshot.name,f.transition.ownerAuthorization.name]){
  const path=join(f.runDirectory,file),bytes=await readFile(path);await writeFile(path,Buffer.concat([bytes,Buffer.from(' ')]));await assert.rejects(f.a.readContinuationLink(f));await writeFile(path,bytes);await chmod(path,0o644);await assert.rejects(f.a.readContinuationLink(f));await chmod(path,0o600);
 }
 const originalPath=join(f.runDirectory,f.transition.originalSnapshot.name),bytes=await readFile(originalPath);f.transition.originalSnapshot.sha256='f'.repeat(64);await rewriteSuccessor(f);await assert.rejects(f.a.readContinuationLink(f));f.transition.originalSnapshot.sha256=hash(bytes);
 const snapshot=structuredClone(f.successorSnapshot);delete snapshot.tables.users;await rewriteSuccessor(f,{snapshot});await assert.rejects(f.a.readContinuationLink(f));
 await rewriteSuccessor(f);await writeFile(f.failedPath,f.failureBytes+' ');await assert.rejects(f.a.readContinuationLink(f));
});
test('successor proof requires fresh observed state and binds approval snapshot launch source and run',async t=>{
 const f=await successorAdmission(t);f.a.validateContinuationProof(f.proof,f.request,f.link.baseline);
 for(const mutate of [p=>delete p.successorBaseline,p=>p.successorBaseline.approvalID=id(),p=>p.successorBaseline.authorizationSHA256='f'.repeat(64),p=>p.successorBaseline.originalSnapshotSHA256='f'.repeat(64),p=>p.successorBaseline.observedSnapshotSHA256=f.baseline.sha256,p=>p.successorBaseline.scopeSHA256='f'.repeat(64),p=>p.successorBaseline.observedAt=f.authorization.approvedAt,p=>p.successorBaseline.observedAt=f.authorization.interval.endsAt,p=>p.operator.ordinary=f.baseline,p=>p.operator.launchNonce=id(),p=>p.operator.runID='foreign-continued',p=>p.operator.sourceSHA='f'.repeat(40)]){
  const proof=structuredClone(f.proof);mutate(proof);assert.throws(()=>f.a.validateContinuationProof(proof,f.request,f.link.baseline));
 }
 const request=f.a.createContinuationRequest({config:f.config,link:f.link,launchNonce:id(),processID:id(),identities:f.identities});assert.throws(()=>f.a.validateContinuationProof(f.proof,request,f.link.baseline));
});
test('successor cannot be changed or added again after profile claim and admission is bound to link',async t=>{
 const f=await successorAdmission(t),{acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs');await acquireLifecycleLock(join(f.original,'runner.lock'));
 const foreign=structuredClone(f.request);foreign.runID='foreign-continued';const {checkpointSHA256,...body}=foreign;foreign.checkpointSHA256=hash(canonicalMigrationJSON(body));const foreignProof=proofFor(foreign,f.successorBaseline);foreignProof.successorBaseline=f.proof.successorBaseline;
 await assert.rejects(f.a.claimContinuation({...f,request:foreign,proof:foreignProof}));await f.a.claimContinuation(f);
 await writeFile(join(f.runDirectory,f.transition.successorSnapshot.name),JSON.stringify({...f.successorSnapshot,extra:true}));await assert.rejects(f.a.readContinuationLink(f));
 await rewriteSuccessor(f,{snapshot:f.originalSnapshot});await assert.rejects(f.a.assertContinuationClaim({...f,link:await f.a.readContinuationLink(f)}));
});
test('successor initializes new baseline journal and later phase rejects baseline substitution before browser work',async t=>{
 const f=await successorFixture(t),{runStagingBrowserLifecycle,acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs'),oldMode=process.env.TEST_SESSION_MODE,oldModule=process.env.PLAYWRIGHT_MODULE;
 process.env.TEST_SESSION_MODE='PRESERVE_TRUSTED_STATE';delete process.env.PLAYWRIGHT_MODULE;t.after(()=>{if(oldMode===undefined)delete process.env.TEST_SESSION_MODE;else process.env.TEST_SESSION_MODE=oldMode;if(oldModule!==undefined)process.env.PLAYWRIGHT_MODULE=oldModule;});
 await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-bootstrap'}),/real_phase_failed/);
 assert.deepEqual(JSON.parse(await readFile(join(f.runDirectory,'baseline.json'))),f.successorBaseline);const journal=JSON.parse(await readFile(join(f.runDirectory,'journal.json')));assert.deepEqual(journal.baseline,f.successorBaseline);
 const g=await successorAdmission(t);await acquireLifecycleLock(join(g.original,'runner.lock'));await g.a.claimContinuation(g);await rm(join(g.original,'runner.lock'),{recursive:true});
 await writeFile(join(g.runDirectory,'baseline.json'),JSON.stringify(g.baseline),{mode:0o600});await writeFile(join(g.runDirectory,'journal.json'),JSON.stringify({baseline:g.baseline}),{mode:0o600});
 await assert.rejects(runStagingBrowserLifecycle({...g,phase:'protocol-before'}),/continuation_baseline_changed/);
 const checkpoint={...g.request,phase:'protocol-before'};assert.doesNotThrow(()=>validateOperatorProof(proofFor(checkpoint,g.successorBaseline).operator,checkpoint,g.link.baseline));assert.throws(()=>validateOperatorProof(proofFor(checkpoint,g.baseline).operator,checkpoint,g.link.baseline),/ordinary_baseline_changed/);
});

test('successor rejects expired approval future observations wrong new digest and a second linked origin',async t=>{
 const f=await successorAdmission(t);f.a.validateContinuationProof(f.proof,f.request,f.link.baseline);
 const future=structuredClone(f.proof);future.successorBaseline.observedAt=new Date(Date.now()+30000).toISOString();assert.throws(()=>f.a.validateContinuationProof(future,f.request,f.link.baseline),/successor_proof_mismatch/);
 const originalApproval=structuredClone(f.authorization),expired=structuredClone(f.authorization);expired.approvedAt='2026-01-01T00:00:00.000Z';expired.interval={startsAt:'2026-01-01T00:00:01.000Z',endsAt:'2026-01-01T01:00:00.000Z'};await rewriteSuccessor(f,{authorization:expired});
 const link=await f.a.readContinuationLink(f);assert.throws(()=>f.a.createContinuationRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:f.identities}),/successor_authorization_expired/);
 await rewriteSuccessor(f,{authorization:originalApproval});f.transition.successorSnapshot.sha256='e'.repeat(64);await writeFile(join(f.runDirectory,'continuation.json'),JSON.stringify(f.manifest)+'\n');await assert.rejects(f.a.readContinuationLink(f),/successor_artifact_changed/);
 await rewriteSuccessor(f,{authorization:originalApproval});await writeFile(join(f.original,'continuation.json'),'{}',{mode:0o600});await assert.rejects(f.a.readContinuationLink(f),/continuation_partial_scope/);
});
test('successor reordering retains exactly the same scope and admits only its raw authorized digest',async t=>{
 const f=await successorFixture(t),snapshot=structuredClone(f.successorSnapshot);snapshot.scope.users.reverse();await rewriteSuccessor(f,{snapshot});
 const link=await f.a.readContinuationLink(f);assert.equal(link.baseline.sha256,hash(JSON.stringify(snapshot)));assert.notEqual(link.baseline.sha256,f.successorBaseline.sha256);
 const unauthorized=structuredClone(f.authorization);unauthorized.successorSnapshotSHA256='e'.repeat(64);const bytes=JSON.stringify(unauthorized)+'\n';await writeFile(join(f.runDirectory,f.transition.ownerAuthorization.name),bytes);f.transition.ownerAuthorization.sha256=hash(bytes);await writeFile(join(f.runDirectory,'continuation.json'),JSON.stringify(f.manifest)+'\n');await assert.rejects(f.a.readContinuationLink(f),/successor_authorization_required/);
});
