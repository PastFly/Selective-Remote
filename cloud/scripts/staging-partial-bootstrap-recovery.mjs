// One failed bootstrap cut point only. Historical registration and creation stay historical.
import {readFile,lstat} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {readProtectedBytes,readProtectedJSON,assertProtectedDirectory,validateRunConfig,validateOrdinaryBaseline,validateOperatorProof} from './staging-publication-acceptance.mjs';
import {continuationConfigIdentity,continuationRunnerHashes,assertContinuationClaim,writeContinuationExclusive} from './staging-bootstrap-continuation.mjs';
import {readSuccessorBaseline} from './staging-successor-baseline.mjs';
import {validateDiagnosticRun,diagnosticProfileReady} from './staging-lifecycle-diagnostics.mjs';

export const recoveryEvidenceClass='PARTIAL_BOOTSTRAP_SOURCE_RECOVERY';
const fail=code=>{throw Error(code);},hash=/^[a-f0-9]{64}$/,uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
const equal=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b),sha=v=>createHash('sha256').update(v).digest('hex'),digest=v=>sha(canonicalMigrationJSON(v));
const timestamp=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
const predecessorNames=['config.json','owner.json','journal.json','evidence.json','baseline.json','continuation.json','continuation-admission.json'];
const accountKeys=['browserIndex','emailSHA256','accountID','deviceID','publicKeyFingerprint','rootFingerprint'];
const partialKeys=['created','membershipID','membershipEpoch','automaticDeviceAdmission','revision','formatState','activated','hasCiphertext','wrapperCount','ownedTeamCount','membershipCount','vaultCount','invitationCount','publicationCount','inventorySHA256'];
const claimName='partial-bootstrap-recovery-claim.json';
export async function recoveryRunnerHashes(){return {...await continuationRunnerHashes(),'scripts/staging-partial-bootstrap-recovery.mjs':sha(await readFile(new URL('./staging-partial-bootstrap-recovery.mjs',import.meta.url)))};}
async function absent(path){try{await lstat(path);}catch(error){if(error.code==='ENOENT')return;throw error;}fail('recovery_partial_scope');}
export async function assertRecoveryUnclaimed(link){try{await lstat(join(link.predecessorDirectory,claimName));}catch(error){if(error.code==='ENOENT')return;throw error;}fail('recovery_already_claimed');}
async function pinned(path,expected){if(!hash.test(expected))fail('recovery_artifact_invalid');const bytes=await readProtectedBytes(path);if(sha(bytes)!==expected)fail('recovery_predecessor_changed');return JSON.parse(bytes);}
function validateAccounts(accounts,config){
 if(!Array.isArray(accounts)||accounts.length!==2)fail('recovery_identity_mismatch');
 for(const [i,a]of accounts.entries())if(!exact(a,accountKeys)||a.browserIndex!==i||a.emailSHA256!==sha(config.emails[i].toLowerCase())||!uuid.test(a.accountID)||!uuid.test(a.deviceID)||!hash.test(a.rootFingerprint)||typeof a.publicKeyFingerprint!=='string'||!/^[a-f0-9]{4}(?:-[a-f0-9]{4}){15}$/.test(a.publicKeyFingerprint))fail('recovery_identity_mismatch');
 if(accounts[0].accountID===accounts[1].accountID||accounts[0].deviceID===accounts[1].deviceID)fail('recovery_identity_mismatch');
}
function validatePartial(p,runID,accounts){
 if(!exact(p,partialKeys)||!exact(p.created,['teamID','actorUserID','actorDeviceID','vaults'])||!uuid.test(p.created.teamID)||p.created.actorUserID!==accounts[0].accountID||p.created.actorDeviceID!==accounts[0].deviceID
  ||!Array.isArray(p.created.vaults)||p.created.vaults.length!==1||!uuid.test(p.membershipID)||p.membershipEpoch!==1||p.automaticDeviceAdmission!==true||p.revision!==0||p.formatState!=='V1_ACTIVE'||p.activated!==false||p.hasCiphertext!==false
  ||['wrapperCount','invitationCount','publicationCount'].some(k=>p[k]!==0)||['ownedTeamCount','membershipCount','vaultCount'].some(k=>p[k]!==1)||!hash.test(p.inventorySHA256))fail('recovery_partial_scope');
 const v=p.created.vaults[0];if(!exact(v,['vaultID','name','attemptID'])||!uuid.test(v.vaultID)||!uuid.test(v.attemptID)||v.name!==`TEST-ONLY-CODEX-${runID}-populated`)fail('recovery_partial_scope');
}
function expectedAdmission(partial){return {teamID:partial.created.teamID,membershipID:partial.membershipID,membershipEpoch:partial.membershipEpoch,deviceID:partial.created.actorDeviceID,automaticDeviceAdmission:true,admitted:true,productSignInObserved:true};}

