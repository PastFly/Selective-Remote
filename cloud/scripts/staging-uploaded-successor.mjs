// One explicit Owner-authorized successor of an interrupted, unclaimed upload run.
// Historical admissions keep their original authority. This module never archives locks.
import {lstat,readdir} from 'node:fs/promises';
import {join,dirname,isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';
import {canonicalMigrationJSON as canonical} from '../public/vault-v2-migration.js';
import {readProtectedBytes,readProtectedJSON,assertProtectedDirectory,validateRunConfig} from './staging-publication-acceptance.mjs';
import {continuationConfigIdentity} from './staging-bootstrap-continuation.mjs';
import {readSuccessorBaseline} from './staging-successor-baseline.mjs';
import {diagnosticProfileReady} from './staging-lifecycle-diagnostics.mjs';

const fail=()=>{throw Error('uploaded_successor_invalid');},sha=b=>createHash('sha256').update(b).digest('hex'),digest=v=>sha(canonical(v));
const same=(a,b)=>canonical(a)===canonical(b),hash=/^[a-f0-9]{64}$/,uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&same(Object.keys(v).sort(),[...keys].sort());
const timestamp=v=>typeof v==='string'&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString()===v;
const contextKeys=['kind','predecessorRunDirectory','predecessorFilesSHA256','parentClaimSHA256','predecessorAuthorizationSHA256','predecessorSnapshotSHA256','uploadedSHA256','fixtureSHA256','archiveSHA256','captureSHA256','capturedAt'];
async function absent(path){try{await lstat(path);}catch(e){if(e.code==='ENOENT')return;throw e;}fail();}
async function pinned(entry){if(!exact(entry,['path','sha256'])||!isAbsolute(entry.path)||!hash.test(entry.sha256))fail();const raw=await readProtectedBytes(entry.path);if(sha(raw)!==entry.sha256)fail();return JSON.parse(raw);}
function dead(pid){if(!Number.isSafeInteger(pid)||pid<1)fail();try{process.kill(pid,0);}catch(e){if(e.code==='ESRCH')return;throw e;}fail();}
const metadata=s=>({dev:s.dev,ino:s.ino,uid:s.uid,gid:s.gid,mode:s.mode&0o777,nlink:s.nlink,size:s.size});

async function validateArchive(entry,directories,runDirectory){
 const a=await pinned(entry);
 if(!exact(a,['version','kind','archivedAt','entries'])||a.version!==1||a.kind!=='VERIFIED_STALE_LOCK_ARCHIVE'||!timestamp(a.archivedAt)||a.archivedAt>new Date().toISOString()||!Array.isArray(a.entries)||a.entries.length!==5||directories.length!==5)fail();
 const root=dirname(entry.path);await assertProtectedDirectory(root);
 if([...directories,runDirectory].some(d=>root===d||root.startsWith(d+'/')))fail();
 for(const [i,dir]of directories.entries()){
  const e=a.entries[i];if(!exact(e,['originalDirectory','archiveDirectory','ownerSHA256','directory','owner'])||e.originalDirectory!==join(dir,'runner.lock')||e.archiveDirectory!==join(root,i+'-runner.lock')||!hash.test(e.ownerSHA256))fail();
  await assertProtectedDirectory(e.archiveDirectory);const bytes=await readProtectedBytes(join(e.archiveDirectory,'owner.json'));
  if(sha(bytes)!==e.ownerSHA256||!same(await readdir(e.archiveDirectory),['owner.json'])||!same(metadata(await lstat(e.archiveDirectory)),e.directory)||!same(metadata(await lstat(join(e.archiveDirectory,'owner.json'))),e.owner)||e.directory.dev!==(await lstat(dir)).dev)fail();
  const owner=JSON.parse(bytes);if(!exact(owner,['version','pid','processID'])||owner.version!==1||!uuid.test(owner.processID))fail();dead(owner.pid);
  try{const active=await readProtectedJSON(e.originalDirectory+'/owner.json');if(!exact(active,['version','pid','processID'])||active.version!==1||active.pid!==process.pid||!uuid.test(active.processID))fail();}catch(error){if(error.code!=='ENOENT')throw error;await absent(e.originalDirectory);}
 }
 return a;
}

export function validateUploadedRenewalContext(request){
 const c=request.renewalContext,b=request.successorBaseline;
 if(!exact(c,contextKeys)||c.kind!=='UPLOADED_UNCLAIMED_SUCCESSOR'||!isAbsolute(c.predecessorRunDirectory)||!timestamp(c.capturedAt)||contextKeys.filter(k=>k.endsWith('SHA256')).some(k=>!hash.test(c[k]))
  ||c.parentClaimSHA256!==request.parentClaimSHA256||c.predecessorSnapshotSHA256!==b.originalSnapshotSHA256||c.predecessorAuthorizationSHA256===b.authorizationSHA256||c.uploadedSHA256!==digest(request.uploaded)||c.fixtureSHA256!==digest(request.expectedFixture)||c.capturedAt!==b.interval.startsAt||Date.parse(b.interval.endsAt)-Date.parse(b.interval.startsAt)>86400000)fail();
}

export async function readUploadedRenewal({manifest,config,runDirectory,parent,baseline,successor,lockDirectories}){
 const r=manifest.renewal;
 if(!exact(r,['version','capturedAt','predecessorRunDirectory','predecessorConfigPath','predecessorFiles','requestName','archive','capture','successorBaseline'])||r.version!==1||!timestamp(r.capturedAt)||r.capturedAt>new Date().toISOString()||r.capturedAt<successor.binding.interval.endsAt||r.predecessorRunDirectory===runDirectory||lockDirectories.includes(r.predecessorRunDirectory)||!isAbsolute(r.predecessorRunDirectory)||!/^uploaded-continuation-request-[a-f0-9-]{36}\.json$/.test(r.requestName))fail();
 const old=r.predecessorRunDirectory;await assertProtectedDirectory(dirname(old));await assertProtectedDirectory(old);
 const names=['config.json','owner.json','journal.json','baseline.json','evidence.json','uploaded-continuation.json',r.requestName];if(!exact(r.predecessorFiles,names))fail();
 const values={};for(const name of names)values[name]=await pinned({path:name==='config.json'?r.predecessorConfigPath:join(old,name),sha256:r.predecessorFiles[name]});
 const prior=values['uploaded-continuation.json'],oldConfig=validateRunConfig(values['config.json']),request=values[r.requestName];
 const originalKeys=Object.keys(manifest).filter(k=>k!=='renewal');
 if(!exact(prior,originalKeys)||prior.version!==1||prior.evidenceClass!==manifest.evidenceClass||oldConfig.runID!==config.runID||oldConfig.origin!==config.origin||!same(oldConfig.emails.map(v=>v.toLowerCase()),config.emails.map(v=>v.toLowerCase()))||oldConfig.expectedSourceSHA===config.expectedSourceSHA||oldConfig.approvedVaultIDs.length||prior.configIdentitySHA256!==continuationConfigIdentity(oldConfig))fail();
 for(const key of ['parentRunDirectory','parentConfigPath','parentFiles','parentClaimSHA256','uploaded','expectedFixture','artifacts'])if(!same(prior[key],manifest[key]))fail();
 const oldRunnerKeys=Object.keys(manifest.runnerHashes).filter(k=>k!=='scripts/staging-uploaded-successor.mjs');
 if(!exact(prior.runnerHashes,oldRunnerKeys)||Object.values(prior.runnerHashes).some(v=>!hash.test(v))||!exact(prior.deployment,['sourceSHA','moduleHashesSHA256','imageDigest','controllerSHA256'])||prior.deployment.sourceSHA!==oldConfig.expectedSourceSHA||prior.deployment.moduleHashesSHA256!==digest(oldConfig.moduleHashes)||!/^sha256:[a-f0-9]{64}$/.test(prior.deployment.imageDigest)||!hash.test(prior.deployment.controllerSHA256))fail();
 const requestKeys=['version','runID','origin','sourceSHA','launchNonce','processID','phase','checkpointID','operationID','expectedDeltaCount','evidenceClass','requestedAt','manifestSHA256','configSHA256','configIdentitySHA256','parentRunDirectory','parentSourceSHA','parentFiles','parentClaimSHA256','deployment','runnerHashes','accounts','uploaded','expectedFixture','artifacts','successorBaseline','checkpointSHA256'];
 if(!exact(request,requestKeys)||request.version!==1||request.phase!=='continue-uploaded-bootstrap'||request.evidenceClass!==prior.evidenceClass||request.operationID!==null||request.expectedDeltaCount!==null||!['launchNonce','processID','checkpointID'].every(k=>uuid.test(request[k]))||r.requestName!=='uploaded-continuation-request-'+request.launchNonce+'.json'||!timestamp(request.requestedAt)||request.requestedAt<successor.binding.interval.startsAt||request.requestedAt>=successor.binding.interval.endsAt)fail();
 const {checkpointSHA256,...body}=request;if(checkpointSHA256!==digest(body))fail();
 const expected={runID:oldConfig.runID,origin:oldConfig.origin,sourceSHA:oldConfig.expectedSourceSHA,manifestSHA256:r.predecessorFiles['uploaded-continuation.json'],configSHA256:r.predecessorFiles['config.json'],configIdentitySHA256:prior.configIdentitySHA256,parentRunDirectory:prior.parentRunDirectory,parentSourceSHA:parent.config.expectedSourceSHA,parentFiles:prior.parentFiles,parentClaimSHA256:prior.parentClaimSHA256,deployment:prior.deployment,runnerHashes:prior.runnerHashes,accounts:parent.accounts,uploaded:prior.uploaded,expectedFixture:prior.expectedFixture,artifacts:prior.artifacts,successorBaseline:successor.binding};
 if(Object.entries(expected).some(([k,v])=>!same(request[k],v)))fail();
 if(!same(values['owner.json'],{version:1,runID:oldConfig.runID,sourceSHA:oldConfig.expectedSourceSHA})||!same(values['baseline.json'],baseline)||!same(values['journal.json'],{version:1,completed:[],pending:null,processes:[],baseline}))fail();
 const evidence=values['evidence.json'];if(!Array.isArray(evidence)||evidence.length!==8)fail();
 for(const i of [0,1]){const [started,ready,closed]=evidence.slice(i*3,i*3+3);for(const e of [started,closed])if(e.phase!==(e===started?'process_started':'process_closed')||e.browserIndex!==i||e.outcome!=='PASS'||e.processID!==request.processID||e.launchNonce!==request.launchNonce)fail();if(started.pid!==closed.pid)fail();dead(started.pid);if(ready.phase!=='continuation_readiness'||ready.browserIndex!==i||ready.launchNonce!==request.launchNonce||ready.stage!=='diagnostic_trust'||!diagnosticProfileReady(ready)||['accountID','deviceID','rootFingerprint','publicKeyFingerprint'].some(k=>ready[k]!==request.accounts[i][k]))fail();}
 const pending=evidence[6];if(pending.phase!=='uploaded-continuation_operator_proof_pending'||pending.outcome!=='PENDING'||pending.launchNonce!==request.launchNonce||pending.checkpointID!==request.checkpointID||pending.checkpointSHA256!==request.checkpointSHA256||pending.previousLaunchNonce!==parent.consumed.request.launchNonce||pending.runID!==oldConfig.runID||pending.expectedSourceSHA!==oldConfig.expectedSourceSHA||pending.evidenceClass!==prior.evidenceClass||!same(evidence[7],{phase:'owner_input_pending',outcome:'PENDING'}))fail();
 const allowed=new Set([...names.filter(n=>n!=='config.json'),'runner.lock']);if(r.predecessorConfigPath===join(old,'config.json'))allowed.add('config.json');if((await readdir(old)).some(n=>!allowed.has(n)))fail();
 try{const claim=await readProtectedJSON(join(manifest.parentRunDirectory,'uploaded-bootstrap-continuation-claim.json'));if(claim.runDirectory!==runDirectory||claim.sourceSHA!==config.expectedSourceSHA)fail();}catch(error){if(error.code!=='ENOENT')throw error;}
 const ancestors=[...lockDirectories.slice(0,-1),old];await validateArchive(r.archive,ancestors,runDirectory);
 const capture=await pinned(r.capture),captureKeys=['version','kind','capturedAt','readOnly','deployment','previousSnapshotSHA256','snapshotSHA256','scopeSHA256','uploadedSHA256','fixtureSHA256','testInventorySHA256'];
 if(!exact(capture,captureKeys)||capture.version!==1||capture.kind!=='READ_ONLY_UPLOADED_SUCCESSOR_CAPTURE'||capture.readOnly!==true||capture.capturedAt!==r.capturedAt||!same(capture.deployment,prior.deployment)||capture.previousSnapshotSHA256!==baseline.sha256||capture.snapshotSHA256!==r.successorBaseline.successorSnapshot.sha256||capture.scopeSHA256!==successor.binding.scopeSHA256||capture.uploadedSHA256!==digest(manifest.uploaded)||capture.fixtureSHA256!==digest(manifest.expectedFixture)||!hash.test(capture.testInventorySHA256))fail();
 const renewalContext={kind:'UPLOADED_UNCLAIMED_SUCCESSOR',predecessorRunDirectory:old,predecessorFilesSHA256:digest(r.predecessorFiles),parentClaimSHA256:manifest.parentClaimSHA256,predecessorAuthorizationSHA256:successor.binding.authorizationSHA256,predecessorSnapshotSHA256:baseline.sha256,uploadedSHA256:digest(manifest.uploaded),fixtureSHA256:digest(manifest.expectedFixture),archiveSHA256:r.archive.sha256,captureSHA256:r.capture.sha256,capturedAt:r.capturedAt};
 const active=await readSuccessorBaseline({manifest:{...manifest,originalFiles:r.predecessorFiles,successorBaseline:r.successorBaseline},runDirectory,originalConfig:oldConfig,config,baseline,recoveryContext:renewalContext});
 if(active.binding.approvalID===successor.binding.approvalID||active.binding.authorizationSHA256===successor.binding.authorizationSHA256||active.binding.interval.startsAt!==r.capturedAt||Date.parse(active.binding.interval.endsAt)-Date.parse(r.capturedAt)>86400000)fail();
 return {baseline:active.baseline,successor:active,renewalContext,lockDirectories:[...ancestors,runDirectory]};
}
