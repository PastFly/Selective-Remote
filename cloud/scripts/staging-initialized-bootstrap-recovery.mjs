// One successor of a consumed revision-zero recovery, with its original interval.
import {readFile,lstat} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {readProtectedBytes,readProtectedJSON,assertProtectedDirectory,validateRunConfig,validateOperatorProof} from './staging-publication-acceptance.mjs';
import {continuationConfigIdentity,writeContinuationExclusive} from './staging-bootstrap-continuation.mjs';
import {readHistoricalRecovery,recoveryRunnerHashes} from './staging-partial-bootstrap-recovery.mjs';
import {validateSuccessorProof} from './staging-successor-baseline.mjs';
import {diagnosticProfileReady} from './staging-lifecycle-diagnostics.mjs';

export const initializedRecoveryEvidenceClass='INITIALIZED_EMPTY_BOOTSTRAP_RECOVERY';
const fail=code=>{throw Error(code);},hash=/^[a-f0-9]{64}$/,uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
const equal=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b),sha=v=>createHash('sha256').update(v).digest('hex');
export const initializedRecoveryDigest=v=>sha(canonicalMigrationJSON(v));
const digest=initializedRecoveryDigest,timestamp=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
const parentNames=['config.json','owner.json','journal.json','evidence.json','baseline.json','recovery.json','recovery-admission.json'];
const claimName='initialized-bootstrap-recovery-claim.json',admissionName='initialized-recovery-admission.json';
const recipientKeys=['membershipID','membershipEpoch','deviceID'];
const initializedKeys=['created','membershipID','membershipEpoch','automaticDeviceAdmission','revision','keyGeneration','rotationRequired','formatState','activated','v2Pointer','ownedTeamCount','membershipCount','vaultCount','invitationCount','grantCount','publicationCount','inventorySHA256','envelopeSHA256','wrappers','requiredRecipients','ownerTrust'];
export async function initializedRecoveryRunnerHashes(){return {...await recoveryRunnerHashes(),'scripts/staging-initialized-bootstrap-recovery.mjs':sha(await readFile(new URL('./staging-initialized-bootstrap-recovery.mjs',import.meta.url)))};}
async function absent(path){try{await lstat(path);}catch(error){if(error.code==='ENOENT')return;throw error;}fail('initialized_recovery_partial_scope');}
async function pinned(path,expected){if(!hash.test(expected))fail('initialized_recovery_history_changed');const bytes=await readProtectedBytes(path);if(sha(bytes)!==expected)fail('initialized_recovery_history_changed');return JSON.parse(bytes);}
function inInterval(binding){const now=new Date().toISOString();if(now<binding.interval.startsAt||now>=binding.interval.endsAt)fail('initialized_recovery_authorization_expired');}
function validateInitialized(v,partial,accounts){
 if(!exact(v,initializedKeys)||!equal(v.created,partial.created)||v.membershipID!==partial.membershipID||v.membershipEpoch!==1||v.automaticDeviceAdmission!==true||v.revision!==1||v.keyGeneration!==1||v.rotationRequired!==false||v.formatState!=='V1_ACTIVE'||v.activated!==false||v.v2Pointer!==null
  ||['ownedTeamCount','membershipCount','vaultCount'].some(k=>v[k]!==1)||['invitationCount','grantCount','publicationCount'].some(k=>v[k]!==0)||!hash.test(v.inventorySHA256)||!hash.test(v.envelopeSHA256))fail('initialized_recovery_scope_changed');
 const trust=v.ownerTrust,owner=accounts[0];
 if(!exact(trust,['accountID','deviceID','rootFingerprint','publicKeyFingerprint','admitted','revoked','signedDirectorySHA256','certificateSHA256'])||['accountID','deviceID','rootFingerprint','publicKeyFingerprint'].some(k=>trust[k]!==owner[k])||trust.admitted!==true||trust.revoked!==false||!hash.test(trust.signedDirectorySHA256)||!hash.test(trust.certificateSHA256))fail('initialized_recovery_identity_mismatch');
 if(!Array.isArray(v.requiredRecipients)||!v.requiredRecipients.length||!Array.isArray(v.wrappers)||v.wrappers.length!==v.requiredRecipients.length)fail('initialized_recovery_recipients_changed');
 for(const recipients of [v.requiredRecipients,v.wrappers]){
  if(new Set(recipients.map(r=>r.deviceID)).size!==recipients.length)fail('initialized_recovery_recipients_changed');
  for(const r of recipients)if(!exact(r,recipients===v.wrappers?[...recipientKeys,'wrapperSHA256']:recipientKeys)||r.membershipID!==v.membershipID||r.membershipEpoch!==1||!uuid.test(r.deviceID)||recipients===v.wrappers&&!hash.test(r.wrapperSHA256))fail('initialized_recovery_recipients_changed');
 }
 const tuples=rows=>rows.map(r=>Object.fromEntries(recipientKeys.map(k=>[k,r[k]]))).sort((a,b)=>a.deviceID.localeCompare(b.deviceID));
 if(!equal(tuples(v.requiredRecipients),tuples(v.wrappers))||!v.requiredRecipients.some(r=>r.deviceID===owner.deviceID))fail('initialized_recovery_recipients_changed');
}
async function readInitializedRecovery({config,configPath,runDirectory},historical=false){
 validateRunConfig(config);await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);
 const bytes=await readProtectedBytes(join(runDirectory,'initialized-recovery.json')),manifest=JSON.parse(bytes),configBytes=await readProtectedBytes(configPath);
 if(!exact(manifest,['version','evidenceClass','parentRunDirectory','parentConfigPath','parentFiles','parentClaimSHA256','configIdentitySHA256','deployment','runnerHashes','initialized'])||manifest.version!==1||manifest.evidenceClass!==initializedRecoveryEvidenceClass||manifest.configIdentitySHA256!==continuationConfigIdentity(config)||!(historical?exact(manifest.runnerHashes,Object.keys(await initializedRecoveryRunnerHashes()))&&Object.values(manifest.runnerHashes).every(v=>hash.test(v)):equal(manifest.runnerHashes,await initializedRecoveryRunnerHashes()))||!equal(JSON.parse(configBytes),config))fail('initialized_recovery_source_mismatch');
 const deployment=manifest.deployment;
 if(!exact(deployment,['sourceSHA','moduleHashesSHA256','imageDigest','controllerSHA256'])||deployment.sourceSHA!==config.expectedSourceSHA||deployment.moduleHashesSHA256!==digest(config.moduleHashes)||!/^sha256:[a-f0-9]{64}$/.test(deployment.imageDigest)||!hash.test(deployment.controllerSHA256))fail('initialized_recovery_source_mismatch');
 const parentDirectory=manifest.parentRunDirectory;await assertProtectedDirectory(dirname(parentDirectory));await assertProtectedDirectory(parentDirectory);
 if(parentDirectory===runDirectory||!exact(manifest.parentFiles,parentNames))fail('initialized_recovery_history_changed');
 const values={};for(const name of parentNames)values[name]=await pinned(name==='config.json'?manifest.parentConfigPath:join(parentDirectory,name),manifest.parentFiles[name]);
 const parentConfig=validateRunConfig(values['config.json']);
 if(parentConfig.runID!==config.runID||parentConfig.expectedSourceSHA===config.expectedSourceSHA||parentConfig.origin!==config.origin||!equal(parentConfig.emails.map(v=>v.toLowerCase()),config.emails.map(v=>v.toLowerCase()))||parentConfig.approvedVaultIDs.length)fail('initialized_recovery_source_mismatch');
 await absent(join(parentDirectory,'scope.json'));await absent(join(parentDirectory,'initialized-recovery.json'));
 const parent=await readHistoricalRecovery({config:parentConfig,configPath:manifest.parentConfigPath,runDirectory:parentDirectory});
 await pinned(join(parent.predecessorDirectory,'partial-bootstrap-recovery-claim.json'),manifest.parentClaimSHA256);
 const {baseline,profiles,accounts,successor}=parent,owner=values['owner.json'],journal=values['journal.json'],evidence=values['evidence.json'];
 if(!exact(owner,['version','runID','sourceSHA'])||owner.version!==1||owner.runID!==config.runID||owner.sourceSHA!==parentConfig.expectedSourceSHA||!exact(journal,['version','completed','pending','processes','baseline'])||journal.version!==1||!Array.isArray(journal.completed)||journal.completed.length||journal.pending!==null||!Array.isArray(journal.processes)||journal.processes.length||!equal(journal.baseline,baseline)||!equal(values['baseline.json'],baseline))fail('initialized_recovery_partial_scope');
 const failed=Array.isArray(evidence)&&evidence.findLast(v=>v.phase==='stopped_without_acceptance');
 if(!failed||failed.outcome!=='DENIED'||failed.stage!=='team_bootstrap'||failed.browserIndex!==0||failed.launchNonce!==parent.consumed.request.launchNonce||evidence.some(v=>v.phase==='phase_completed')||!evidence.some(v=>v.phase==='session_gate'&&v.launchNonce===failed.launchNonce&&v.testSessionMode==='PRESERVE_TRUSTED_STATE'&&v.outcome==='PASS'))fail('initialized_recovery_partial_scope');
 validateInitialized(manifest.initialized,parent.partial,accounts);
 const lockDirectories=[parent.originalRunDirectory,parent.predecessorDirectory,parentDirectory,runDirectory];if(new Set(lockDirectories).size!==4)fail('initialized_recovery_history_changed');
 return {manifest,manifestSHA256:sha(bytes),configSHA256:sha(configBytes),config:structuredClone(config),configPath,runDirectory,parentDirectory,parentConfig,parent,baseline,profiles,accounts,successor,initialized:structuredClone(manifest.initialized),lockDirectories,admission:parent.consumed};
}
export async function readInitializedRecoveryLink(options){return readInitializedRecovery(options);}
// Only already consumed admissions may use old, independently pinned runner bytes.
export async function readHistoricalInitializedRecovery(options){
 const link=await readInitializedRecovery(options,true);
 return {...link,consumed:await assertInitializedRecoveryClaim({link,runDirectory:options.runDirectory})};
}
export function createInitializedRecoveryRequest({config,link,launchNonce,processID,identities}){
 if(!equal(config,link.config)||!uuid.test(launchNonce)||!uuid.test(processID)||!Array.isArray(identities)||identities.length!==2||identities.some((v,i)=>!diagnosticProfileReady(v)||['accountID','deviceID','rootFingerprint','publicKeyFingerprint'].some(k=>v[k]!==link.accounts[i][k])))fail('initialized_recovery_identity_mismatch');
 inInterval(link.successor.binding);
 const body={version:1,runID:config.runID,origin:config.origin,sourceSHA:config.expectedSourceSHA,launchNonce,processID,phase:'recover-initialized-bootstrap',checkpointID:randomUUID(),operationID:null,expectedDeltaCount:null,evidenceClass:initializedRecoveryEvidenceClass,requestedAt:new Date().toISOString(),manifestSHA256:link.manifestSHA256,configSHA256:link.configSHA256,configIdentitySHA256:link.manifest.configIdentitySHA256,parentRunDirectory:link.parentDirectory,parentSourceSHA:link.parentConfig.expectedSourceSHA,parentFiles:link.manifest.parentFiles,parentClaimSHA256:link.manifest.parentClaimSHA256,deployment:link.manifest.deployment,runnerHashes:link.manifest.runnerHashes,accounts:link.accounts,initialized:link.initialized,successorBaseline:link.successor.binding};
 return structuredClone({...body,checkpointSHA256:digest(body)});
}
export function validateInitializedRecoveryProof(proof,request,baseline){
 const {checkpointSHA256,...body}=request;
 if(!exact(request,['version','runID','origin','sourceSHA','launchNonce','processID','phase','checkpointID','operationID','expectedDeltaCount','evidenceClass','requestedAt','manifestSHA256','configSHA256','configIdentitySHA256','parentRunDirectory','parentSourceSHA','parentFiles','parentClaimSHA256','deployment','runnerHashes','accounts','initialized','successorBaseline','checkpointSHA256'])||request.version!==1||request.phase!=='recover-initialized-bootstrap'||request.evidenceClass!==initializedRecoveryEvidenceClass||request.operationID!==null||request.expectedDeltaCount!==null||!uuid.test(request.launchNonce)||!uuid.test(request.processID)||!uuid.test(request.checkpointID)||!timestamp(request.requestedAt)||checkpointSHA256!==digest(body))fail('initialized_recovery_proof_mismatch');
 validateInitialized(request.initialized,{created:request.initialized.created,membershipID:request.initialized.membershipID},request.accounts);
 const b=request.successorBaseline,interval=b?.interval;
 if(!exact(b,['authorizationSHA256','approvalID','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256','interval'])||!['authorizationSHA256','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256'].every(k=>hash.test(b[k]))||!uuid.test(b.approvalID)||!exact(interval,['startsAt','endsAt'])||!timestamp(interval.startsAt)||!timestamp(interval.endsAt)||interval.startsAt>request.requestedAt||request.requestedAt>=interval.endsAt||b.successorSnapshotSHA256!==baseline.sha256)fail('initialized_recovery_proof_mismatch');
 if(!exact(proof,['operator','evidenceClass','deployment','observedAt','initialized','successorBaseline'])||proof.evidenceClass!==initializedRecoveryEvidenceClass||!equal(proof.deployment,request.deployment)||!equal(proof.initialized,request.initialized)||!timestamp(proof.observedAt)||proof.observedAt<request.requestedAt||proof.observedAt>=interval.endsAt||proof.observedAt>new Date().toISOString()||proof.successorBaseline?.observedAt!==proof.observedAt)fail('initialized_recovery_proof_mismatch');
 validateSuccessorProof(proof.successorBaseline,{successorBaseline:{...b,requestedAt:request.requestedAt}},baseline);validateOperatorProof(proof.operator,request,baseline);return structuredClone(proof);
}
function assertRequestLink(link,request){
 const expected={runID:link.config.runID,origin:link.config.origin,sourceSHA:link.config.expectedSourceSHA,manifestSHA256:link.manifestSHA256,configIdentitySHA256:link.manifest.configIdentitySHA256,parentRunDirectory:link.parentDirectory,parentSourceSHA:link.parentConfig.expectedSourceSHA,parentFiles:link.manifest.parentFiles,parentClaimSHA256:link.manifest.parentClaimSHA256,deployment:link.manifest.deployment,runnerHashes:link.manifest.runnerHashes,accounts:link.accounts,initialized:link.initialized,successorBaseline:link.successor.binding};
 if(Object.keys(expected).some(k=>!equal(expected[k],request[k])))fail('initialized_recovery_claim_mismatch');
}
export async function assertInitializedRecoveryUnclaimed(link){try{await lstat(join(link.parentDirectory,claimName));}catch(error){if(error.code==='ENOENT')return;throw error;}fail('initialized_recovery_already_claimed');}
export async function claimInitializedRecovery({link,request,proof,runDirectory}){
 if(runDirectory!==link.runDirectory)fail('initialized_recovery_claim_mismatch');
 for(const dir of link.lockDirectories){let owner;try{owner=await readProtectedJSON(join(dir,'runner.lock','owner.json'));}catch{fail('initialized_recovery_lock_required');}if(owner.pid!==process.pid)fail('initialized_recovery_lock_required');}
 const fresh=await readInitializedRecoveryLink({config:link.config,configPath:link.configPath,runDirectory});assertRequestLink(fresh,request);
 if(fresh.configSHA256!==request.configSHA256||fresh.config.approvedVaultIDs.length)fail('initialized_recovery_claim_mismatch');
 validateInitializedRecoveryProof(proof,request,fresh.baseline);inInterval(fresh.successor.binding);await assertInitializedRecoveryUnclaimed(fresh);await absent(join(runDirectory,admissionName));await absent(join(runDirectory,'scope.json'));
 const claim={version:1,runDirectory,manifestSHA256:fresh.manifestSHA256,sourceSHA:request.sourceSHA,launchNonce:request.launchNonce,checkpointSHA256:request.checkpointSHA256,admissionSHA256:digest({request,proof})};
 try{await writeContinuationExclusive(join(fresh.parentDirectory,claimName),claim);}catch(error){if(error.code==='EEXIST')fail('initialized_recovery_already_claimed');throw error;}
 await writeContinuationExclusive(join(runDirectory,admissionName),{request,proof});return claim;
}
export async function assertInitializedRecoveryClaim({link,runDirectory}){
 if(runDirectory!==link.runDirectory)fail('initialized_recovery_claim_mismatch');
 const claim=await readProtectedJSON(join(link.parentDirectory,claimName)),admission=await readProtectedJSON(join(runDirectory,admissionName));
 if(!exact(claim,['version','runDirectory','manifestSHA256','sourceSHA','launchNonce','checkpointSHA256','admissionSHA256'])||claim.version!==1||claim.runDirectory!==runDirectory||claim.manifestSHA256!==link.manifestSHA256||claim.sourceSHA!==link.config.expectedSourceSHA||claim.launchNonce!==admission.request?.launchNonce||claim.checkpointSHA256!==admission.request?.checkpointSHA256||claim.admissionSHA256!==digest(admission))fail('initialized_recovery_claim_mismatch');
 assertRequestLink(link,admission.request);validateInitializedRecoveryProof(admission.proof,admission.request,link.baseline);return admission;
}