// Current continuation validation intentionally rejects changed runner bytes. This
// historical path instead verifies every preserved byte, then reuses its strict
// admission validator. It never modifies or extends the historical admission.
async function readHistorical({manifest,predecessorConfig,predecessorValues}){
 const prior=predecessorValues['continuation.json'],original=prior?.originalRunDirectory;
 if(!exact(prior,['version','evidenceClass','originalRunDirectory','originalConfigPath','originalFiles','diagnosticName','configIdentitySHA256','deployment','runnerHashes','registrationWindow','successorBaseline'])||prior.version!==1||prior.evidenceClass!=='REGISTERED_BY_OWNER_SERVER_VERIFIED'
  ||prior.configIdentitySHA256!==continuationConfigIdentity(predecessorConfig)||prior.deployment?.sourceSHA!==predecessorConfig.expectedSourceSHA||prior.deployment.moduleHashesSHA256!==digest(predecessorConfig.moduleHashes)
  ||!exact(prior.runnerHashes,Object.keys(await continuationRunnerHashes()))||Object.values(prior.runnerHashes).some(v=>!hash.test(v)))fail('recovery_historical_admission_invalid');
 if(!exact(prior.deployment,['sourceSHA','moduleHashesSHA256','imageDigest','controllerSHA256'])||!/^sha256:[a-f0-9]{64}$/.test(prior.deployment.imageDigest)||!hash.test(prior.deployment.controllerSHA256)
  ||!exact(prior.registrationWindow,['absentAt','verifiedBy'])||!timestamp(prior.registrationWindow.absentAt)||!timestamp(prior.registrationWindow.verifiedBy)||prior.registrationWindow.absentAt>=prior.registrationWindow.verifiedBy)fail('recovery_historical_admission_invalid');
 await assertProtectedDirectory(dirname(original));await assertProtectedDirectory(original);
 if(original===manifest.predecessorRunDirectory||typeof prior.diagnosticName!=='string'||!/^diagnostic-[a-f0-9-]{36}\.json$/.test(prior.diagnosticName))fail('recovery_historical_admission_invalid');
 const names=['config.json','owner.json','baseline.json','journal.json','evidence.json',prior.diagnosticName];if(!exact(prior.originalFiles,names))fail('recovery_historical_admission_invalid');
 const values={};for(const name of names)values[name]=await pinned(name==='config.json'?prior.originalConfigPath:join(original,name),prior.originalFiles[name]);
 const originalConfig=validateRunConfig(values['config.json']),oldBaseline=validateOrdinaryBaseline(values['baseline.json']);
 if(originalConfig.runID===predecessorConfig.runID||originalConfig.origin!==predecessorConfig.origin||!equal(originalConfig.emails.map(v=>v.toLowerCase()),predecessorConfig.emails.map(v=>v.toLowerCase())))fail('recovery_historical_admission_invalid');
 const originalLaunchNonce=validateDiagnosticRun({config:originalConfig,mode:'PRESERVE_TRUSTED_STATE',marker:values['owner.json'],journal:values['journal.json'],baseline:oldBaseline,evidence:values['evidence.json']});
 const events=values[prior.diagnosticName],finished=Array.isArray(events)&&events.at(-1);
 if(!finished||!['diagnostic_completed','diagnostic_cancelled'].includes(finished.phase)||finished.outcome!=='NOT_RUN'||!uuid.test(finished.launchNonce)||!uuid.test(finished.processID))fail('recovery_historical_admission_invalid');
 for(const event of events)if(event.runID!==originalConfig.runID||event.expectedSourceSHA!==originalConfig.expectedSourceSHA||event.previousLaunchNonce!==originalLaunchNonce||event.launchNonce!==finished.launchNonce||event.processID!==finished.processID||event.evidenceClass!=='DIAGNOSTIC_ONLY_NO_ACCEPTANCE')fail('recovery_historical_admission_invalid');
 await absent(join(original,'scope.json'));await absent(join(original,'continuation.json'));
 const successor=await readSuccessorBaseline({manifest:prior,runDirectory:manifest.predecessorRunDirectory,originalConfig,config:predecessorConfig,baseline:oldBaseline});
 const historicalLink={successor,manifest:prior,runID:predecessorConfig.runID,manifestSHA256:manifest.predecessorFiles['continuation.json'],originalConfig,originalLaunchNonce,baseline:successor.baseline};
 await pinned(join(original,'continuation-claim.json'),manifest.originalClaimSHA256);
 const admission=await assertContinuationClaim({link:historicalLink,runDirectory:manifest.predecessorRunDirectory});
 for(const i of [0,1]){const old=events.findLast(v=>v.phase==='diagnostic_metadata'&&v.browserIndex===i&&diagnosticProfileReady(v));if(old&&(['accountID','deviceID','publicKeyFingerprint'].some(k=>old[k]!==admission.request.accounts[i][k])||old.rootFingerprint!==undefined&&old.rootFingerprint!==admission.request.accounts[i].rootFingerprint))fail('recovery_historical_admission_invalid');}
 return {originalRunDirectory:original,baseline:successor.baseline,successor,admission,originalConfig};
}

