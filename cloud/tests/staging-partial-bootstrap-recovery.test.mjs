import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,readFile,rm,realpath,symlink,lstat,rename} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {lifecycleModules,redactedEvidence} from '../scripts/staging-publication-acceptance.mjs';
import * as continuation from '../scripts/staging-bootstrap-continuation.mjs';

const api=()=>import('../scripts/staging-partial-bootstrap-recovery.mjs');
const id=()=>randomUUID(),sha=v=>createHash('sha256').update(v).digest('hex'),digest=v=>sha(canonicalMigrationJSON(v));
const json=v=>JSON.stringify(v)+'\n';
const write=(path,value)=>writeFile(path,json(value),{mode:0o600});
const config=(runID,source)=>({version:1,runID,origin:'https://cloud.pastfly.ru',emails:['one@example.test','two@example.test'],expectedSourceSHA:source.repeat(40),approvedVaultIDs:[],moduleHashes:Object.fromEntries(lifecycleModules.map(v=>['/'+v+'.js','a'.repeat(64)])),operator:{sshHost:'root@142.252.220.33',remoteWrapperPath:'/opt/selective-remote-controller/scripts/staging-migration-operator.sh',identityFile:'/Users/kadaevleonid/.ssh/id_ed25519_selectiveremote'}});
const predecessorNames=['config.json','owner.json','journal.json','evidence.json','baseline.json','continuation.json','continuation-admission.json'];
async function locks(f){for(const dir of [f.original,f.predecessor,f.runDirectory]){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}}
async function fixture(t){
 const a=await api(),dir=await realpath(await mkdtemp(join(tmpdir(),'partial-bootstrap-')));t.after(()=>rm(dir,{recursive:true,force:true}));
 const original=join(dir,'original'),predecessor=join(dir,'predecessor'),runDirectory=join(dir,'recovery');for(const p of [original,predecessor,runDirectory])await mkdir(p,{mode:0o700});
 for(const i of [0,1])await mkdir(join(original,'edge-'+i),{mode:0o700});
 const old=config('prc20261009-original','a'),prior=config('prc20261009-partial','b'),current=config(prior.runID,'c'),nonce=id(),diagnosticNonce=id(),processID=id();
 const identities=[0,1].map(i=>({accountID:id(),deviceID:id(),publicKeyFingerprint:Array(16).fill(i?'bbbb':'aaaa').join('-'),rootFingerprint:(i?'d':'e').repeat(64),outcome:'PASS',accountMatch:'expected',rootStatus:'CUSTODIAN',hasRoot:true,hasPin:true,signedDirectoryVerified:true,certificateVerified:true}));
 const snapshot={formatVersion:1,scope:{shared:[id()],personal:[id()],users:[id()],teams:[id()]},tables:Object.fromEntries(['users','personal_vaults','vault_revisions','teams','shared_vaults'].map(n=>[n,{present:true,columns:['id'],count:1,sha256:'a'.repeat(64)}]))};
 const next=structuredClone(snapshot);next.tables.users.sha256='b'.repeat(64);
 const originalBaseline={unchanged:true,vaultCount:1,personalVaultCount:1,userCount:1,sha256:sha(JSON.stringify(snapshot))},baseline={...originalBaseline,sha256:sha(JSON.stringify(next))};
 const diagnosticName='diagnostic-'+diagnosticNonce+'.json',events=[...identities.map((v,browserIndex)=>({...v,phase:'diagnostic_metadata',browserIndex,launchNonce:diagnosticNonce,processID,runID:old.runID,expectedSourceSHA:old.expectedSourceSHA,previousLaunchNonce:nonce,evidenceClass:'DIAGNOSTIC_ONLY_NO_ACCEPTANCE'})),{phase:'diagnostic_completed',outcome:'NOT_RUN',launchNonce:diagnosticNonce,processID,runID:old.runID,expectedSourceSHA:old.expectedSourceSHA,previousLaunchNonce:nonce,evidenceClass:'DIAGNOSTIC_ONLY_NO_ACCEPTANCE'}];
 const originalValues={'config.json':old,'owner.json':{version:1,runID:old.runID,sourceSHA:old.expectedSourceSHA},'baseline.json':originalBaseline,'journal.json':{version:1,completed:[],pending:null,processes:[],baseline:originalBaseline},'evidence.json':[{phase:'session_gate',launchNonce:nonce,testSessionMode:'FRESH_ANONYMOUS',outcome:'PASS'},{phase:'stopped_without_acceptance',launchNonce:nonce,outcome:'DENIED'}],[diagnosticName]:events};
 const originalFiles={};for(const [name,value]of Object.entries(originalValues)){await write(join(original,name),value);originalFiles[name]=sha(json(value));}
 await write(join(predecessor,'config.json'),prior);
 const historical={version:1,evidenceClass:'REGISTERED_BY_OWNER_SERVER_VERIFIED',originalRunDirectory:original,originalConfigPath:join(original,'config.json'),originalFiles,diagnosticName,configIdentitySHA256:continuation.continuationConfigIdentity(prior),deployment:{sourceSHA:prior.expectedSourceSHA,moduleHashesSHA256:digest(prior.moduleHashes),imageDigest:'sha256:'+'b'.repeat(64),controllerSHA256:'b'.repeat(64)},runnerHashes:await continuation.continuationRunnerHashes(),registrationWindow:{absentAt:'2026-10-09T10:00:00.000Z',verifiedBy:'2026-10-09T10:10:00.000Z'}};
 await writeFile(join(predecessor,'ordinary-original-snapshot.json'),JSON.stringify(snapshot),{mode:0o600});await writeFile(join(predecessor,'ordinary-successor-snapshot.json'),JSON.stringify(next),{mode:0o600});
 const failedPath=join(dir,'failed-comparison.json');await write(failedPath,{outcome:'DENIED'});
 const now=Date.now(),authorization={version:1,kind:'OWNER_AUTHORIZED_SUCCESSOR_ORDINARY_BASELINE',approved:true,approvalID:id(),approvedAt:new Date(now-60000).toISOString(),interval:{startsAt:new Date(now-30000).toISOString(),endsAt:new Date(now+3600000).toISOString()},originalRunID:old.runID,originalSourceSHA:old.expectedSourceSHA,successorRunID:prior.runID,successorSourceSHA:prior.expectedSourceSHA,configIdentitySHA256:historical.configIdentitySHA256,originalFiles,deployment:historical.deployment,runnerHashes:historical.runnerHashes,originalSnapshotSHA256:originalBaseline.sha256,successorSnapshotSHA256:baseline.sha256,failedComparisons:[{path:failedPath,sha256:sha(json({outcome:'DENIED'}))}]};
 await write(join(predecessor,'ordinary-successor-authorization.json'),authorization);
 historical.successorBaseline={version:1,originalSnapshot:{name:'ordinary-original-snapshot.json',sha256:originalBaseline.sha256},successorSnapshot:{name:'ordinary-successor-snapshot.json',sha256:baseline.sha256},ownerAuthorization:{name:'ordinary-successor-authorization.json',sha256:sha(json(authorization))},failedComparisons:authorization.failedComparisons};
 await write(join(predecessor,'continuation.json'),historical);
 const historicalLink=await continuation.readContinuationLink({config:prior,configPath:join(predecessor,'config.json'),runDirectory:predecessor}),request=continuation.createContinuationRequest({config:prior,link:historicalLink,launchNonce:id(),processID:id(),identities});
 const keys=['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'];
 const proof={operator:{...Object.fromEntries(keys.map(k=>[k,request[k]])),ordinary:baseline,outbox:null},evidenceClass:historical.evidenceClass,deployment:historical.deployment,ownerAttestation:{registeredAndVerifiedViaProductGUI:true,registrationResponseNotObserved:true},registration:{absentBeforeWindow:true,accounts:request.accounts.map(v=>({...v,createdAt:'2026-10-09T10:02:00.000Z',verifiedAt:'2026-10-09T10:08:00.000Z',disabled:false})),noPartialScope:{ownedTeams:0,memberships:0,invitations:0,teamVaults:0,testNameMatches:0}},successorBaseline:{authorizationSHA256:historical.successorBaseline.ownerAuthorization.sha256,approvalID:authorization.approvalID,originalSnapshotSHA256:originalBaseline.sha256,observedSnapshotSHA256:baseline.sha256,scopeSHA256:digest(snapshot.scope),observedAt:new Date().toISOString()}};
 await mkdir(join(original,'runner.lock'),{mode:0o700});await write(join(original,'runner.lock','owner.json'),{pid:process.pid});
 await continuation.claimContinuation({link:historicalLink,request,proof,runDirectory:predecessor});await rm(join(original,'runner.lock'),{recursive:true});
 const predecessorValues={'owner.json':{version:1,runID:prior.runID,sourceSHA:prior.expectedSourceSHA},'baseline.json':baseline,'journal.json':{version:1,completed:[],pending:null,processes:[],baseline},'evidence.json':[{phase:'session_gate',testSessionMode:'PRESERVE_TRUSTED_STATE',launchNonce:request.launchNonce,outcome:'PASS'},{phase:'stopped_without_acceptance',stage:'team_bootstrap',browserIndex:0,launchNonce:request.launchNonce,outcome:'DENIED'}]};
 for(const [name,value]of Object.entries(predecessorValues))await write(join(predecessor,name),value);
 const partial={created:{teamID:id(),actorUserID:identities[0].accountID,actorDeviceID:identities[0].deviceID,vaults:[{vaultID:id(),name:`TEST-ONLY-CODEX-${prior.runID}-populated`,attemptID:id()}]},membershipID:id(),membershipEpoch:1,automaticDeviceAdmission:true,revision:0,formatState:'V1_ACTIVE',activated:false,hasCiphertext:false,wrapperCount:0,ownedTeamCount:1,membershipCount:1,vaultCount:1,invitationCount:0,publicationCount:0,inventorySHA256:'f'.repeat(64)};
 const configPath=join(runDirectory,'config.json');await write(configPath,current);
 const predecessorFiles={};for(const name of predecessorNames)predecessorFiles[name]=sha(await readFile(join(predecessor,name)));
 const manifest={version:1,evidenceClass:'PARTIAL_BOOTSTRAP_SOURCE_RECOVERY',predecessorRunDirectory:predecessor,predecessorConfigPath:join(predecessor,'config.json'),predecessorFiles,originalClaimSHA256:sha(await readFile(join(original,'continuation-claim.json'))),configIdentitySHA256:continuation.continuationConfigIdentity(current),deployment:{sourceSHA:current.expectedSourceSHA,moduleHashesSHA256:digest(current.moduleHashes),imageDigest:'sha256:'+'c'.repeat(64),controllerSHA256:'c'.repeat(64)},runnerHashes:await a.recoveryRunnerHashes(),partial};
 await write(join(runDirectory,'recovery.json'),manifest);
 const preserved=new Map();for(const [root,names]of [[original,[...Object.keys(originalValues),'continuation-claim.json']],[predecessor,[...predecessorNames,'ordinary-original-snapshot.json','ordinary-successor-snapshot.json','ordinary-successor-authorization.json']]])for(const name of names)preserved.set(join(root,name),await readFile(join(root,name)));
 return {a,dir,original,predecessor,runDirectory,configPath,config:current,manifest,baseline,identities,partial,preserved};
}
function proofFor(request,baseline){
 const keys=['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'],observedAt=new Date().toISOString();
 return {operator:{...Object.fromEntries(keys.map(k=>[k,request[k]])),ordinary:baseline,outbox:null},evidenceClass:'PARTIAL_BOOTSTRAP_SOURCE_RECOVERY',deployment:request.deployment,observedAt,partial:structuredClone(request.partial),deviceAdmission:{teamID:request.partial.created.teamID,membershipID:request.partial.membershipID,membershipEpoch:request.partial.membershipEpoch,deviceID:request.partial.created.actorDeviceID,automaticDeviceAdmission:true,admitted:true,productSignInObserved:true,admissionSHA256:'1'.repeat(64),sessionAuditSHA256:'2'.repeat(64),auditSource:'session',observedAt}};
}
async function admitted(t){const f=await fixture(t),link=await f.a.readRecoveryLink(f),request=f.a.createRecoveryRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:f.identities});return {...f,link,request,proof:proofFor(request,f.baseline)};}
async function malformedHistoricalDeployment(f){
 // Deliberately self-consistent historical hashes must not substitute for semantic validation.
 const prior=JSON.parse(await readFile(join(f.predecessor,'continuation.json'))),admission=JSON.parse(await readFile(join(f.predecessor,'continuation-admission.json'))),authorization=JSON.parse(await readFile(join(f.predecessor,'ordinary-successor-authorization.json')));
 prior.deployment.imageDigest='invalid';authorization.deployment=prior.deployment;await write(join(f.predecessor,'ordinary-successor-authorization.json'),authorization);prior.successorBaseline.ownerAuthorization.sha256=sha(json(authorization));await write(join(f.predecessor,'continuation.json'),prior);
 admission.request.deployment=prior.deployment;admission.request.manifestSHA256=sha(json(prior));admission.request.successorBaseline.authorizationSHA256=prior.successorBaseline.ownerAuthorization.sha256;const {checkpointSHA256,...body}=admission.request;admission.request.checkpointSHA256=digest(body);admission.proof.deployment=prior.deployment;admission.proof.operator.checkpointSHA256=admission.request.checkpointSHA256;admission.proof.successorBaseline.authorizationSHA256=prior.successorBaseline.ownerAuthorization.sha256;await write(join(f.predecessor,'continuation-admission.json'),admission);
 const claim=JSON.parse(await readFile(join(f.original,'continuation-claim.json')));claim.manifestSHA256=admission.request.manifestSHA256;claim.checkpointSHA256=admission.request.checkpointSHA256;await write(join(f.original,'continuation-claim.json'),claim);
 for(const name of ['continuation.json','continuation-admission.json'])f.manifest.predecessorFiles[name]=sha(await readFile(join(f.predecessor,name)));f.manifest.originalClaimSHA256=sha(json(claim));await write(join(f.runDirectory,'recovery.json'),f.manifest);
}

