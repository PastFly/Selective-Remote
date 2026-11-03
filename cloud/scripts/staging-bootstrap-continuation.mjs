// Test harness only. A separately labelled continuation never repairs a lost POST receipt.
import {readFile,lstat,open,rm} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {readProtectedJSON,readProtectedBytes,assertProtectedDirectory,validateRunConfig,validateOrdinaryBaseline,validateOperatorProof} from './staging-publication-acceptance.mjs';
import {readSuccessorBaseline,createSuccessorRequest,validateSuccessorProof} from './staging-successor-baseline.mjs';
import {validateDiagnosticRun,diagnosticProfileReady} from './staging-lifecycle-diagnostics.mjs';

const fail=code=>{throw Error(code);},uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/,hash=/^[a-f0-9]{64}$/;
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
const equal=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b);
export const continuationEvidenceClass='REGISTERED_BY_OWNER_SERVER_VERIFIED';
export const continuationSHA256=value=>createHash('sha256').update(value).digest('hex');
const digest=value=>continuationSHA256(canonicalMigrationJSON(value));
export const continuationConfigIdentity=config=>digest({...config,approvedVaultIDs:[]});
const timestamp=value=>typeof value==='string'&&Number.isFinite(Date.parse(value))&&new Date(value).toISOString()===value;
const runnerFiles=['scripts/staging-bootstrap-continuation.mjs','scripts/staging-successor-baseline.mjs','scripts/staging-publication-acceptance.mjs','scripts/staging-lifecycle-diagnostics.mjs','tests/browser/staging-real-lifecycle.mjs'];
export async function continuationRunnerHashes(){return Object.fromEntries(await Promise.all(runnerFiles.map(async path=>[path,continuationSHA256(await readFile(new URL('../'+path,import.meta.url)))])));}
async function absent(path){try{await lstat(path);}catch(error){if(error.code==='ENOENT')return;throw error;}fail('continuation_partial_scope');}
export async function readContinuationLink({config,configPath,runDirectory}){
 validateRunConfig(config);await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);
 const manifestBytes=await readProtectedBytes(join(runDirectory,'continuation.json')),manifest=JSON.parse(manifestBytes);
 if(!exact(manifest,['version','evidenceClass','originalRunDirectory','originalConfigPath','originalFiles','diagnosticName','configIdentitySHA256','deployment','runnerHashes','registrationWindow',...(Object.hasOwn(manifest,'successorBaseline')?['successorBaseline']:[])])||manifest.version!==1||manifest.evidenceClass!==continuationEvidenceClass
  ||manifest.configIdentitySHA256!==continuationConfigIdentity(config)||!equal(manifest.runnerHashes,await continuationRunnerHashes()))fail('continuation_source_mismatch');
 const deployment=manifest.deployment,window=manifest.registrationWindow;
 if(!exact(deployment,['sourceSHA','moduleHashesSHA256','imageDigest','controllerSHA256'])||deployment.sourceSHA!==config.expectedSourceSHA||deployment.moduleHashesSHA256!==digest(config.moduleHashes)
  ||typeof deployment.imageDigest!=='string'||!/^sha256:[a-f0-9]{64}$/.test(deployment.imageDigest)||!hash.test(deployment.controllerSHA256)
  ||!exact(window,['absentAt','verifiedBy'])||!timestamp(window.absentAt)||!timestamp(window.verifiedBy)||window.absentAt>=window.verifiedBy)fail('continuation_source_mismatch');
 const configBytes=await readProtectedBytes(configPath);if(!equal(validateRunConfig(JSON.parse(configBytes)),config))fail('continuation_source_mismatch');
 const original=manifest.originalRunDirectory;await assertProtectedDirectory(dirname(original));await assertProtectedDirectory(original);if(original===runDirectory)fail('continuation_run_mismatch');
 if(typeof manifest.diagnosticName!=='string'||!/^diagnostic-[a-f0-9-]{36}\.json$/.test(manifest.diagnosticName))fail('continuation_run_mismatch');
 const names=['config.json','owner.json','baseline.json','journal.json','evidence.json',manifest.diagnosticName];
 if(!exact(manifest.originalFiles,names)||names.some(n=>typeof manifest.originalFiles[n]!=='string'||!hash.test(manifest.originalFiles[n])))fail('continuation_run_mismatch');
 const values={};for(const name of names){const bytes=await readProtectedBytes(name==='config.json'?manifest.originalConfigPath:join(original,name));if(continuationSHA256(bytes)!==manifest.originalFiles[name])fail('continuation_original_changed');values[name]=JSON.parse(bytes);}
 const originalConfig=validateRunConfig(values['config.json']),originalBaseline=validateOrdinaryBaseline(values['baseline.json']);
 if(config.runID===originalConfig.runID||config.origin!==originalConfig.origin||!equal(config.emails.map(v=>v.toLowerCase()),originalConfig.emails.map(v=>v.toLowerCase())))fail('continuation_run_mismatch');
 const originalLaunchNonce=validateDiagnosticRun({config:originalConfig,mode:'PRESERVE_TRUSTED_STATE',marker:values['owner.json'],journal:values['journal.json'],baseline:originalBaseline,evidence:values['evidence.json']});
 await absent(join(original,'scope.json'));
 const profiles=[join(original,'edge-0'),join(original,'edge-1')];for(const p of profiles)await assertProtectedDirectory(p);
 const events=values[manifest.diagnosticName],finished=Array.isArray(events)&&events.at(-1);
 if(!finished||!['diagnostic_completed','diagnostic_cancelled'].includes(finished.phase)||finished.outcome!=='NOT_RUN'||!uuid.test(finished.launchNonce)||!uuid.test(finished.processID))fail('continuation_diagnostic_required');
 for(const e of events)if(e.runID!==originalConfig.runID||e.expectedSourceSHA!==originalConfig.expectedSourceSHA||e.previousLaunchNonce!==originalLaunchNonce||e.launchNonce!==finished.launchNonce||e.processID!==finished.processID||e.evidenceClass!=='DIAGNOSTIC_ONLY_NO_ACCEPTANCE')fail('continuation_diagnostic_required');
 const identities=[0,1].map(i=>events.findLast(e=>e.phase==='diagnostic_metadata'&&e.browserIndex===i&&diagnosticProfileReady(e))??null);
 if(identities[0]&&identities[1]&&(identities[0].accountID===identities[1].accountID||identities[0].deviceID===identities[1].deviceID))fail('continuation_diagnostic_required');
 const successor=Object.hasOwn(manifest,'successorBaseline')?await readSuccessorBaseline({manifest,runDirectory,originalConfig,config,baseline:originalBaseline}):null;
 if(successor)await absent(join(original,'continuation.json'));
 return {successor,manifest,runID:config.runID,manifestSHA256:continuationSHA256(manifestBytes),configSHA256:continuationSHA256(configBytes),originalConfig,originalLaunchNonce,baseline:successor?.baseline??originalBaseline,profiles,identities};
}
export function createContinuationRequest({config,link,launchNonce,processID,identities}){
 if(!uuid.test(launchNonce)||!uuid.test(processID)||!Array.isArray(identities)||identities.length!==2)fail('continuation_identity_mismatch');
 if(new Set(identities.map(v=>v.accountID)).size!==2||new Set(identities.map(v=>v.deviceID)).size!==2)fail('continuation_identity_mismatch');
 const accounts=identities.map((v,i)=>{
  const old=link.identities[i];
  if(!diagnosticProfileReady(v)||!uuid.test(v.accountID)||!uuid.test(v.deviceID)||typeof v.publicKeyFingerprint!=='string'||! /^[a-f0-9]{4}(?:-[a-f0-9]{4}){15}$/.test(v.publicKeyFingerprint)||typeof v.rootFingerprint!=='string'||!hash.test(v.rootFingerprint)
   ||old&&(['accountID','deviceID','publicKeyFingerprint'].some(k=>v[k]!==old[k])||old.rootFingerprint!==undefined&&v.rootFingerprint!==old.rootFingerprint))fail('continuation_identity_mismatch');
  return {browserIndex:i,emailSHA256:continuationSHA256(config.emails[i].toLowerCase()),accountID:v.accountID,deviceID:v.deviceID,publicKeyFingerprint:v.publicKeyFingerprint,rootFingerprint:v.rootFingerprint};
 });
 if(link.successor&&accounts.some(a=>link.successor.scope.users.includes(a.accountID)))fail('successor_scope_mismatch');
 const body={version:1,runID:config.runID,origin:config.origin,sourceSHA:config.expectedSourceSHA,launchNonce,processID,phase:'continue-bootstrap',checkpointID:randomUUID(),operationID:null,expectedDeltaCount:null,evidenceClass:continuationEvidenceClass,
  manifestSHA256:link.manifestSHA256,configSHA256:link.configSHA256,originalRunID:link.originalConfig.runID,originalSourceSHA:link.originalConfig.expectedSourceSHA,originalLaunchNonce:link.originalLaunchNonce,originalFiles:link.manifest.originalFiles,
  deployment:link.manifest.deployment,runnerHashes:link.manifest.runnerHashes,registrationWindow:link.manifest.registrationWindow,accounts,...(link.successor?{successorBaseline:createSuccessorRequest(link.successor)}:{})};
 return {...body,checkpointSHA256:digest(body)};
}
export function validateContinuationProof(proof,request,baseline){
 const {checkpointSHA256,...body}=request;if(checkpointSHA256!==digest(body)||request.phase!=='continue-bootstrap'||request.evidenceClass!==continuationEvidenceClass)fail('continuation_proof_mismatch');
 if(!exact(proof,['operator','evidenceClass','deployment','ownerAttestation','registration',...(Object.hasOwn(request,'successorBaseline')?['successorBaseline']:[])])||proof.evidenceClass!==continuationEvidenceClass||!equal(proof.deployment,request.deployment)
  ||!exact(proof.ownerAttestation,['registeredAndVerifiedViaProductGUI','registrationResponseNotObserved'])||proof.ownerAttestation.registeredAndVerifiedViaProductGUI!==true||proof.ownerAttestation.registrationResponseNotObserved!==true)fail('continuation_proof_mismatch');
 if(Object.hasOwn(request,'successorBaseline'))validateSuccessorProof(proof.successorBaseline,request,baseline);
 validateOperatorProof(proof.operator,request,baseline);
 const registration=proof.registration,counts=['ownedTeams','memberships','invitations','teamVaults','testNameMatches'];
 if(!exact(registration,['absentBeforeWindow','accounts','noPartialScope'])||registration.absentBeforeWindow!==true||!exact(registration.noPartialScope,counts)||counts.some(k=>registration.noPartialScope[k]!==0)
  ||!Array.isArray(registration.accounts)||registration.accounts.length!==2)fail('continuation_registration_mismatch');
 for(const [i,a]of registration.accounts.entries()){
  const expected=request.accounts[i];if(!exact(a,[...Object.keys(expected),'createdAt','verifiedAt','disabled'])||Object.keys(expected).some(k=>a[k]!==expected[k])||a.disabled!==false
   ||!timestamp(a.createdAt)||!timestamp(a.verifiedAt)||a.createdAt<request.registrationWindow.absentAt||a.verifiedAt<a.createdAt||a.verifiedAt>request.registrationWindow.verifiedBy)fail('continuation_registration_mismatch');
 }
 return structuredClone(proof);
}
export async function writeContinuationExclusive(path,value){
 const file=await open(path,'wx',0o600);try{await file.writeFile(JSON.stringify(value)+'\n');await file.sync();}finally{await file.close();}
 const directory=await open(dirname(path),'r');try{await directory.sync();}finally{await directory.close();}
}
export async function claimContinuation({link,request,proof,runDirectory}){
 assertRequestLink(link,request);
 if(link.successor&&new Date().toISOString()>=link.successor.binding.interval.endsAt)fail('successor_authorization_expired');
 validateContinuationProof(proof,request,link.baseline);
 let owner;try{owner=await readProtectedJSON(join(link.manifest.originalRunDirectory,'runner.lock','owner.json'));}catch{fail('continuation_lock_required');}
 if(owner.pid!==process.pid)fail('continuation_lock_required');
 const claim={version:1,runDirectory,manifestSHA256:link.manifestSHA256,sourceSHA:request.sourceSHA,launchNonce:request.launchNonce,checkpointSHA256:request.checkpointSHA256};
 try{await writeContinuationExclusive(join(link.manifest.originalRunDirectory,'continuation-claim.json'),claim);}catch(error){if(error.code==='EEXIST')fail('continuation_already_claimed');throw error;}
 await writeContinuationExclusive(join(runDirectory,'continuation-admission.json'),{request,proof});
 return claim;
}
export async function assertContinuationClaim({link,runDirectory}){
 const claim=await readProtectedJSON(join(link.manifest.originalRunDirectory,'continuation-claim.json')),admission=await readProtectedJSON(join(runDirectory,'continuation-admission.json'));
 if(!exact(claim,['version','runDirectory','manifestSHA256','sourceSHA','launchNonce','checkpointSHA256'])||claim.version!==1||claim.runDirectory!==runDirectory||claim.manifestSHA256!==link.manifestSHA256||claim.sourceSHA!==link.manifest.deployment.sourceSHA
  ||admission.request?.sourceSHA!==claim.sourceSHA||!equal(admission.request?.deployment,link.manifest.deployment)||!equal(admission.request?.originalFiles,link.manifest.originalFiles)||claim.launchNonce!==admission.request?.launchNonce||claim.checkpointSHA256!==admission.request?.checkpointSHA256||admission.request?.manifestSHA256!==link.manifestSHA256)fail('continuation_claim_mismatch');
 assertRequestLink(link,admission.request);
 validateContinuationProof(admission.proof,admission.request,link.baseline);return admission;
}

