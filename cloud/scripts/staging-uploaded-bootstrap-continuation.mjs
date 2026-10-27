// One consumed initialized attempt whose populated upload completed; no replay or renewal.
import {readFile,lstat} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {readProtectedBytes,readProtectedJSON,assertProtectedDirectory,validateRunConfig,validateOperatorProof} from './staging-publication-acceptance.mjs';
import {continuationConfigIdentity,writeContinuationExclusive} from './staging-bootstrap-continuation.mjs';
import {readHistoricalInitializedRecovery,initializedRecoveryRunnerHashes} from './staging-initialized-bootstrap-recovery.mjs';
import {validateSuccessorProof} from './staging-successor-baseline.mjs';
import {diagnosticProfileReady} from './staging-lifecycle-diagnostics.mjs';

export const uploadedContinuationEvidenceClass='UPLOADED_V1_BOOTSTRAP_CONTINUATION';
const fail=code=>{throw Error(code);},hash=/^[a-f0-9]{64}$/,uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
const equal=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b),sha=v=>createHash('sha256').update(v).digest('hex');
export const uploadedContinuationDigest=v=>sha(canonicalMigrationJSON(v));
const digest=uploadedContinuationDigest,timestamp=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
const parentNames=['config.json','owner.json','journal.json','evidence.json','baseline.json','initialized-recovery.json','initialized-recovery-admission.json'];
const claimName='uploaded-bootstrap-continuation-claim.json',admissionName='uploaded-continuation-admission.json';
const recipientKeys=['membershipID','membershipEpoch','deviceID'];
const uploadedKeys=['created','membershipID','membershipEpoch','automaticDeviceAdmission','revision','keyGeneration','rotationRequired','formatState','activated','v2Pointer','ownedTeamCount','membershipCount','vaultCount','invitationCount','grantCount','publicationCount','inventorySHA256','envelopeSHA256','wrappers','requiredRecipients','ownerTrust','revisionCount','migrationCount','v2WrapperCount','revisionHistory'];
export async function uploadedContinuationRunnerHashes(){return {...await initializedRecoveryRunnerHashes(),'scripts/staging-uploaded-bootstrap-continuation.mjs':sha(await readFile(new URL('./staging-uploaded-bootstrap-continuation.mjs',import.meta.url)))};}
async function absent(path){try{await lstat(path);}catch(error){if(error.code==='ENOENT')return;throw error;}fail('uploaded_continuation_partial_scope');}
async function pinned(path,expected){if(!hash.test(expected))fail('uploaded_continuation_history_changed');const bytes=await readProtectedBytes(path);if(sha(bytes)!==expected)fail('uploaded_continuation_history_changed');return JSON.parse(bytes);}
export function assertUploadedInterval(interval){const now=new Date().toISOString();if(!exact(interval,['startsAt','endsAt'])||!timestamp(interval.startsAt)||!timestamp(interval.endsAt)||now<interval.startsAt||now>=interval.endsAt)fail('uploaded_authorization_expired');}
function inInterval(binding){assertUploadedInterval(binding.interval);}
function validateUploaded(v,partial,accounts){
 if(!exact(v,uploadedKeys)||!equal(v.created,partial.created)||v.membershipID!==partial.membershipID||v.membershipEpoch!==1||v.automaticDeviceAdmission!==true||v.revision!==2||v.keyGeneration!==1||v.rotationRequired!==false||v.formatState!=='V1_ACTIVE'||v.activated!==false||v.v2Pointer!==null
  ||['ownedTeamCount','membershipCount','vaultCount'].some(k=>v[k]!==1)||['invitationCount','grantCount','publicationCount'].some(k=>v[k]!==0)||!hash.test(v.inventorySHA256)||!hash.test(v.envelopeSHA256)||v.revisionCount!==2||v.migrationCount!==0||v.v2WrapperCount!==0||!exact(v.revisionHistory,['revision1EnvelopeSHA256','revision1RowSHA256','revision2RowSHA256'])||Object.values(v.revisionHistory).some(x=>!hash.test(x)))fail('uploaded_continuation_scope_changed');
 const trust=v.ownerTrust,owner=accounts[0];
 if(!exact(trust,['accountID','deviceID','rootFingerprint','publicKeyFingerprint','admitted','revoked','signedDirectorySHA256','certificateSHA256'])||['accountID','deviceID','rootFingerprint','publicKeyFingerprint'].some(k=>trust[k]!==owner[k])||trust.admitted!==true||trust.revoked!==false||!hash.test(trust.signedDirectorySHA256)||!hash.test(trust.certificateSHA256))fail('uploaded_continuation_identity_mismatch');
 if(!Array.isArray(v.requiredRecipients)||!v.requiredRecipients.length||!Array.isArray(v.wrappers)||v.wrappers.length!==v.requiredRecipients.length)fail('uploaded_continuation_recipients_changed');
 for(const recipients of [v.requiredRecipients,v.wrappers]){
  if(new Set(recipients.map(r=>r.deviceID)).size!==recipients.length)fail('uploaded_continuation_recipients_changed');
  for(const r of recipients)if(!exact(r,recipients===v.wrappers?[...recipientKeys,'wrapperSHA256']:recipientKeys)||r.membershipID!==v.membershipID||r.membershipEpoch!==1||!uuid.test(r.deviceID)||recipients===v.wrappers&&!hash.test(r.wrapperSHA256))fail('uploaded_continuation_recipients_changed');
 }
 const tuples=rows=>rows.map(r=>Object.fromEntries(recipientKeys.map(k=>[k,r[k]]))).sort((a,b)=>a.deviceID.localeCompare(b.deviceID));
 if(!equal(tuples(v.requiredRecipients),tuples(v.wrappers))||!v.requiredRecipients.some(r=>r.deviceID===owner.deviceID))fail('uploaded_continuation_recipients_changed');
}
function validateFixture(v){
 if(!exact(v,['shapeVersion','documentSHA256','records'])||v.shapeVersion!==1||!hash.test(v.documentSHA256)||!Array.isArray(v.records)||v.records.length!==4||new Set(v.records.map(r=>r.id)).size!==4||!equal(v.records.map(r=>r.type).sort(),['credential','forwarding','host','snippet'])||!equal(v.records,[...v.records].sort((a,b)=>a.id.localeCompare(b.id)))||v.records.some(r=>!exact(r,['id','type','canonicalSHA256'])||!uuid.test(r.id)||!hash.test(r.canonicalSHA256)))fail('uploaded_continuation_fixture_changed');
}
export async function readUploadedContinuationLink({config,configPath,runDirectory}){
 validateRunConfig(config);await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);
 const bytes=await readProtectedBytes(join(runDirectory,'uploaded-continuation.json')),manifest=JSON.parse(bytes),configBytes=await readProtectedBytes(configPath);
 if(!exact(manifest,['version','evidenceClass','parentRunDirectory','parentConfigPath','parentFiles','parentClaimSHA256','configIdentitySHA256','deployment','runnerHashes','uploaded','expectedFixture','artifacts'])||manifest.version!==1||manifest.evidenceClass!==uploadedContinuationEvidenceClass||manifest.configIdentitySHA256!==continuationConfigIdentity(config)||!equal(manifest.runnerHashes,await uploadedContinuationRunnerHashes())||!equal(JSON.parse(configBytes),config))fail('uploaded_continuation_source_mismatch');
 const d=manifest.deployment;
 if(!exact(d,['sourceSHA','moduleHashesSHA256','imageDigest','controllerSHA256'])||d.sourceSHA!==config.expectedSourceSHA||d.moduleHashesSHA256!==digest(config.moduleHashes)||!/^sha256:[a-f0-9]{64}$/.test(d.imageDigest)||!hash.test(d.controllerSHA256))fail('uploaded_continuation_source_mismatch');
 const parentDirectory=manifest.parentRunDirectory;await assertProtectedDirectory(dirname(parentDirectory));await assertProtectedDirectory(parentDirectory);
 if(parentDirectory===runDirectory||!exact(manifest.parentFiles,parentNames))fail('uploaded_continuation_history_changed');
 const values={};for(const name of parentNames)values[name]=await pinned(name==='config.json'?manifest.parentConfigPath:join(parentDirectory,name),manifest.parentFiles[name]);
 const parentConfig=validateRunConfig(values['config.json']);
 if(parentConfig.runID!==config.runID||parentConfig.expectedSourceSHA===config.expectedSourceSHA||parentConfig.origin!==config.origin||!equal(parentConfig.emails.map(v=>v.toLowerCase()),config.emails.map(v=>v.toLowerCase()))||parentConfig.approvedVaultIDs.length)fail('uploaded_continuation_source_mismatch');
 await absent(join(parentDirectory,'scope.json'));await absent(join(parentDirectory,'uploaded-continuation.json'));
 const parent=await readHistoricalInitializedRecovery({config:parentConfig,configPath:manifest.parentConfigPath,runDirectory:parentDirectory});
 await pinned(join(parent.parentDirectory,'initialized-bootstrap-recovery-claim.json'),manifest.parentClaimSHA256);
 const {baseline,profiles,accounts,successor}=parent,owner=values['owner.json'],journal=values['journal.json'],evidence=values['evidence.json'];
 if(!exact(owner,['version','runID','sourceSHA'])||owner.version!==1||owner.runID!==config.runID||owner.sourceSHA!==parentConfig.expectedSourceSHA||!exact(journal,['version','completed','pending','processes','baseline'])||journal.version!==1||!Array.isArray(journal.completed)||journal.completed.length||journal.pending!==null||!Array.isArray(journal.processes)||journal.processes.length||!equal(journal.baseline,baseline)||!equal(values['baseline.json'],baseline))fail('uploaded_continuation_partial_scope');
 const failed=Array.isArray(evidence)&&evidence.findLast(v=>v.phase==='stopped_without_acceptance'),nonce=parent.consumed.request.launchNonce;
 if(!failed||failed.outcome!=='DENIED'||failed.stage!=='team_bootstrap'||failed.browserIndex!==0||failed.failureCode!=='legacy_roundtrip_failed'||failed.launchNonce!==nonce||evidence.some(v=>v.phase==='phase_completed')||!evidence.some(v=>v.phase==='session_gate'&&v.launchNonce===nonce&&v.testSessionMode==='PRESERVE_TRUSTED_STATE'&&v.outcome==='PASS')||!evidence.some(v=>v.phase==='initialized_empty_browser_verified'&&v.outcome==='PASS'&&v.sha256===parent.consumed.request.checkpointSHA256))fail('uploaded_continuation_partial_scope');
 validateUploaded(manifest.uploaded,parent.initialized,accounts);validateFixture(manifest.expectedFixture);
 if(manifest.uploaded.revisionHistory.revision1EnvelopeSHA256!==parent.consumed.request.initialized.envelopeSHA256||['wrappers','requiredRecipients','ownerTrust'].some(k=>!equal(manifest.uploaded[k],parent.initialized[k])))fail('uploaded_continuation_history_changed');
 if(!exact(manifest.artifacts,['initializedObservation','diagnosis','records','uploaded']))fail('uploaded_continuation_history_changed');
 const artifacts={};for(const [name,binding]of Object.entries(manifest.artifacts)){if(!exact(binding,['path','sha256']))fail('uploaded_continuation_history_changed');artifacts[name]=await pinned(binding.path,binding.sha256);}
 const observation=artifacts.initializedObservation;
 if(observation.version!==1||observation.evidenceClass!=='INITIALIZED_EMPTY_BOOTSTRAP_RECOVERY'||observation.launchNonce!==nonce||observation.processID!==parent.consumed.request.processID||observation.checkpointSHA256!==parent.consumed.request.checkpointSHA256||observation.observation?.envelopeSHA256!==parent.initialized.envelopeSHA256||observation.observation?.serverRevision!==1||observation.observation?.vaultID!==parent.initialized.created.vaults[0].vaultID)fail('uploaded_continuation_history_changed');
 for(const value of [artifacts.diagnosis,artifacts.records])if(value.readOnly!==true||value.diagnosticOnly!==true||value.decryptedDocumentsEqual!==true||value.localDocumentSHA256!==manifest.expectedFixture.documentSHA256||value.remoteDocumentSHA256!==manifest.expectedFixture.documentSHA256||value.remoteRevision!==2||value.keyGeneration!==1||value.rotationRequired!==false||value.recordCount!==4||value.tombstoneCount!==0||value.teamID!==manifest.uploaded.created.teamID||value.vaultID!==manifest.uploaded.created.vaults[0].vaultID||value.deviceID!==accounts[0].deviceID)fail('uploaded_continuation_fixture_changed');
 if(!timestamp(artifacts.diagnosis.observedAt)||!timestamp(artifacts.records.observedAt)||artifacts.records.observedAt<artifacts.diagnosis.observedAt||!equal([...artifacts.records.records].sort((a,b)=>a.id.localeCompare(b.id)),manifest.expectedFixture.records)||!equal(artifacts.uploaded,manifest.uploaded))fail('uploaded_continuation_fixture_changed');
 const lockDirectories=[...parent.lockDirectories,runDirectory];if(new Set(lockDirectories).size!==5)fail('uploaded_continuation_history_changed');
 return {manifest,manifestSHA256:sha(bytes),configSHA256:sha(configBytes),config:structuredClone(config),configPath,runDirectory,parentDirectory,parentConfig,parent,baseline,profiles,accounts,successor,uploaded:structuredClone(manifest.uploaded),expectedFixture:structuredClone(manifest.expectedFixture),lockDirectories,admission:parent.consumed};
}
export function createUploadedContinuationRequest({config,link,launchNonce,processID,identities}){
 if(!equal(config,link.config)||!uuid.test(launchNonce)||!uuid.test(processID)||!Array.isArray(identities)||identities.length!==2||identities.some((v,i)=>!diagnosticProfileReady(v)||['accountID','deviceID','rootFingerprint','publicKeyFingerprint'].some(k=>v[k]!==link.accounts[i][k])))fail('uploaded_continuation_identity_mismatch');
 inInterval(link.successor.binding);
 const body={version:1,runID:config.runID,origin:config.origin,sourceSHA:config.expectedSourceSHA,launchNonce,processID,phase:'continue-uploaded-bootstrap',checkpointID:randomUUID(),operationID:null,expectedDeltaCount:null,evidenceClass:uploadedContinuationEvidenceClass,requestedAt:new Date().toISOString(),manifestSHA256:link.manifestSHA256,configSHA256:link.configSHA256,configIdentitySHA256:link.manifest.configIdentitySHA256,parentRunDirectory:link.parentDirectory,parentSourceSHA:link.parentConfig.expectedSourceSHA,parentFiles:link.manifest.parentFiles,parentClaimSHA256:link.manifest.parentClaimSHA256,deployment:link.manifest.deployment,runnerHashes:link.manifest.runnerHashes,accounts:link.accounts,uploaded:link.uploaded,expectedFixture:link.expectedFixture,artifacts:link.manifest.artifacts,successorBaseline:link.successor.binding};
 return structuredClone({...body,checkpointSHA256:digest(body)});
}
export function validateUploadedContinuationProof(proof,request,baseline){
 const {checkpointSHA256,...body}=request;
 if(!exact(request,['version','runID','origin','sourceSHA','launchNonce','processID','phase','checkpointID','operationID','expectedDeltaCount','evidenceClass','requestedAt','manifestSHA256','configSHA256','configIdentitySHA256','parentRunDirectory','parentSourceSHA','parentFiles','parentClaimSHA256','deployment','runnerHashes','accounts','uploaded','expectedFixture','artifacts','successorBaseline','checkpointSHA256'])||request.version!==1||request.phase!=='continue-uploaded-bootstrap'||request.evidenceClass!==uploadedContinuationEvidenceClass||request.operationID!==null||request.expectedDeltaCount!==null||!uuid.test(request.launchNonce)||!uuid.test(request.processID)||!uuid.test(request.checkpointID)||!timestamp(request.requestedAt)||checkpointSHA256!==digest(body))fail('uploaded_continuation_proof_mismatch');
 validateFixture(request.expectedFixture);validateUploaded(request.uploaded,{created:request.uploaded.created,membershipID:request.uploaded.membershipID},request.accounts);
 const b=request.successorBaseline,interval=b?.interval;
 if(!exact(b,['authorizationSHA256','approvalID','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256','interval'])||!['authorizationSHA256','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256'].every(k=>hash.test(b[k]))||!uuid.test(b.approvalID)||!exact(interval,['startsAt','endsAt'])||!timestamp(interval.startsAt)||!timestamp(interval.endsAt)||interval.startsAt>request.requestedAt||request.requestedAt>=interval.endsAt||b.successorSnapshotSHA256!==baseline.sha256)fail('uploaded_continuation_proof_mismatch');
 if(!exact(proof,['operator','evidenceClass','deployment','observedAt','uploaded','successorBaseline'])||proof.evidenceClass!==uploadedContinuationEvidenceClass||!equal(proof.deployment,request.deployment)||!equal(proof.uploaded,request.uploaded)||!timestamp(proof.observedAt)||proof.observedAt<request.requestedAt||proof.observedAt>=interval.endsAt||proof.observedAt>new Date().toISOString()||proof.successorBaseline?.observedAt!==proof.observedAt)fail('uploaded_continuation_proof_mismatch');
 validateSuccessorProof(proof.successorBaseline,{successorBaseline:{...b,requestedAt:request.requestedAt}},baseline);validateOperatorProof(proof.operator,request,baseline);return structuredClone(proof);
}
function assertRequestLink(link,request){
 const expected={runID:link.config.runID,origin:link.config.origin,sourceSHA:link.config.expectedSourceSHA,manifestSHA256:link.manifestSHA256,configIdentitySHA256:link.manifest.configIdentitySHA256,parentRunDirectory:link.parentDirectory,parentSourceSHA:link.parentConfig.expectedSourceSHA,parentFiles:link.manifest.parentFiles,parentClaimSHA256:link.manifest.parentClaimSHA256,deployment:link.manifest.deployment,runnerHashes:link.manifest.runnerHashes,accounts:link.accounts,uploaded:link.uploaded,expectedFixture:link.expectedFixture,artifacts:link.manifest.artifacts,successorBaseline:link.successor.binding};
 if(Object.keys(expected).some(k=>!equal(expected[k],request[k])))fail('uploaded_continuation_claim_mismatch');
}
export async function assertUploadedContinuationUnclaimed(link){try{await lstat(join(link.parentDirectory,claimName));}catch(error){if(error.code==='ENOENT')return;throw error;}fail('uploaded_continuation_already_claimed');}
export async function claimUploadedContinuation({link,request,proof,runDirectory}){
 if(runDirectory!==link.runDirectory)fail('uploaded_continuation_claim_mismatch');
 for(const dir of link.lockDirectories){let owner;try{owner=await readProtectedJSON(join(dir,'runner.lock','owner.json'));}catch{fail('uploaded_continuation_lock_required');}if(owner.pid!==process.pid)fail('uploaded_continuation_lock_required');}
 const fresh=await readUploadedContinuationLink({config:link.config,configPath:link.configPath,runDirectory});assertRequestLink(fresh,request);
 if(fresh.configSHA256!==request.configSHA256||fresh.config.approvedVaultIDs.length)fail('uploaded_continuation_claim_mismatch');
 validateUploadedContinuationProof(proof,request,fresh.baseline);inInterval(fresh.successor.binding);await assertUploadedContinuationUnclaimed(fresh);await absent(join(runDirectory,admissionName));await absent(join(runDirectory,'scope.json'));
 const claim={version:1,runDirectory,manifestSHA256:fresh.manifestSHA256,sourceSHA:request.sourceSHA,launchNonce:request.launchNonce,checkpointSHA256:request.checkpointSHA256,admissionSHA256:digest({request,proof})};
 inInterval(fresh.successor.binding);
 try{await writeContinuationExclusive(join(fresh.parentDirectory,claimName),claim);}catch(error){if(error.code==='EEXIST')fail('uploaded_continuation_already_claimed');throw error;}
 await writeContinuationExclusive(join(runDirectory,admissionName),{request,proof});return claim;
}
export async function assertUploadedContinuationClaim({link,runDirectory}){
 if(runDirectory!==link.runDirectory)fail('uploaded_continuation_claim_mismatch');
 const claim=await readProtectedJSON(join(link.parentDirectory,claimName)),admission=await readProtectedJSON(join(runDirectory,admissionName));
 if(!exact(claim,['version','runDirectory','manifestSHA256','sourceSHA','launchNonce','checkpointSHA256','admissionSHA256'])||claim.version!==1||claim.runDirectory!==runDirectory||claim.manifestSHA256!==link.manifestSHA256||claim.sourceSHA!==link.config.expectedSourceSHA||claim.launchNonce!==admission.request?.launchNonce||claim.checkpointSHA256!==admission.request?.checkpointSHA256||claim.admissionSHA256!==digest(admission))fail('uploaded_continuation_claim_mismatch');
 assertRequestLink(link,admission.request);validateUploadedContinuationProof(admission.proof,admission.request,link.baseline);return admission;
}