test('partial recovery retains original creation and baseline while binding a new source and same browser namespace',async t=>{
 const f=await admitted(t);assert.equal(f.request.phase,'recover-bootstrap');assert.equal(f.request.runID,'prc20261009-partial');assert.equal(f.request.sourceSHA,'c'.repeat(40));assert.equal(f.link.predecessorConfig.expectedSourceSHA,'b'.repeat(40));assert.equal(f.link.originalRunDirectory,f.original);assert.deepEqual(f.link.profiles,[join(f.original,'edge-0'),join(f.original,'edge-1')]);assert.deepEqual(f.link.partial.created,f.partial.created);assert.deepEqual(f.a.validateRecoveryProof(f.proof,f.request,f.baseline),f.proof);
 assert.equal(Object.hasOwn(f.proof,'registration'),false);for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);
});
test('partial recovery refuses any changed predecessor, original claim, baseline authorization or original evidence',async t=>{
 const f=await fixture(t);
 for(const [path,bytes]of f.preserved){await writeFile(path,Buffer.concat([bytes,Buffer.from(' ')]));await assert.rejects(f.a.readRecoveryLink(f));await writeFile(path,bytes);}
});
test('partial recovery refuses another cut point even when its changed journal hash is pinned',async t=>{
 const f=await fixture(t),path=join(f.predecessor,'journal.json'),old=await readFile(path);
 for(const patch of [{completed:['bootstrap']},{pending:{phase:'bootstrap'}},{processes:[id()]}]){await write(path,{...JSON.parse(old),...patch});f.manifest.predecessorFiles['journal.json']=sha(await readFile(path));await write(join(f.runDirectory,'recovery.json'),f.manifest);await assert.rejects(f.a.readRecoveryLink(f),/recovery_partial_scope/);}
 await writeFile(path,old);f.manifest.predecessorFiles['journal.json']=sha(old);await write(join(f.runDirectory,'recovery.json'),f.manifest);await write(join(f.predecessor,'scope.json'),{});await assert.rejects(f.a.readRecoveryLink(f),/recovery_partial_scope/);
});
test('partial recovery refuses extra objects changed tuple and nonempty V1 state',async t=>{
 const f=await fixture(t),mutations=[p=>p.created.vaults.push({...p.created.vaults[0],vaultID:id()}),p=>p.created.actorDeviceID=id(),p=>p.created.vaults[0].name='ordinary',p=>p.revision=1,p=>p.wrapperCount=1,p=>p.ownedTeamCount=2,p=>p.membershipCount=2,p=>p.vaultCount=2,p=>p.invitationCount=1,p=>p.publicationCount=1,p=>p.activated=true,p=>p.hasCiphertext=true,p=>p.formatState='V2_ACTIVE',p=>p.automaticDeviceAdmission=false,p=>p.membershipEpoch=2];
 for(const mutate of mutations){const m=structuredClone(f.manifest);mutate(m.partial);await write(join(f.runDirectory,'recovery.json'),m);await assert.rejects(f.a.readRecoveryLink(f),/recovery_partial_scope/);}
});
test('partial recovery refuses namespace origin identity source runner and module drift',async t=>{
 const f=await fixture(t);
 for(const mutate of [c=>c.runID='prc20261009-other',c=>c.emails.reverse(),c=>c.expectedSourceSHA='b'.repeat(40),c=>c.moduleHashes['/vault-sync.js']='f'.repeat(64)]){const c=structuredClone(f.config);mutate(c);await write(f.configPath,c);await assert.rejects(f.a.readRecoveryLink({...f,config:c}));}await write(f.configPath,f.config);
 const m=structuredClone(f.manifest);m.runnerHashes['scripts/staging-partial-bootstrap-recovery.mjs']='a'.repeat(64);await write(join(f.runDirectory,'recovery.json'),m);await assert.rejects(f.a.readRecoveryLink(f),/recovery_source_mismatch/);
});
test('partial recovery requires the same signed identities and root before requesting target proof',async t=>{
 const f=await fixture(t),link=await f.a.readRecoveryLink(f);
 for(const patch of [{accountID:id()},{deviceID:id()},{rootFingerprint:'f'.repeat(64)},{publicKeyFingerprint:Array(16).fill('ffff').join('-')},{rootStatus:'FIRST_DEVICE'},{hasPin:false}])assert.throws(()=>f.a.createRecoveryRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:[{...f.identities[0],...patch},f.identities[1]]}),/recovery_identity_mismatch/);
});
test('partial recovery target proof rejects replay baseline drift unobserved sign-in and wrong epoch admission',async t=>{
 const f=await admitted(t),mutations=[p=>p.operator.launchNonce=id(),p=>p.operator.sourceSHA='b'.repeat(40),p=>p.operator.ordinary.sha256='0'.repeat(64),p=>p.deployment.imageDigest='sha256:'+'0'.repeat(64),p=>p.partial.inventorySHA256='0'.repeat(64),p=>p.partial.created.vaults[0].attemptID=id(),p=>p.deviceAdmission.membershipEpoch=2,p=>p.deviceAdmission.deviceID=id(),p=>p.deviceAdmission.admitted=false,p=>p.deviceAdmission.productSignInObserved=false,p=>p.deviceAdmission.auditSource='policy',p=>p.deviceAdmission.admissionSHA256='invalid',p=>delete p.deviceAdmission.sessionAuditSHA256,p=>p.deviceAdmission.observedAt='2000-01-01T00:00:00.000Z',p=>p.observedAt='2000-01-01T00:00:00.000Z',p=>p.registration={observed:true}];
 for(const mutate of mutations){const p=structuredClone(f.proof);mutate(p);assert.throws(()=>f.a.validateRecoveryProof(p,f.request,f.baseline));}
});
test('partial recovery exclusive claim requires both inherited locks and prevents replay without touching old evidence',async t=>{
 const f=await admitted(t);await assert.rejects(f.a.claimRecovery(f),/recovery_lock_required/);await locks(f);
 for(const dir of [f.original,f.predecessor]){await write(join(dir,'runner.lock','owner.json'),{pid:process.pid+100000});await assert.rejects(f.a.claimRecovery(f),/recovery_lock_required/);await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 await f.a.claimRecovery(f);await f.a.assertRecoveryClaim(f);await assert.rejects(f.a.claimRecovery(f),/recovery_already_claimed/);for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);
 const other={...f,runDirectory:join(f.dir,'other')};await assert.rejects(f.a.assertRecoveryClaim(other));
});
test('partial recovery rechecks predecessor bytes and target manifest after locks before claiming',async t=>{
 const f=await admitted(t);await locks(f);const path=join(f.predecessor,'evidence.json');await writeFile(path,'changed');await assert.rejects(f.a.claimRecovery(f));await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});
});
test('partial recovery denies missing claim and symlinked preserved profiles',async t=>{
 const f=await fixture(t);await rm(join(f.original,'continuation-claim.json'));await assert.rejects(f.a.readRecoveryLink(f));await writeFile(join(f.original,'continuation-claim.json'),f.preserved.get(join(f.original,'continuation-claim.json')),{mode:0o600});await rm(join(f.original,'edge-1'),{recursive:true});await symlink(join(f.original,'edge-0'),join(f.original,'edge-1'));await assert.rejects(f.a.readRecoveryLink(f));
});
test('partial recovery does not consume its predecessor claim if target admission or scope already exists',async t=>{
 for(const name of ['recovery-admission.json','scope.json']){const f=await admitted(t);await locks(f);await write(join(f.runDirectory,name),{});await assert.rejects(f.a.claimRecovery(f),/recovery_partial_scope/);await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});}
});
test('partial recovery same-process claim race admits exactly one launch and never overwrites its receipt',async t=>{
 const f=await admitted(t);await locks(f);const results=await Promise.allSettled([f.a.claimRecovery(f),f.a.claimRecovery(f)]);assert.equal(results.filter(v=>v.status==='fulfilled').length,1);assert.equal(results.filter(v=>v.status==='rejected').length,1);await f.a.assertRecoveryClaim(f);for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);
});
test('partial recovery refuses an expired interval without replacing the approved baseline or taking a claim',async t=>{
 const f=await admitted(t),expired=structuredClone(f.link);expired.successor.binding.interval.endsAt=new Date(Date.now()-1).toISOString();assert.throws(()=>f.a.createRecoveryRequest({config:f.config,link:expired,launchNonce:id(),processID:id(),identities:f.identities}),/recovery_authorization_expired/);await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});
});
test('partial recovery historical claim survives later vault enrollment but rejects altered recovery admission',async t=>{
 const f=await admitted(t);await locks(f);await f.a.claimRecovery(f);const next={...f.config,approvedVaultIDs:[f.partial.created.vaults[0].vaultID,id()]};await write(f.configPath,next);const link=await f.a.readRecoveryLink({...f,config:next});await f.a.assertRecoveryClaim({link,runDirectory:f.runDirectory});
 const path=join(f.runDirectory,'recovery-admission.json'),value=JSON.parse(await readFile(path));value.request.sourceSHA='b'.repeat(40);await write(path,value);await assert.rejects(f.a.assertRecoveryClaim({link,runDirectory:f.runDirectory}),/recovery_claim_mismatch/);
});
test('partial recovery rejects semantically invalid historical deployment even with self-consistent frozen hashes',async t=>{
 const f=await fixture(t);await malformedHistoricalDeployment(f);await assert.rejects(f.a.readRecoveryLink(f),/recovery_historical_admission_invalid/);
});
function preserveSessionMode(t){const old=process.env.TEST_SESSION_MODE;process.env.TEST_SESSION_MODE='PRESERVE_TRUSTED_STATE';t.after(()=>{if(old===undefined)delete process.env.TEST_SESSION_MODE;else process.env.TEST_SESSION_MODE=old;});}
test('real recovery entrypoint rejects either inherited active lock before writing owner or opening browsers',async t=>{
 preserveSessionMode(t);const {runStagingBrowserLifecycle,acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs');
 for(const which of ['original','predecessor']){const f=await fixture(t),path=join(f[which],'runner.lock');await acquireLifecycleLock(path);const before=await readFile(join(path,'owner.json'));await assert.rejects(runStagingBrowserLifecycle({...f,phase:'recover-bootstrap'}),/runner_already_active/);assert.deepEqual(await readFile(join(path,'owner.json')),before);await assert.rejects(readFile(join(f.runDirectory,'owner.json')),{code:'ENOENT'});if(which==='predecessor')await assert.rejects(readFile(join(f.original,'runner.lock','owner.json')),{code:'ENOENT'});for(const [file,bytes]of f.preserved)assert.deepEqual(await readFile(file),bytes);}
});
test('real recovery entrypoint refuses missing manifest before any linked state creation',async t=>{
 preserveSessionMode(t);const f=await fixture(t),{runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs');await rm(join(f.runDirectory,'recovery.json'));await assert.rejects(runStagingBrowserLifecycle({...f,phase:'recover-bootstrap'}),/recovery_manifest_required/);await assert.rejects(readFile(join(f.runDirectory,'owner.json')),{code:'ENOENT'});
});
test('real recovery pre-browser failure releases inherited and own locks and preserves all historical claims',async t=>{
 preserveSessionMode(t);const previous=process.env.PLAYWRIGHT_MODULE;delete process.env.PLAYWRIGHT_MODULE;t.after(()=>{if(previous===undefined)delete process.env.PLAYWRIGHT_MODULE;else process.env.PLAYWRIGHT_MODULE=previous;});
 const f=await fixture(t),{runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs');await assert.rejects(runStagingBrowserLifecycle({...f,phase:'recover-bootstrap'}),/real_phase_failed/);
 for(const directory of [f.original,f.predecessor,f.runDirectory])await assert.rejects(readFile(join(directory,'runner.lock','owner.json')),{code:'ENOENT'});for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});await assert.rejects(readFile(join(f.runDirectory,'recovery-admission.json')),{code:'ENOENT'});
 const evidence=JSON.parse(await readFile(join(f.runDirectory,'evidence.json')));assert.equal(evidence.at(-1).phase,'stopped_without_acceptance');assert.equal(evidence.some(v=>v.phase==='partial_bootstrap_admitted'||v.phase==='process_started'),false);
});
test('partial recovery evidence exposes its separate class while dropping raw scope and credentials',()=>{
 const safe={phase:'partial_bootstrap_admitted',evidenceClass:'PARTIAL_BOOTSTRAP_SOURCE_RECOVERY',runID:'prc20261009-partial',expectedSourceSHA:'c'.repeat(40),launchNonce:id(),sha256:'a'.repeat(64),outcome:'PASS'};
 assert.deepEqual(redactedEvidence({...safe,password:'never',email:'one@example.test',partial:{teamID:id()},deviceAdmission:{admissionSHA256:'f'.repeat(64)}}),safe);
});
test('partial recovery claim rejects later replacement of a syntactically valid observed audit digest',async t=>{
 const f=await admitted(t);await locks(f);await f.a.claimRecovery(f);const path=join(f.runDirectory,'recovery-admission.json'),admission=JSON.parse(await readFile(path));admission.proof.deviceAdmission.sessionAuditSHA256='3'.repeat(64);await write(path,admission);await assert.rejects(f.a.assertRecoveryClaim(f),/recovery_claim_mismatch/);
});

async function renewed(t){
 const f=await fixture(t);
 // The historical admission is valid at its own observation time, then expires.
 t.mock.timers.enable({apis:['Date'],now:Date.now()+2*86400000});
 const old=await f.a.readRecoveryLink(f);
 assert.throws(()=>f.a.createRecoveryRequest({config:f.config,link:old,launchNonce:id(),processID:id(),identities:f.identities}),/recovery_authorization_expired/);
 const capturedAt=new Date(Date.now()-1000).toISOString(),interval={startsAt:capturedAt,endsAt:new Date(Date.now()+3600000).toISOString()};
 const original=await readFile(join(f.predecessor,'ordinary-successor-snapshot.json')),snapshot=JSON.parse(original);snapshot.tables.personal_vaults.sha256='9'.repeat(64);snapshot.tables.vault_revisions.count+=10;
 const successor=JSON.stringify(snapshot),failedPath=join(f.dir,'expired-interval-comparison.json');await write(failedPath,{outcome:'DENIED',expectedSnapshotSHA256:f.baseline.sha256,observedSnapshotSHA256:sha(successor)});
 const failedComparisons=[...JSON.parse(await readFile(join(f.predecessor,'ordinary-successor-authorization.json'))).failedComparisons,{path:failedPath,sha256:sha(await readFile(failedPath))}];
 const recoveryContext={predecessorRunDirectory:f.predecessor,predecessorFilesSHA256:digest(f.manifest.predecessorFiles),originalClaimSHA256:f.manifest.originalClaimSHA256,predecessorAuthorizationSHA256:old.successor.binding.authorizationSHA256,predecessorSnapshotSHA256:f.baseline.sha256,partialSHA256:digest(f.partial),capturedAt};
 const authorization={version:1,kind:'OWNER_AUTHORIZED_SUCCESSOR_ORDINARY_BASELINE',approved:true,approvalID:id(),approvedAt:new Date(Date.now()-2000).toISOString(),interval,originalRunID:f.config.runID,originalSourceSHA:old.predecessorConfig.expectedSourceSHA,successorRunID:f.config.runID,successorSourceSHA:f.config.expectedSourceSHA,configIdentitySHA256:f.manifest.configIdentitySHA256,originalFiles:f.manifest.predecessorFiles,deployment:f.manifest.deployment,runnerHashes:f.manifest.runnerHashes,originalSnapshotSHA256:sha(original),successorSnapshotSHA256:sha(successor),failedComparisons,recoveryContext};
 await writeFile(join(f.runDirectory,'ordinary-original-snapshot.json'),original,{mode:0o600});await writeFile(join(f.runDirectory,'ordinary-successor-snapshot.json'),successor,{mode:0o600});await write(join(f.runDirectory,'ordinary-successor-authorization.json'),authorization);
 f.manifest.renewal={capturedAt,successorBaseline:{version:1,originalSnapshot:{name:'ordinary-original-snapshot.json',sha256:sha(original)},successorSnapshot:{name:'ordinary-successor-snapshot.json',sha256:sha(successor)},ownerAuthorization:{name:'ordinary-successor-authorization.json',sha256:sha(json(authorization))},failedComparisons}};
 await write(join(f.runDirectory,'recovery.json'),f.manifest);
 return {...f,authorization,recoveryContext,newBaseline:{...f.baseline,sha256:sha(successor)},old};
}
async function rewriteRenewal(f,mutate){
 const m=structuredClone(f.manifest),a=structuredClone(f.authorization);mutate(m,a);await write(join(f.runDirectory,'ordinary-successor-authorization.json'),a);m.renewal.successorBaseline.ownerAuthorization.sha256=sha(json(a));await write(join(f.runDirectory,'recovery.json'),m);
}
function renewalProof(request,baseline){
 const proof=proofFor(request,baseline),b=request.successorBaseline;
 return {...proof,successorBaseline:{authorizationSHA256:b.authorizationSHA256,approvalID:b.approvalID,originalSnapshotSHA256:b.originalSnapshotSHA256,observedSnapshotSHA256:baseline.sha256,scopeSHA256:b.scopeSHA256,observedAt:proof.observedAt}};
}
test('authorized renewal admits a fresh same-scope interval after historical expiry and keeps all historical bytes',async t=>{
 const f=await renewed(t),link=await f.a.readRecoveryLink(f),request=f.a.createRecoveryRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:f.identities}),proof=renewalProof(request,f.newBaseline);
 assert.deepEqual(link.baseline,f.newBaseline);assert.deepEqual(request.renewalContext,f.recoveryContext);assert.equal(request.successorBaseline.originalSnapshotSHA256,f.baseline.sha256);assert.deepEqual(link.profiles,f.old.profiles);assert.deepEqual(link.partial,f.partial);assert.deepEqual(f.a.validateRecoveryProof(proof,request,f.newBaseline),proof);
 await locks(f);await f.a.claimRecovery({...f,link,request,proof});await f.a.assertRecoveryClaim({link,runDirectory:f.runDirectory});await assert.rejects(f.a.claimRecovery({...f,link,request,proof}),/recovery_already_claimed/);
 for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);
 await write(join(f.runDirectory,'baseline.json'),f.newBaseline);await write(join(f.runDirectory,'journal.json'),{baseline:f.newBaseline});await continuation.assertContinuationRunBaseline({link,runDirectory:f.runDirectory});await write(join(f.runDirectory,'baseline.json'),f.baseline);await assert.rejects(continuation.assertContinuationRunBaseline({link,runDirectory:f.runDirectory}));
});
test('renewal rejects missing authorization, chain tampering, source mismatch, unbounded or fabricated capture interval before claim',async t=>{
 const f=await renewed(t);
 const mutations=[(m,a)=>a.approved=false,(m,a)=>delete a.recoveryContext,(m,a)=>a.recoveryContext.predecessorAuthorizationSHA256='0'.repeat(64),(m,a)=>a.recoveryContext.predecessorSnapshotSHA256='0'.repeat(64),(m,a)=>a.recoveryContext.originalClaimSHA256='0'.repeat(64),(m,a)=>a.recoveryContext.partialSHA256='0'.repeat(64),(m,a)=>a.successorSourceSHA='d'.repeat(40),(m,a)=>a.successorRunID='prc-other',(m,a)=>a.deployment={...a.deployment,controllerSHA256:'0'.repeat(64)},(m,a)=>a.originalSnapshotSHA256='0'.repeat(64),(m,a)=>a.successorSnapshotSHA256='0'.repeat(64),(m,a)=>a.interval.endsAt=new Date(Date.now()+2*86400000).toISOString(),(m,a)=>m.renewal.capturedAt='2000-01-01T00:00:00.000Z',(m,a)=>m.renewal.unrecognized=true,(m,a)=>{a.failedComparisons=[];m.renewal.successorBaseline.failedComparisons=[];}];
 for(const mutate of mutations){await rewriteRenewal(f,mutate);await assert.rejects(f.a.readRecoveryLink(f));}
 await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});
});
test('renewal rejects changed IDs in each original scope set even with matching counts and recomputed hashes',async t=>{
 const f=await renewed(t),snapshot=JSON.parse(await readFile(join(f.runDirectory,'ordinary-successor-snapshot.json')));
 for(const kind of ['shared','personal','users','teams']){
  const next=structuredClone(snapshot);next.scope[kind][0]=id();const bytes=JSON.stringify(next);await writeFile(join(f.runDirectory,'ordinary-successor-snapshot.json'),bytes);
  await rewriteRenewal(f,(m,a)=>{m.renewal.successorBaseline.successorSnapshot.sha256=sha(bytes);a.successorSnapshotSHA256=sha(bytes);});await assert.rejects(f.a.readRecoveryLink(f),/successor_scope_mismatch/);
 }
});
test('renewal proof requires current observations and rejects nonce replay and every subsequent ordinary drift',async t=>{
 const f=await renewed(t),link=await f.a.readRecoveryLink(f),request=f.a.createRecoveryRequest({config:f.config,link,launchNonce:id(),processID:id(),identities:f.identities}),proof=renewalProof(request,f.newBaseline);
 for(const mutate of [p=>delete p.successorBaseline,p=>p.successorBaseline.authorizationSHA256=f.old.successor.binding.authorizationSHA256,p=>p.successorBaseline.observedSnapshotSHA256=f.baseline.sha256,p=>p.successorBaseline.scopeSHA256='0'.repeat(64),p=>p.operator.launchNonce=id(),p=>p.operator.ordinary.sha256=f.baseline.sha256,p=>p.successorBaseline.observedAt='2000-01-01T00:00:00.000Z']){const p=structuredClone(proof);mutate(p);assert.throws(()=>f.a.validateRecoveryProof(p,request,f.newBaseline));}
 const changed=structuredClone(request);changed.renewalContext.partialSHA256='0'.repeat(64);const {checkpointSHA256,...body}=changed;changed.checkpointSHA256=digest(body);const changedProof=renewalProof(changed,f.newBaseline);await locks(f);await assert.rejects(f.a.claimRecovery({...f,link,request:changed,proof:changedProof}),/recovery_claim_mismatch/);
 await writeFile(join(f.runDirectory,'ordinary-successor-snapshot.json'),'{}');await assert.rejects(f.a.claimRecovery({...f,link,request,proof}));await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});
});
test('renewal preserves frozen failure artifacts and rejects their replacement or missing historical failure pins',async t=>{
 const f=await renewed(t);await f.a.readRecoveryLink(f);
 for(const entry of f.authorization.failedComparisons){const before=await readFile(entry.path);await writeFile(entry.path,Buffer.concat([before,Buffer.from(' ')]));await assert.rejects(f.a.readRecoveryLink(f),/successor_failed_comparison_changed/);await writeFile(entry.path,before);}
 await rewriteRenewal(f,(m,a)=>{a.failedComparisons=a.failedComparisons.slice(1);m.renewal.successorBaseline.failedComparisons=a.failedComparisons;});await assert.rejects(f.a.readRecoveryLink(f),/recovery_renewal_invalid/);
 await rewriteRenewal(f,(m,a)=>{a.failedComparisons=a.failedComparisons.slice(0,1);m.renewal.successorBaseline.failedComparisons=a.failedComparisons;});await assert.rejects(f.a.readRecoveryLink(f),/recovery_renewal_invalid/);
});
test('renewal rejects raw snapshot and authorization tampering and widened scopes before taking its one-use claim',async t=>{
 const f=await renewed(t);await f.a.readRecoveryLink(f);
 for(const name of ['ordinary-original-snapshot.json','ordinary-successor-snapshot.json','ordinary-successor-authorization.json']){const path=join(f.runDirectory,name),bytes=await readFile(path);await writeFile(path,Buffer.concat([bytes,Buffer.from(' ')]));await assert.rejects(f.a.readRecoveryLink(f),/successor_artifact_changed/);await writeFile(path,bytes);}
 const snapshot=JSON.parse(await readFile(join(f.runDirectory,'ordinary-successor-snapshot.json')));
 for(const kind of ['shared','personal','users','teams']){const next=structuredClone(snapshot);next.scope[kind].push(id());const bytes=JSON.stringify(next);await writeFile(join(f.runDirectory,'ordinary-successor-snapshot.json'),bytes);await rewriteRenewal(f,(m,a)=>{m.renewal.successorBaseline.successorSnapshot.sha256=sha(bytes);a.successorSnapshotSHA256=sha(bytes);});await assert.rejects(f.a.readRecoveryLink(f),/successor_scope_mismatch/);}
 await assert.rejects(readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')),{code:'ENOENT'});
});

// Task 4: the consumed revision-zero claim is historical evidence, never replayable.
async function initializedFixture(t){
 const f=await admitted(t);await locks(f);await f.a.claimRecovery(f);
 for(const dir of [f.original,f.predecessor,f.runDirectory])await rm(join(dir,'runner.lock'),{recursive:true});
 const parent=f.runDirectory,parentConfigPath=f.configPath;
 const values={'owner.json':{version:1,runID:f.config.runID,sourceSHA:f.config.expectedSourceSHA},'baseline.json':f.baseline,'journal.json':{version:1,completed:[],pending:null,processes:[],baseline:f.baseline},'evidence.json':[{phase:'session_gate',testSessionMode:'PRESERVE_TRUSTED_STATE',launchNonce:f.request.launchNonce,outcome:'PASS'},{phase:'stopped_without_acceptance',stage:'team_bootstrap',browserIndex:0,launchNonce:f.request.launchNonce,outcome:'DENIED',failureCode:'unknown_failure'}]};
 for(const [name,value]of Object.entries(values))await write(join(parent,name),value);
 const runDirectory=join(f.dir,'initialized'),current=config(f.config.runID,'d');await mkdir(runDirectory,{mode:0o700});const configPath=join(runDirectory,'config.json');await write(configPath,current);
 const parentFiles={};for(const name of ['config.json','owner.json','journal.json','evidence.json','baseline.json','recovery.json','recovery-admission.json'])parentFiles[name]=sha(await readFile(join(parent,name)));
 const recipient={membershipID:f.partial.membershipID,membershipEpoch:1,deviceID:f.identities[0].deviceID};
 const initialized={created:f.partial.created,membershipID:f.partial.membershipID,membershipEpoch:1,automaticDeviceAdmission:true,revision:1,keyGeneration:1,rotationRequired:false,formatState:'V1_ACTIVE',activated:false,v2Pointer:null,ownedTeamCount:1,membershipCount:1,vaultCount:1,invitationCount:0,grantCount:0,publicationCount:0,inventorySHA256:'f'.repeat(64),envelopeSHA256:'1'.repeat(64),wrappers:[{...recipient,wrapperSHA256:'2'.repeat(64)}],requiredRecipients:[recipient],ownerTrust:{...Object.fromEntries(['accountID','deviceID','rootFingerprint','publicKeyFingerprint'].map(k=>[k,f.identities[0][k]])),admitted:true,revoked:false,signedDirectorySHA256:'3'.repeat(64),certificateSHA256:'4'.repeat(64)}};
 const a=await import('../scripts/staging-initialized-bootstrap-recovery.mjs');
 const manifest={version:1,evidenceClass:'INITIALIZED_EMPTY_BOOTSTRAP_RECOVERY',parentRunDirectory:parent,parentConfigPath,parentFiles,parentClaimSHA256:sha(await readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json'))),configIdentitySHA256:continuation.continuationConfigIdentity(current),deployment:{sourceSHA:current.expectedSourceSHA,moduleHashesSHA256:digest(current.moduleHashes),imageDigest:'sha256:'+'d'.repeat(64),controllerSHA256:'d'.repeat(64)},runnerHashes:await a.initializedRecoveryRunnerHashes(),initialized};
 await write(join(runDirectory,'initialized-recovery.json'),manifest);
 for(const name of Object.keys(parentFiles))f.preserved.set(join(parent,name),await readFile(join(parent,name)));
 f.preserved.set(join(f.predecessor,'partial-bootstrap-recovery-claim.json'),await readFile(join(f.predecessor,'partial-bootstrap-recovery-claim.json')));
 const result={...f,a,config:current,configPath,runDirectory,parent,parentConfigPath,manifest,initialized};
 const link=await a.readInitializedRecoveryLink(result),request=a.createInitializedRecoveryRequest({...result,link,launchNonce:id(),processID:id(),identities:f.identities});
 const observedAt=new Date().toISOString(),b=request.successorBaseline;
 const proof={operator:{...Object.fromEntries(['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'].map(k=>[k,request[k]])),ordinary:f.baseline,outbox:null},evidenceClass:manifest.evidenceClass,deployment:manifest.deployment,observedAt,initialized:structuredClone(initialized),successorBaseline:{authorizationSHA256:b.authorizationSHA256,approvalID:b.approvalID,originalSnapshotSHA256:b.originalSnapshotSHA256,observedSnapshotSHA256:b.successorSnapshotSHA256,scopeSHA256:b.scopeSHA256,observedAt}};
 return {...result,link,request,proof};
}
test('initialized successor admits exactly the preserved revision-one empty scope and consumes a new exclusive parent claim',async t=>{
 const f=await initializedFixture(t);assert.equal(f.request.phase,'recover-initialized-bootstrap');assert.deepEqual(f.a.validateInitializedRecoveryProof(f.proof,f.request,f.baseline),f.proof);
 for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 await f.a.claimInitializedRecovery(f);await f.a.assertInitializedRecoveryClaim(f);await assert.rejects(f.a.claimInitializedRecovery(f),/initialized_recovery_already_claimed/);
 for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);
});
test('initialized successor rejects altered history, consumed claim, config, source and nonce',async t=>{
 const f=await initializedFixture(t);
 for(const [path,bytes]of f.preserved){await writeFile(path,Buffer.concat([bytes,Buffer.from(' ')]));await assert.rejects(f.a.readInitializedRecoveryLink(f));await writeFile(path,bytes);}
 for(const mutate of [p=>p.operator.launchNonce=id(),p=>p.operator.sourceSHA='c'.repeat(40),p=>p.operator.ordinary.sha256='0'.repeat(64),p=>p.deployment.controllerSHA256='0'.repeat(64),p=>p.successorBaseline.observedSnapshotSHA256='0'.repeat(64)]){const p=structuredClone(f.proof);mutate(p);assert.throws(()=>f.a.validateInitializedRecoveryProof(p,f.request,f.baseline));}
 for(const mutate of [m=>m.parentRunDirectory=f.original,m=>m.parentClaimSHA256='0'.repeat(64),m=>m.configIdentitySHA256='0'.repeat(64),m=>m.runnerHashes['scripts/staging-initialized-bootstrap-recovery.mjs']='0'.repeat(64)]){const m=structuredClone(f.manifest);mutate(m);await write(join(f.runDirectory,'initialized-recovery.json'),m);await assert.rejects(f.a.readInitializedRecoveryLink(f));}
});
test('initialized successor refuses scope epoch trust V2 ciphertext wrapper recipient and inventory drift',async t=>{
 const f=await initializedFixture(t);
 for(const mutate of [v=>v.created.teamID=id(),v=>v.created.vaults[0].vaultID=id(),v=>v.membershipEpoch=2,v=>v.ownerTrust.deviceID=id(),v=>v.ownerTrust.rootFingerprint='0'.repeat(64),v=>v.ownerTrust.revoked=true,v=>v.ownerTrust.admitted=false,v=>v.vaultCount=2,v=>v.invitationCount=1,v=>v.grantCount=1,v=>v.publicationCount=1,v=>v.v2Pointer=id(),v=>v.formatState='V2_ACTIVE',v=>v.rotationRequired=true,v=>v.revision=2,v=>v.keyGeneration=2,v=>v.envelopeSHA256='0'.repeat(64),v=>v.wrappers[0].wrapperSHA256='0'.repeat(64),v=>v.requiredRecipients=[],v=>v.requiredRecipients.push({...v.requiredRecipients[0]}),v=>v.wrappers=[]]){
  const p=structuredClone(f.proof);mutate(p.initialized);assert.throws(()=>f.a.validateInitializedRecoveryProof(p,f.request,f.baseline));
 }
 const expired=structuredClone(f.link);expired.successor.binding.interval.endsAt=new Date(Date.now()-1).toISOString();assert.throws(()=>f.a.createInitializedRecoveryRequest({...f,link:expired,launchNonce:id(),processID:id()}),/initialized_recovery_authorization_expired/);
});
test('historical recovery reader validates its consumed proof and cannot authorize old runner execution',async t=>{
 const f=await initializedFixture(t),old=await api();
 const manifest=JSON.parse(await readFile(join(f.parent,'recovery.json')));manifest.runnerHashes['tests/browser/staging-real-lifecycle.mjs']='9'.repeat(64);await write(join(f.parent,'recovery.json'),manifest);
 await assert.rejects(old.readRecoveryLink({config:config(f.config.runID,'c'),configPath:f.parentConfigPath,runDirectory:f.parent}),/recovery_source_mismatch/);
 await assert.rejects(old.readHistoricalRecovery({config:config(f.config.runID,'c'),configPath:f.parentConfigPath,runDirectory:f.parent}),/recovery_claim_mismatch/);
});

test('initialized runner rejects a missing manifest and inherited active lock without opening a browser',async t=>{
 preserveSessionMode(t);const {runStagingBrowserLifecycle,acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs');
 const f=await initializedFixture(t),lock=join(f.parent,'runner.lock');await acquireLifecycleLock(lock);
 await assert.rejects(runStagingBrowserLifecycle({...f,phase:'recover-initialized-bootstrap'}),/runner_already_active/);await assert.rejects(readFile(join(f.runDirectory,'owner.json')),{code:'ENOENT'});
 await rm(lock,{recursive:true});await rm(join(f.runDirectory,'initialized-recovery.json'));await assert.rejects(runStagingBrowserLifecycle({...f,phase:'recover-initialized-bootstrap'}),/initialized_recovery_manifest_required/);
});
test('initialized runner failure releases all four locks and never consumes the parent before actual admission',async t=>{
 preserveSessionMode(t);const previous=process.env.PLAYWRIGHT_MODULE;delete process.env.PLAYWRIGHT_MODULE;t.after(()=>{if(previous!==undefined)process.env.PLAYWRIGHT_MODULE=previous;});
 const f=await initializedFixture(t),{runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs');await assert.rejects(runStagingBrowserLifecycle({...f,phase:'recover-initialized-bootstrap'}),/real_phase_failed/);
 for(const dir of f.link.lockDirectories)await assert.rejects(readFile(join(dir,'runner.lock','owner.json')),{code:'ENOENT'});
 await assert.rejects(readFile(join(f.parent,'initialized-bootstrap-recovery-claim.json')),{code:'ENOENT'});for(const [path,bytes]of f.preserved)assert.deepEqual(await readFile(path),bytes);
});
test('initialized public evidence is redacted independently from its protected scope observations',()=>{
 const event={phase:'initialized_empty_bootstrap_admitted',evidenceClass:'INITIALIZED_EMPTY_BOOTSTRAP_RECOVERY',outcome:'PASS'};assert.deepEqual(redactedEvidence({...event,initialized:{secret:'no'},password:'no'}),event);
});

test('frozen historical runner bytes require the complete consumed admission and never enable public execution',async t=>{
 const f=await initializedFixture(t),old=await api(),args={config:config(f.config.runID,'c'),configPath:f.parentConfigPath,runDirectory:f.parent};
 const manifest=JSON.parse(await readFile(join(f.parent,'recovery.json'))),admission=JSON.parse(await readFile(join(f.parent,'recovery-admission.json'))),claimPath=join(f.predecessor,'partial-bootstrap-recovery-claim.json'),claim=JSON.parse(await readFile(claimPath));
 manifest.runnerHashes['tests/browser/staging-real-lifecycle.mjs']='9'.repeat(64);await write(join(f.parent,'recovery.json'),manifest);
 admission.request.runnerHashes=manifest.runnerHashes;admission.request.manifestSHA256=sha(json(manifest));const {checkpointSHA256,...body}=admission.request;admission.request.checkpointSHA256=digest(body);admission.proof.operator.checkpointSHA256=admission.request.checkpointSHA256;
 await write(join(f.parent,'recovery-admission.json'),admission);Object.assign(claim,{manifestSHA256:admission.request.manifestSHA256,checkpointSHA256:admission.request.checkpointSHA256,admissionSHA256:digest(admission)});await write(claimPath,claim);
 const historical=await old.readHistoricalRecovery(args);assert.equal(historical.consumed.request.sourceSHA,'c'.repeat(40));
 await assert.rejects(old.readRecoveryLink({...args,historical:true,frozen:true}),/recovery_source_mismatch/);
 await rm(claimPath);await assert.rejects(old.readHistoricalRecovery({...args,skipClaim:true}));
});
test('initialized claim binds request config and fresh nonce and denies replay across another target',async t=>{
 const f=await initializedFixture(t);for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 for(const patch of [{configSHA256:'0'.repeat(64)},{parentClaimSHA256:'0'.repeat(64)},{launchNonce:id()}])await assert.rejects(f.a.claimInitializedRecovery({...f,request:{...f.request,...patch}}));
 await assert.rejects(f.a.claimInitializedRecovery({...f,runDirectory:f.parent}));await assert.rejects(readFile(join(f.parent,'initialized-bootstrap-recovery-claim.json')),{code:'ENOENT'});
});

test('initialized admission accepts every existing required owner wrapper, including an older admitted owner device',async t=>{
 const f=await initializedFixture(t),second={membershipID:f.initialized.membershipID,membershipEpoch:1,deviceID:id()};
 f.manifest.initialized.requiredRecipients.push(second);f.manifest.initialized.wrappers.push({...second,wrapperSHA256:'5'.repeat(64)});await write(join(f.runDirectory,'initialized-recovery.json'),f.manifest);
 const link=await f.a.readInitializedRecoveryLink(f),request=f.a.createInitializedRecoveryRequest({...f,link,launchNonce:id(),processID:id()});
 const proof=structuredClone(f.proof);proof.initialized=structuredClone(link.initialized);proof.observedAt=new Date().toISOString();proof.successorBaseline.observedAt=proof.observedAt;for(const k of ['launchNonce','checkpointID','checkpointSHA256'])proof.operator[k]=request[k];
 assert.equal(f.a.validateInitializedRecoveryProof(proof,request,f.baseline).initialized.wrappers.length,2);
});

test('uploaded continuation retains strict initialized revision-one history and immutable expiry',async t=>{
 const f=await initializedFixture(t),uploaded=await import('../scripts/staging-uploaded-bootstrap-continuation.mjs');
 for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 await f.a.claimInitializedRecovery(f);
 assert.equal((await f.a.readHistoricalInitializedRecovery(f)).consumed.request.initialized.revision,1);
 assert.throws(()=>uploaded.assertUploadedInterval({startsAt:'2020-01-01T00:00:00.000Z',endsAt:'2020-01-02T00:00:00.000Z'}),/uploaded_authorization_expired/);
 const m=structuredClone(f.manifest);m.initialized.revision=2;await write(join(f.runDirectory,'initialized-recovery.json'),m);
 await assert.rejects(f.a.readHistoricalInitializedRecovery(f));
});

async function uploadedFixture(t){
 const f=await initializedFixture(t);for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}await f.a.claimInitializedRecovery(f);for(const dir of f.link.lockDirectories)await rm(join(dir,'runner.lock'),{recursive:true});
 const parent=f.runDirectory,parentConfigPath=f.configPath,nonce=f.request.launchNonce;
 const evidence=[{phase:'session_gate',testSessionMode:'PRESERVE_TRUSTED_STATE',launchNonce:nonce,outcome:'PASS'},{phase:'initialized_empty_browser_verified',outcome:'PASS',sha256:f.request.checkpointSHA256},{phase:'stopped_without_acceptance',stage:'team_bootstrap',browserIndex:0,launchNonce:nonce,outcome:'DENIED',failureCode:'legacy_roundtrip_failed'}];
 for(const [name,value]of Object.entries({'owner.json':{version:1,runID:f.config.runID,sourceSHA:f.config.expectedSourceSHA},'baseline.json':f.baseline,'journal.json':{version:1,completed:[],pending:null,processes:[],baseline:f.baseline},'evidence.json':evidence}))await write(join(parent,name),value);
 const runDirectory=join(f.dir,'uploaded'),current=config(f.config.runID,'e');await mkdir(runDirectory,{mode:0o700});const configPath=join(runDirectory,'config.json');await write(configPath,current);
 const parentFiles={};for(const name of ['config.json','owner.json','journal.json','evidence.json','baseline.json','initialized-recovery.json','initialized-recovery-admission.json'])parentFiles[name]=sha(await readFile(join(parent,name)));
 const uploaded={...f.initialized,revision:2,revisionCount:2,migrationCount:0,v2WrapperCount:0,revisionHistory:{revision1EnvelopeSHA256:f.initialized.envelopeSHA256,revision1RowSHA256:'a'.repeat(64),revision2RowSHA256:'b'.repeat(64)}};
 const expectedFixture={shapeVersion:1,documentSHA256:'c'.repeat(64),records:['credential','forwarding','host','snippet'].map(type=>({id:id(),type,canonicalSHA256:'d'.repeat(64)})).sort((a,b)=>a.id.localeCompare(b.id))};
 const observation={version:1,evidenceClass:f.manifest.evidenceClass,launchNonce:nonce,processID:f.request.processID,checkpointSHA256:f.request.checkpointSHA256,observation:{envelopeSHA256:f.initialized.envelopeSHA256,serverRevision:1,vaultID:f.initialized.created.vaults[0].vaultID}};
 const diagnostic={diagnosticOnly:true,readOnly:true,decryptedDocumentsEqual:true,localDocumentSHA256:expectedFixture.documentSHA256,remoteDocumentSHA256:expectedFixture.documentSHA256,remoteRevision:2,keyGeneration:1,rotationRequired:false,recordCount:4,tombstoneCount:0,teamID:uploaded.created.teamID,vaultID:uploaded.created.vaults[0].vaultID,deviceID:f.identities[0].deviceID,observedAt:new Date().toISOString()};
 const artifacts={};for(const [name,value]of Object.entries({initializedObservation:observation,diagnosis:diagnostic,records:{...diagnostic,records:expectedFixture.records},uploaded})){const path=join(parent,name+'.json');await write(path,value);artifacts[name]={path,sha256:sha(await readFile(path))};}
 const a=await import('../scripts/staging-uploaded-bootstrap-continuation.mjs'),manifest={version:1,evidenceClass:a.uploadedContinuationEvidenceClass,parentRunDirectory:parent,parentConfigPath,parentFiles,parentClaimSHA256:sha(await readFile(join(f.parent,'initialized-bootstrap-recovery-claim.json'))),configIdentitySHA256:continuation.continuationConfigIdentity(current),deployment:{sourceSHA:current.expectedSourceSHA,moduleHashesSHA256:digest(current.moduleHashes),imageDigest:'sha256:'+'e'.repeat(64),controllerSHA256:'e'.repeat(64)},runnerHashes:await a.uploadedContinuationRunnerHashes(),uploaded,expectedFixture,artifacts};
 await write(join(runDirectory,'uploaded-continuation.json'),manifest);
 const result={...f,a,config:current,configPath,runDirectory,parent,parentConfigPath,manifest,uploaded,expectedFixture};const link=await a.readUploadedContinuationLink(result),request=a.createUploadedContinuationRequest({...result,link,launchNonce:id(),processID:id(),identities:f.identities}),observedAt=new Date().toISOString(),b=request.successorBaseline;
 const proof={operator:{...Object.fromEntries(['version','runID','origin','sourceSHA','launchNonce','phase','checkpointID','checkpointSHA256'].map(k=>[k,request[k]])),ordinary:f.baseline,outbox:null},evidenceClass:manifest.evidenceClass,deployment:manifest.deployment,observedAt,uploaded:structuredClone(uploaded),successorBaseline:{authorizationSHA256:b.authorizationSHA256,approvalID:b.approvalID,originalSnapshotSHA256:b.originalSnapshotSHA256,observedSnapshotSHA256:b.successorSnapshotSHA256,scopeSHA256:b.scopeSHA256,observedAt}};
 return {...result,link,request,proof};
}
test('uploaded successor validates exact consumed history and claims exclusively across all five locks',async t=>{
 const f=await uploadedFixture(t);assert.equal(f.link.lockDirectories.length,5);assert.deepEqual(f.a.validateUploadedContinuationProof(f.proof,f.request,f.baseline),f.proof);
 await assert.rejects(f.a.claimUploadedContinuation(f),/uploaded_continuation_lock_required/);
 for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 const oldClaimPath=join(f.link.parent.parentDirectory,'initialized-bootstrap-recovery-claim.json'),oldClaim=await readFile(oldClaimPath);
 await f.a.claimUploadedContinuation(f);assert.deepEqual(await f.a.assertUploadedContinuationClaim(f),{request:f.request,proof:f.proof});await assert.rejects(f.a.claimUploadedContinuation(f),/uploaded_continuation_already_claimed/);assert.deepEqual(await readFile(oldClaimPath),oldClaim);
});
test('uploaded successor rejects history/source/fixture/admission mutations, no expected-list adaptation',async t=>{
 const f=await uploadedFixture(t),path=join(f.runDirectory,'uploaded-continuation.json');
 for(const mutate of [m=>m.parentClaimSHA256='0'.repeat(64),m=>m.configIdentitySHA256='0'.repeat(64),m=>m.runnerHashes['scripts/staging-uploaded-bootstrap-continuation.mjs']='0'.repeat(64),m=>m.uploaded.revision=1,m=>m.uploaded.revisionHistory.revision1EnvelopeSHA256='0'.repeat(64),m=>m.uploaded.revisionCount=3,m=>m.uploaded.migrationCount=1,m=>m.uploaded.v2WrapperCount=1,m=>m.uploaded.grantCount=1,m=>m.uploaded.invitationCount=1,m=>m.uploaded.vaultCount=2,m=>m.uploaded.ownerTrust.revoked=true,m=>m.uploaded.requiredRecipients=[],m=>m.expectedFixture.documentSHA256='0'.repeat(64),m=>m.expectedFixture.records[0].id=id(),m=>m.expectedFixture.records.reverse(),m=>m.artifacts.initializedObservation.sha256='0'.repeat(64)]){
  const m=structuredClone(f.manifest);mutate(m);await write(path,m);await assert.rejects(f.a.readUploadedContinuationLink(f));
 }
 await write(path,f.manifest);
 for(const [name,binding]of Object.entries(f.manifest.artifacts)){const original=await readFile(binding.path);await write(binding.path,{tampered:name});await assert.rejects(f.a.readUploadedContinuationLink(f));await writeFile(binding.path,original);}
 const old=await readFile(join(f.parent,'initialized-recovery-admission.json'));await write(join(f.parent,'initialized-recovery-admission.json'),{});await assert.rejects(f.a.readUploadedContinuationLink(f));await writeFile(join(f.parent,'initialized-recovery-admission.json'),old);
 await assert.rejects(readFile(join(f.parent,'uploaded-bootstrap-continuation-claim.json')),{code:'ENOENT'});
});
test('uploaded proof rejects changed actual graph, baseline, nonce, timestamp and encrypted history',async t=>{
 const f=await uploadedFixture(t);
 for(const mutate of [p=>p.uploaded.envelopeSHA256='0'.repeat(64),p=>p.uploaded.inventorySHA256='0'.repeat(64),p=>p.uploaded.revisionHistory.revision2RowSHA256='0'.repeat(64),p=>p.uploaded.wrappers[0].wrapperSHA256='0'.repeat(64),p=>p.deployment.sourceSHA='a'.repeat(40),p=>p.operator.launchNonce=id(),p=>p.operator.checkpointSHA256='0'.repeat(64),p=>p.successorBaseline.observedSnapshotSHA256='0'.repeat(64),p=>p.observedAt=new Date(Date.parse(f.request.requestedAt)-1).toISOString(),p=>p.observedAt=f.request.successorBaseline.interval.endsAt]){const proof=structuredClone(f.proof);mutate(proof);assert.throws(()=>f.a.validateUploadedContinuationProof(proof,f.request,f.baseline));}
});
test('uploaded expired admission cannot claim; a consumed claim remains retained after expiry',async t=>{
 const f=await uploadedFixture(t);for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 await f.a.claimUploadedContinuation(f);const path=join(f.parent,'uploaded-bootstrap-continuation-claim.json'),before=await readFile(path);
 t.mock.timers.enable({apis:['Date'],now:Date.parse(f.link.successor.binding.interval.endsAt)});
 assert.throws(()=>f.a.createUploadedContinuationRequest({...f,launchNonce:id(),processID:id(),identities:f.identities}),/uploaded_authorization_expired/);await assert.rejects(f.a.claimUploadedContinuation(f),/uploaded_authorization_expired/);assert.deepEqual(await readFile(path),before);
});

test('uploaded expiry after a fresh valid proof leaves no new claim or admission',async t=>{
 const f=await uploadedFixture(t);for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 f.a.validateUploadedContinuationProof(f.proof,f.request,f.baseline);t.mock.timers.enable({apis:['Date'],now:Date.parse(f.link.successor.binding.interval.endsAt)});
 await assert.rejects(f.a.claimUploadedContinuation(f),/uploaded_authorization_expired/);
 await assert.rejects(readFile(join(f.parent,'uploaded-bootstrap-continuation-claim.json')),{code:'ENOENT'});await assert.rejects(readFile(join(f.runDirectory,'uploaded-continuation-admission.json')),{code:'ENOENT'});
});
test('uploaded runner refuses inherited locks or missing manifest and releases ancestors without claiming',{timeout:10000},async t=>{
 preserveSessionMode(t);const previous=process.env.PLAYWRIGHT_MODULE;delete process.env.PLAYWRIGHT_MODULE;t.after(()=>{if(previous===undefined)delete process.env.PLAYWRIGHT_MODULE;else process.env.PLAYWRIGHT_MODULE=previous;});const f=await uploadedFixture(t),{runStagingBrowserLifecycle,acquireLifecycleLock}=await import('./browser/staging-real-lifecycle.mjs');
 const lock=join(f.parent,'runner.lock');await acquireLifecycleLock(lock);await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-uploaded-bootstrap'}),/runner_already_active/);await rm(lock,{recursive:true});
 for(const dir of f.link.lockDirectories.slice(0,-1))await assert.rejects(readFile(join(dir,'runner.lock','owner.json')),{code:'ENOENT'});
 await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-uploaded-bootstrap'}),/real_phase_failed/);
 const evidence=JSON.parse(await readFile(join(f.runDirectory,'evidence.json')));assert.equal(evidence.at(-1).phase,'stopped_without_acceptance');assert.equal(evidence.some(e=>['process_started','owner_input_pending','uploaded_bootstrap_admitted'].includes(e.phase)),false);
 await assert.rejects(readFile(join(f.runDirectory,'uploaded-continuation-admission.json')),{code:'ENOENT'});
 await assert.rejects(readFile(join(f.parent,'uploaded-bootstrap-continuation-claim.json')),{code:'ENOENT'});
 for(const dir of f.link.lockDirectories)await assert.rejects(readFile(join(dir,'runner.lock','owner.json')),{code:'ENOENT'});
 await rm(join(f.runDirectory,'uploaded-continuation.json'));await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-uploaded-bootstrap'}),/uploaded_continuation_manifest_required/);
});

test('uploaded admission ordering leaves actual exclusive claim absent on inspection failure and claims only after success',async t=>{
 const f=await uploadedFixture(t),{inspectThenClaimUploaded}=await import('./browser/staging-real-lifecycle.mjs');
 for(const dir of f.link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{pid:process.pid});}
 const events=[],claim=async()=>{events.push('claim');return f.a.claimUploadedContinuation(f);};
 await assert.rejects(inspectThenClaimUploaded({interval:f.link.successor.binding.interval,inspect:async()=>{events.push('denied');throw Error('uploaded_bootstrap_changed');},claim}),/uploaded_bootstrap_changed/);
 assert.deepEqual(events,['denied']);await assert.rejects(readFile(join(f.parent,'uploaded-bootstrap-continuation-claim.json')),{code:'ENOENT'});await assert.rejects(readFile(join(f.runDirectory,'uploaded-continuation-admission.json')),{code:'ENOENT'});
 await inspectThenClaimUploaded({interval:f.link.successor.binding.interval,inspect:async()=>{events.push('verified');},claim});assert.deepEqual(events,['denied','verified','claim']);assert.deepEqual(await f.a.assertUploadedContinuationClaim(f),{request:f.request,proof:f.proof});
});

async function uploadedRenewalFixture(t){
 const f=await uploadedFixture(t),old=f.runDirectory,requestName='uploaded-continuation-request-'+f.request.launchNonce+'.json';
 const evidence=[];for(const [browserIndex,identity]of f.identities.entries()){const pid=2147483647;evidence.push({phase:'process_started',browserIndex,pid,processID:f.request.processID,launchNonce:f.request.launchNonce,outcome:'PASS'},{...identity,phase:'continuation_readiness',stage:'diagnostic_trust',browserIndex,launchNonce:f.request.launchNonce},{phase:'process_closed',browserIndex,pid,processID:f.request.processID,launchNonce:f.request.launchNonce,outcome:'PASS'});}
 evidence.push({phase:'uploaded-continuation_operator_proof_pending',evidenceClass:f.manifest.evidenceClass,runID:f.config.runID,expectedSourceSHA:f.config.expectedSourceSHA,previousLaunchNonce:f.link.admission.request.launchNonce,launchNonce:f.request.launchNonce,checkpointID:f.request.checkpointID,checkpointSHA256:f.request.checkpointSHA256,outcome:'PENDING'},{phase:'owner_input_pending',outcome:'PENDING'});
 for(const [name,value]of Object.entries({'owner.json':{version:1,runID:f.config.runID,sourceSHA:f.config.expectedSourceSHA},'baseline.json':f.baseline,'journal.json':{version:1,completed:[],pending:null,processes:[],baseline:f.baseline},'evidence.json':evidence,[requestName]:f.request}))await write(join(old,name),value);
 const names=['config.json','owner.json','journal.json','baseline.json','evidence.json','uploaded-continuation.json',requestName],predecessorFiles={};for(const n of names)predecessorFiles[n]=sha(await readFile(join(old,n)));
 const originalLockDirectories=[...f.link.lockDirectories],archiveRoot=join(f.dir,'archived-locks');await mkdir(archiveRoot,{mode:0o700});const entries=[];
 const meta=s=>({dev:s.dev,ino:s.ino,uid:s.uid,gid:s.gid,mode:s.mode&0o777,nlink:s.nlink,size:s.size});
 for(const [i,dir]of originalLockDirectories.entries()){
  const from=join(dir,'runner.lock'),to=join(archiveRoot,String(i)+'-runner.lock');await mkdir(from,{mode:0o700});await write(join(from,'owner.json'),{version:1,pid:2147483647,processID:id()});const ownerSHA256=sha(await readFile(join(from,'owner.json'))),directory=meta(await lstat(from)),owner=meta(await lstat(join(from,'owner.json')));await rename(from,to);entries.push({originalDirectory:from,archiveDirectory:to,ownerSHA256,directory,owner});
 }
 t.mock.timers.enable({apis:['Date'],now:Date.parse(f.link.successor.binding.interval.endsAt)+1000});
 const capturedAt=new Date().toISOString(),archivePath=join(archiveRoot,'attestation.json'),archive={version:1,kind:'VERIFIED_STALE_LOCK_ARCHIVE',archivedAt:capturedAt,entries};await write(archivePath,archive);
 const runDirectory=join(f.dir,'uploaded-renewal'),current=config(f.config.runID,'f');await mkdir(runDirectory,{mode:0o700});const configPath=join(runDirectory,'config.json');await write(configPath,current);
 const manifest={...structuredClone(f.manifest),configIdentitySHA256:continuation.continuationConfigIdentity(current),deployment:{sourceSHA:current.expectedSourceSHA,moduleHashesSHA256:digest(current.moduleHashes),imageDigest:'sha256:'+'f'.repeat(64),controllerSHA256:'f'.repeat(64)},runnerHashes:await f.a.uploadedSuccessorRunnerHashes()};
 const sourceSnapshot=join(f.link.parent.parent.predecessorDirectory,'ordinary-successor-snapshot.json');const raw=await readFile(sourceSnapshot);assert.equal(sha(raw),f.baseline.sha256);
 for(const n of ['ordinary-original-snapshot.json','ordinary-successor-snapshot.json'])await writeFile(join(runDirectory,n),raw,{mode:0o600});
 const capturePath=join(runDirectory,'capture-observation.json'),capture={version:1,kind:'READ_ONLY_UPLOADED_SUCCESSOR_CAPTURE',capturedAt,readOnly:true,deployment:f.manifest.deployment,previousSnapshotSHA256:f.baseline.sha256,snapshotSHA256:f.baseline.sha256,scopeSHA256:f.link.successor.binding.scopeSHA256,uploadedSHA256:digest(f.uploaded),fixtureSHA256:digest(f.expectedFixture),testInventorySHA256:'9'.repeat(64)};await write(capturePath,capture);
 const renewal={version:1,capturedAt,predecessorRunDirectory:old,predecessorConfigPath:f.configPath,predecessorFiles,requestName,archive:{path:archivePath,sha256:sha(json(archive))},capture:{path:capturePath,sha256:sha(json(capture))}};
 const recoveryContext={kind:'UPLOADED_UNCLAIMED_SUCCESSOR',predecessorRunDirectory:old,predecessorFilesSHA256:digest(predecessorFiles),parentClaimSHA256:manifest.parentClaimSHA256,predecessorAuthorizationSHA256:f.link.successor.binding.authorizationSHA256,predecessorSnapshotSHA256:f.baseline.sha256,uploadedSHA256:digest(f.uploaded),fixtureSHA256:digest(f.expectedFixture),archiveSHA256:renewal.archive.sha256,captureSHA256:renewal.capture.sha256,capturedAt};
 const failedComparisons=[{path:capturePath,sha256:renewal.capture.sha256}],authorization={version:1,kind:'OWNER_AUTHORIZED_SUCCESSOR_ORDINARY_BASELINE',approved:true,approvalID:id(),approvedAt:capturedAt,interval:{startsAt:capturedAt,endsAt:new Date(Date.now()+3600000).toISOString()},originalRunID:f.config.runID,originalSourceSHA:f.config.expectedSourceSHA,successorRunID:current.runID,successorSourceSHA:current.expectedSourceSHA,configIdentitySHA256:manifest.configIdentitySHA256,originalFiles:predecessorFiles,deployment:manifest.deployment,runnerHashes:manifest.runnerHashes,originalSnapshotSHA256:f.baseline.sha256,successorSnapshotSHA256:f.baseline.sha256,failedComparisons,recoveryContext};await write(join(runDirectory,'ordinary-successor-authorization.json'),authorization);
 renewal.successorBaseline={version:1,originalSnapshot:{name:'ordinary-original-snapshot.json',sha256:f.baseline.sha256},successorSnapshot:{name:'ordinary-successor-snapshot.json',sha256:f.baseline.sha256},ownerAuthorization:{name:'ordinary-successor-authorization.json',sha256:sha(json(authorization))},failedComparisons};manifest.renewal=renewal;await write(join(runDirectory,'uploaded-continuation.json'),manifest);
 return {...f,config:current,configPath,runDirectory,manifest,old,oldConfig:f.config,oldConfigPath:f.configPath,oldLink:f.link,oldRequest:f.request,archive,archivePath,authorization,capture,capturePath,recoveryContext};
}
test('explicit uploaded renewal accepts actual fresh same-SHA capture while historical interval remains expired',async t=>{
 const f=await uploadedRenewalFixture(t),link=await f.a.readUploadedContinuationLink(f);assert.equal(link.lockDirectories.length,6);assert.deepEqual(link.renewalContext,f.recoveryContext);assert.equal(link.baseline.sha256,f.baseline.sha256);assert.notEqual(link.successor.binding.approvalID,f.oldLink.successor.binding.approvalID);
 const request=f.a.createUploadedContinuationRequest({...f,link,launchNonce:id(),processID:id()});assert.deepEqual(request.renewalContext,f.recoveryContext);assert.equal(request.successorBaseline.interval.startsAt,f.capture.capturedAt);
 assert.throws(()=>f.a.createUploadedContinuationRequest({...f,config:f.oldConfig,link:f.oldLink,launchNonce:id(),processID:id()}),/uploaded_authorization_expired/);
 for(const entry of f.archive.entries)assert.equal(sha(await readFile(join(entry.archiveDirectory,'owner.json'))),entry.ownerSHA256);
});
function uploadedRenewalProof(f,link,request){
 const proof=structuredClone(f.proof),observedAt=new Date().toISOString(),b=request.successorBaseline;proof.deployment=request.deployment;proof.observedAt=observedAt;proof.operator.ordinary=link.baseline;for(const k of ['sourceSHA','launchNonce','checkpointID','checkpointSHA256'])proof.operator[k]=request[k];proof.successorBaseline={authorizationSHA256:b.authorizationSHA256,approvalID:b.approvalID,originalSnapshotSHA256:b.originalSnapshotSHA256,observedSnapshotSHA256:b.successorSnapshotSHA256,scopeSHA256:b.scopeSHA256,observedAt};return proof;
}
test('renewed run revalidates protected history only after all six ordinary locks and before browser',async t=>{
 const f=await uploadedRenewalFixture(t),link=await f.a.readUploadedContinuationLink(f),options={...f,link};
 assert.equal(typeof f.a.revalidateUploadedSuccessorAfterLocks,'function');
 await assert.rejects(f.a.revalidateUploadedSuccessorAfterLocks(options),/lock_required/);
 for(const dir of link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{version:1,pid:process.pid,processID:id()});}
 assert.equal((await f.a.revalidateUploadedSuccessorAfterLocks(options)).manifestSHA256,link.manifestSHA256);
 const old=join(f.old,'evidence.json');await write(old,[]);await assert.rejects(f.a.revalidateUploadedSuccessorAfterLocks(options));
});
test('renewed request proof and one original claim slot bind active authority and retain archive',async t=>{
 const f=await uploadedRenewalFixture(t),link=await f.a.readUploadedContinuationLink(f),request=f.a.createUploadedContinuationRequest({...f,link,launchNonce:id(),processID:id()}),proof=uploadedRenewalProof(f,link,request);
 f.a.validateUploadedContinuationProof(proof,request,link.baseline);for(const dir of link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{version:1,pid:process.pid,processID:id()});}
 await f.a.claimUploadedContinuation({...f,link,request,proof});const fresh=await f.a.readUploadedContinuationLink(f);assert.deepEqual(await f.a.assertUploadedContinuationClaim({...f,link:fresh}),{request,proof});await assert.rejects(f.a.claimUploadedContinuation({...f,link,request,proof}),/already_claimed/);
 for(const e of f.archive.entries)assert.equal(sha(await readFile(join(e.archiveDirectory,'owner.json'))),e.ownerSHA256);
 const changed=structuredClone(request);changed.renewalContext.captureSHA256='1'.repeat(64);const {checkpointSHA256,...body}=changed;changed.checkpointSHA256=digest(body);await assert.rejects(f.a.claimUploadedContinuation({...f,link,request:changed,proof}));
});
test('renewal denies changed interrupted bytes, old proof or scope, completed state and live archive owner',async t=>{
 const f=await uploadedRenewalFixture(t),path=join(f.runDirectory,'uploaded-continuation.json');
 for(const edit of [m=>m.renewal.predecessorFiles['evidence.json']='0'.repeat(64),m=>m.renewal.capture.sha256='0'.repeat(64),m=>m.renewal.archive.sha256='0'.repeat(64),m=>m.renewal.predecessorRunDirectory=f.runDirectory,m=>m.runnerHashes['scripts/staging-uploaded-successor.mjs']='0'.repeat(64)]){const m=structuredClone(f.manifest);edit(m);await write(path,m);await assert.rejects(f.a.readUploadedContinuationLink(f));}await write(path,f.manifest);
 for(const n of ['scope.json','uploaded-continuation-admission.json','uploaded-continuation-proof-'+f.oldRequest.launchNonce+'.json']){await write(join(f.old,n),{});await assert.rejects(f.a.readUploadedContinuationLink(f));await rm(join(f.old,n));}
 const ownerPath=join(f.archive.entries[0].archiveDirectory,'owner.json'),before=await readFile(ownerPath);await write(ownerPath,{version:1,pid:process.pid,processID:id()});await assert.rejects(f.a.readUploadedContinuationLink(f));await writeFile(ownerPath,before);
 const journal=join(f.old,'journal.json'),raw=await readFile(journal);await write(journal,{version:1,completed:['bootstrap'],pending:null,processes:[],baseline:f.baseline});await assert.rejects(f.a.readUploadedContinuationLink(f));await writeFile(journal,raw);
 await assert.rejects(readFile(join(f.parent,'uploaded-bootstrap-continuation-claim.json')),{code:'ENOENT'});
});
test('new interval expiration after fresh proof creates no claim and leaves archived locks intact',async t=>{
 const f=await uploadedRenewalFixture(t),link=await f.a.readUploadedContinuationLink(f),request=f.a.createUploadedContinuationRequest({...f,link,launchNonce:id(),processID:id()}),proof=uploadedRenewalProof(f,link,request);
 for(const dir of link.lockDirectories){await mkdir(join(dir,'runner.lock'),{mode:0o700});await write(join(dir,'runner.lock','owner.json'),{version:1,pid:process.pid,processID:id()});}
 t.mock.timers.setTime(Date.parse(link.successor.binding.interval.endsAt));await assert.rejects(f.a.claimUploadedContinuation({...f,link,request,proof}),/expired/);await assert.rejects(readFile(join(f.parent,'uploaded-bootstrap-continuation-claim.json')),{code:'ENOENT'});for(const e of f.archive.entries)assert.equal(sha(await readFile(join(e.archiveDirectory,'owner.json'))),e.ownerSHA256);
});
async function resealRenewalFixture(f){
 const r=f.manifest.renewal;r.archive.sha256=sha(await readFile(r.archive.path));r.capture.sha256=sha(await readFile(r.capture.path));
 for(const name of Object.keys(r.predecessorFiles))r.predecessorFiles[name]=sha(await readFile(name==='config.json'?r.predecessorConfigPath:join(r.predecessorRunDirectory,name)));
 Object.assign(f.authorization.recoveryContext,{predecessorFilesSHA256:digest(r.predecessorFiles),archiveSHA256:r.archive.sha256,captureSHA256:r.capture.sha256});f.authorization.originalFiles=r.predecessorFiles;
 await write(join(f.runDirectory,'ordinary-successor-authorization.json'),f.authorization);r.successorBaseline.ownerAuthorization.sha256=sha(json(f.authorization));await write(join(f.runDirectory,'uploaded-continuation.json'),f.manifest);
}
test('self-consistent rehashed renewal cannot reuse old approval or widen authorized interval',async t=>{
 const f=await uploadedRenewalFixture(t),saved=structuredClone(f.authorization);
 for(const edit of [a=>a.approved=false,a=>a.approvalID=f.oldLink.successor.binding.approvalID,a=>a.interval.startsAt=new Date(Date.parse(f.capture.capturedAt)+1).toISOString(),a=>a.interval.endsAt=new Date(Date.parse(f.capture.capturedAt)+86400001).toISOString(),a=>a.recoveryContext.predecessorAuthorizationSHA256='0'.repeat(64)]){f.authorization=structuredClone(saved);edit(f.authorization);await resealRenewalFixture(f);await assert.rejects(f.a.readUploadedContinuationLink(f));}
});
test('self-consistent interrupted journal or request change is rejected beyond raw hash checks',async t=>{
 const f=await uploadedRenewalFixture(t),journal=join(f.old,'journal.json'),raw=await readFile(journal);await write(journal,{version:1,completed:['bootstrap'],pending:null,processes:[],baseline:f.baseline});await resealRenewalFixture(f);await assert.rejects(f.a.readUploadedContinuationLink(f));await writeFile(journal,raw);
 const requestPath=join(f.old,f.manifest.renewal.requestName),request=structuredClone(f.oldRequest);request.expectedFixture.documentSHA256='0'.repeat(64);const {checkpointSHA256,...body}=request;request.checkpointSHA256=digest(body);await write(requestPath,request);await resealRenewalFixture(f);await assert.rejects(f.a.readUploadedContinuationLink(f));
});
test('self-consistent archive with live owner PID is denied without deleting any lock',async t=>{
 const f=await uploadedRenewalFixture(t),entry=f.archive.entries[0],path=join(entry.archiveDirectory,'owner.json');await write(path,{version:1,pid:process.pid,processID:id()});const s=await lstat(path);entry.owner={dev:s.dev,ino:s.ino,uid:s.uid,gid:s.gid,mode:s.mode&0o777,nlink:s.nlink,size:s.size};entry.ownerSHA256=sha(await readFile(path));await write(f.archivePath,f.archive);await resealRenewalFixture(f);await assert.rejects(f.a.readUploadedContinuationLink(f));assert.equal(JSON.parse(await readFile(path)).pid,process.pid);
});
test('renewal uses standard ancestor lock exclusion and never opens a browser on collision',{timeout:10000},async t=>{
 preserveSessionMode(t);const previous=process.env.PLAYWRIGHT_MODULE;delete process.env.PLAYWRIGHT_MODULE;t.after(()=>{if(previous===undefined)delete process.env.PLAYWRIGHT_MODULE;else process.env.PLAYWRIGHT_MODULE=previous;});
 const f=await uploadedRenewalFixture(t),link=await f.a.readUploadedContinuationLink(f),{acquireLifecycleLock,runStagingBrowserLifecycle}=await import('./browser/staging-real-lifecycle.mjs');
 const lock=join(link.lockDirectories[0],'runner.lock');await acquireLifecycleLock(lock);const held=await readFile(join(lock,'owner.json'));await assert.rejects(runStagingBrowserLifecycle({...f,phase:'continue-uploaded-bootstrap'}),/runner_already_active/);assert.deepEqual(await readFile(join(lock,'owner.json')),held);await assert.rejects(readFile(join(f.runDirectory,'owner.json')),{code:'ENOENT'});for(const entry of f.archive.entries)assert.equal(sha(await readFile(join(entry.archiveDirectory,'owner.json'))),entry.ownerSHA256);
});

test('rehashed interrupted readiness must retain diagnostic-trust custodian semantics',async t=>{
 const f=await uploadedRenewalFixture(t),path=join(f.old,'evidence.json'),original=JSON.parse(await readFile(path));
 for(const patch of [{stage:'diagnostic_session'},{rootStatus:'ADMITTED'},{rootStatus:'UNKNOWN'},{stage:undefined}]){const evidence=structuredClone(original);Object.assign(evidence[1],patch);await write(path,evidence);await resealRenewalFixture(f);await assert.rejects(f.a.readUploadedContinuationLink(f),/uploaded_successor_invalid/);}
});