export async function readRecoveryLink({config,configPath,runDirectory}){
 validateRunConfig(config);await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);
 const bytes=await readProtectedBytes(join(runDirectory,'recovery.json')),manifest=JSON.parse(bytes),configBytes=await readProtectedBytes(configPath);
 if(!exact(manifest,['version','evidenceClass','predecessorRunDirectory','predecessorConfigPath','predecessorFiles','originalClaimSHA256','configIdentitySHA256','deployment','runnerHashes','partial'])||manifest.version!==1||manifest.evidenceClass!==recoveryEvidenceClass
  ||manifest.configIdentitySHA256!==continuationConfigIdentity(config)||!equal(manifest.runnerHashes,await recoveryRunnerHashes())||!equal(JSON.parse(configBytes),config))fail('recovery_source_mismatch');
 const deployment=manifest.deployment;if(!exact(deployment,['sourceSHA','moduleHashesSHA256','imageDigest','controllerSHA256'])||deployment.sourceSHA!==config.expectedSourceSHA||deployment.moduleHashesSHA256!==digest(config.moduleHashes)||!/^sha256:[a-f0-9]{64}$/.test(deployment.imageDigest)||!hash.test(deployment.controllerSHA256))fail('recovery_source_mismatch');
 const predecessorDirectory=manifest.predecessorRunDirectory;await assertProtectedDirectory(dirname(predecessorDirectory));await assertProtectedDirectory(predecessorDirectory);
 if(predecessorDirectory===runDirectory||!exact(manifest.predecessorFiles,predecessorNames))fail('recovery_predecessor_changed');
 const values={};for(const name of predecessorNames)values[name]=await pinned(name==='config.json'?manifest.predecessorConfigPath:join(predecessorDirectory,name),manifest.predecessorFiles[name]);
 const predecessorConfig=validateRunConfig(values['config.json']);if(predecessorConfig.runID!==config.runID||predecessorConfig.expectedSourceSHA===config.expectedSourceSHA||predecessorConfig.origin!==config.origin||!equal(predecessorConfig.emails.map(v=>v.toLowerCase()),config.emails.map(v=>v.toLowerCase()))||predecessorConfig.approvedVaultIDs.length)fail('recovery_source_mismatch');
 await absent(join(predecessorDirectory,'scope.json'));await absent(join(predecessorDirectory,'recovery.json'));
 const historical=await readHistorical({manifest,predecessorConfig,predecessorValues:values});if(historical.originalRunDirectory===runDirectory)fail('recovery_predecessor_changed');
 const {baseline,admission}=historical,owner=values['owner.json'],journal=values['journal.json'],evidence=values['evidence.json'];
 if(!exact(owner,['version','runID','sourceSHA'])||owner.version!==1||owner.runID!==config.runID||owner.sourceSHA!==predecessorConfig.expectedSourceSHA
  ||!exact(journal,['version','completed','pending','processes','baseline'])||journal.version!==1||!Array.isArray(journal.completed)||journal.completed.length||journal.pending!==null||!Array.isArray(journal.processes)||journal.processes.length||!equal(journal.baseline,baseline)||!equal(values['baseline.json'],baseline))fail('recovery_partial_scope');
 const failed=Array.isArray(evidence)&&evidence.findLast(v=>v.phase==='stopped_without_acceptance');
 if(!failed||failed.outcome!=='DENIED'||failed.stage!=='team_bootstrap'||failed.browserIndex!==0||failed.launchNonce!==admission.request.launchNonce||evidence.some(v=>v.phase==='phase_completed')||!evidence.some(v=>v.phase==='session_gate'&&v.launchNonce===failed.launchNonce&&v.testSessionMode==='PRESERVE_TRUSTED_STATE'&&v.outcome==='PASS'))fail('recovery_partial_scope');
 const accounts=admission.request.accounts;validateAccounts(accounts,config);validatePartial(manifest.partial,config.runID,accounts);
 const profiles=[0,1].map(i=>join(historical.originalRunDirectory,'edge-'+i));for(const profile of profiles)await assertProtectedDirectory(profile);
 return {manifest,manifestSHA256:sha(bytes),configSHA256:sha(configBytes),config:structuredClone(config),configPath,runDirectory,baseline,profiles,accounts:structuredClone(accounts),partial:structuredClone(manifest.partial),predecessorDirectory,predecessorConfig,...historical};
}

