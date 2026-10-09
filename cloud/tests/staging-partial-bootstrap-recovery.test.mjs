import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,readFile,rm,realpath,symlink} from 'node:fs/promises';
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