function assertRequestLink(link,request){
 if(request.runID!==link.runID||request.origin!==link.originalConfig.origin||request.sourceSHA!==link.manifest.deployment.sourceSHA||request.manifestSHA256!==link.manifestSHA256
  ||request.originalRunID!==link.originalConfig.runID||request.originalSourceSHA!==link.originalConfig.expectedSourceSHA||request.originalLaunchNonce!==link.originalLaunchNonce
  ||!equal(request.originalFiles,link.manifest.originalFiles)||!equal(request.deployment,link.manifest.deployment)||!equal(request.runnerHashes,link.manifest.runnerHashes)||!equal(request.registrationWindow,link.manifest.registrationWindow))fail('continuation_claim_mismatch');
 if(link.successor){
  const {requestedAt,...binding}=request.successorBaseline??{};if(!equal(binding,link.successor.binding))fail('continuation_claim_mismatch');
 }else if(Object.hasOwn(request,'successorBaseline'))fail('continuation_claim_mismatch');
}
export async function assertContinuationRunBaseline({link,runDirectory}){
 const baseline=validateOrdinaryBaseline(await readProtectedJSON(join(runDirectory,'baseline.json'))),journal=await readProtectedJSON(join(runDirectory,'journal.json'));
 if(!equal(baseline,link.baseline)||!equal(journal.baseline,link.baseline))fail('continuation_baseline_changed');
}