export function createRecoveryRequest({config,link,launchNonce,processID,identities}){
 if(!uuid.test(launchNonce)||!uuid.test(processID)||!equal(config,link.config)||!Array.isArray(identities)||identities.length!==2)fail('recovery_identity_mismatch');
 for(const [i,v]of identities.entries())if(!diagnosticProfileReady(v)||['accountID','deviceID','publicKeyFingerprint','rootFingerprint'].some(k=>v[k]!==link.accounts[i][k]))fail('recovery_identity_mismatch');
 const requestedAt=new Date().toISOString(),interval=link.successor.binding.interval;if(requestedAt<interval.startsAt||requestedAt>=interval.endsAt)fail('recovery_authorization_expired');
 const body={version:1,runID:config.runID,origin:config.origin,sourceSHA:config.expectedSourceSHA,launchNonce,processID,phase:'recover-bootstrap',checkpointID:randomUUID(),operationID:null,expectedDeltaCount:null,evidenceClass:recoveryEvidenceClass,requestedAt,
  manifestSHA256:link.manifestSHA256,configSHA256:link.configSHA256,configIdentitySHA256:link.manifest.configIdentitySHA256,predecessorRunDirectory:link.predecessorDirectory,predecessorSourceSHA:link.predecessorConfig.expectedSourceSHA,predecessorFiles:link.manifest.predecessorFiles,originalClaimSHA256:link.manifest.originalClaimSHA256,
  deployment:link.manifest.deployment,runnerHashes:link.manifest.runnerHashes,accounts:link.accounts,partial:link.partial,deviceAdmission:expectedAdmission(link.partial),successorBaseline:link.successor.binding};
 return structuredClone({...body,checkpointSHA256:digest(body)});
}
export function validateRecoveryProof(proof,request,baseline){
 const {checkpointSHA256,...body}=request;
 if(!exact(request,['version','runID','origin','sourceSHA','launchNonce','processID','phase','checkpointID','operationID','expectedDeltaCount','evidenceClass','requestedAt','manifestSHA256','configSHA256','configIdentitySHA256','predecessorRunDirectory','predecessorSourceSHA','predecessorFiles','originalClaimSHA256','deployment','runnerHashes','accounts','partial','deviceAdmission','successorBaseline','checkpointSHA256'])||request.version!==1||request.phase!=='recover-bootstrap'||request.evidenceClass!==recoveryEvidenceClass||request.operationID!==null||request.expectedDeltaCount!==null||!uuid.test(request.processID)||checkpointSHA256!==digest(body)||!timestamp(request.requestedAt))fail('recovery_proof_mismatch');
 validatePartial(request.partial,request.runID,request.accounts);
 const binding=request.successorBaseline,interval=binding?.interval;
 if(!exact(binding,['authorizationSHA256','approvalID','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256','interval'])||!['authorizationSHA256','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256'].every(k=>hash.test(binding[k]))||!uuid.test(binding.approvalID)||!exact(interval,['startsAt','endsAt'])||!timestamp(interval.startsAt)||!timestamp(interval.endsAt)||interval.startsAt>request.requestedAt||request.requestedAt>=interval.endsAt||binding.successorSnapshotSHA256!==baseline.sha256)fail('recovery_proof_mismatch');
 const expected=expectedAdmission(request.partial),admitted=proof?.deviceAdmission;
 if(!exact(proof,['operator','evidenceClass','deployment','observedAt','partial','deviceAdmission'])||proof.evidenceClass!==recoveryEvidenceClass||!equal(proof.deployment,request.deployment)||!equal(proof.partial,request.partial)
  ||!exact(admitted,[...Object.keys(expected),'admissionSHA256','sessionAuditSHA256','auditSource','observedAt'])||Object.keys(expected).some(k=>admitted[k]!==expected[k])||!equal(request.deviceAdmission,expected)||!hash.test(admitted.admissionSHA256)||!hash.test(admitted.sessionAuditSHA256)||admitted.auditSource!=='session'||admitted.observedAt!==proof.observedAt
  ||!timestamp(proof.observedAt)||proof.observedAt<request.requestedAt||proof.observedAt>=interval.endsAt||proof.observedAt>new Date().toISOString())fail('recovery_proof_mismatch');
 validateOperatorProof(proof.operator,request,baseline);return structuredClone(proof);
}
function assertRequestLink(link,request){
 if(request.runID!==link.config.runID||request.origin!==link.config.origin||request.sourceSHA!==link.config.expectedSourceSHA||request.manifestSHA256!==link.manifestSHA256||request.configIdentitySHA256!==link.manifest.configIdentitySHA256||request.predecessorRunDirectory!==link.predecessorDirectory||request.predecessorSourceSHA!==link.predecessorConfig.expectedSourceSHA||request.originalClaimSHA256!==link.manifest.originalClaimSHA256
  ||!equal(request.predecessorFiles,link.manifest.predecessorFiles)||!equal(request.deployment,link.manifest.deployment)||!equal(request.runnerHashes,link.manifest.runnerHashes)||!equal(request.accounts,link.accounts)||!equal(request.partial,link.partial)||!equal(request.successorBaseline,link.successor.binding))fail('recovery_claim_mismatch');
}
export async function claimRecovery({link,request,proof,runDirectory}){
 if(runDirectory!==link.runDirectory)fail('recovery_claim_mismatch');
 for(const dir of [link.originalRunDirectory,link.predecessorDirectory,runDirectory]){let owner;try{owner=await readProtectedJSON(join(dir,'runner.lock','owner.json'));}catch{fail('recovery_lock_required');}if(owner.pid!==process.pid)fail('recovery_lock_required');}
 const fresh=await readRecoveryLink({config:link.config,configPath:link.configPath,runDirectory});assertRequestLink(fresh,request);
 if(fresh.configSHA256!==request.configSHA256||fresh.config.approvedVaultIDs.length)fail('recovery_claim_mismatch');
 validateRecoveryProof(proof,request,fresh.baseline);const now=new Date().toISOString();if(now<fresh.successor.binding.interval.startsAt||now>=fresh.successor.binding.interval.endsAt)fail('recovery_authorization_expired');
 await assertRecoveryUnclaimed(fresh);await absent(join(runDirectory,'recovery-admission.json'));await absent(join(runDirectory,'scope.json'));
 const claim={version:1,runDirectory,manifestSHA256:fresh.manifestSHA256,sourceSHA:request.sourceSHA,launchNonce:request.launchNonce,checkpointSHA256:request.checkpointSHA256,admissionSHA256:digest({request,proof})};
 try{await writeContinuationExclusive(join(fresh.predecessorDirectory,claimName),claim);}catch(error){if(error.code==='EEXIST')fail('recovery_already_claimed');throw error;}
 await writeContinuationExclusive(join(runDirectory,'recovery-admission.json'),{request,proof});return claim;
}
export async function assertRecoveryClaim({link,runDirectory}){
 if(runDirectory!==link.runDirectory)fail('recovery_claim_mismatch');
 const claim=await readProtectedJSON(join(link.predecessorDirectory,claimName)),admission=await readProtectedJSON(join(runDirectory,'recovery-admission.json'));
 if(!exact(claim,['version','runDirectory','manifestSHA256','sourceSHA','launchNonce','checkpointSHA256','admissionSHA256'])||claim.version!==1||claim.runDirectory!==runDirectory||claim.manifestSHA256!==link.manifestSHA256||claim.sourceSHA!==link.config.expectedSourceSHA||claim.launchNonce!==admission.request?.launchNonce||claim.checkpointSHA256!==admission.request?.checkpointSHA256||claim.admissionSHA256!==digest(admission))fail('recovery_claim_mismatch');
 assertRequestLink(link,admission.request);validateRecoveryProof(admission.proof,admission.request,link.baseline);return admission;
}