export async function assertContinuationUnclaimed(originalRunDirectory){try{await lstat(join(originalRunDirectory,'continuation-claim.json'));}catch(error){if(error.code==='ENOENT')return;throw error;}fail('continuation_already_claimed');}
export async function acquireUnclaimedLifecycleLock(runDirectory,acquire){
 const lock=join(runDirectory,'runner.lock');await acquire(lock);
 try{await assertContinuationUnclaimed(runDirectory);}catch(error){await rm(lock,{recursive:true});throw error;}
 return lock;
}

export async function runContinuationReadiness({open,inspect,showGUI,prompt,close}){
 const identities=[];
 for(const index of [0,1]){
  const profile=await open(index);
  try{
   let result=await inspect(profile,index);
   while(!diagnosticProfileReady(result)){
    await showGUI(profile,index,result);
    if(await prompt(index,result)==='quit')fail('continuation_readiness_cancelled');
    result=await inspect(profile,index);
   }
   identities.push(result);
  }finally{await close(profile,index);}
 }
 return identities;
}
export function assertContinuationIdentity(actual,expected){
 if(['accountID','deviceID','publicKeyFingerprint'].some(k=>actual[k]!==expected[k])||actual.publicPin?.rootFingerprint!==expected.rootFingerprint)fail('continuation_identity_mismatch');
}
