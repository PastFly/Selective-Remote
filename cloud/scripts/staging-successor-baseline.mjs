// Opt-in continuation evidence only. Ordinary verification keeps exact equality.
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
import {readProtectedBytes,validateOrdinaryBaseline} from './staging-publication-acceptance.mjs';

const fail=code=>{throw Error(code);};
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).length===keys.length&&keys.every(k=>Object.hasOwn(v,k));
const equal=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b);
const sha256=value=>createHash('sha256').update(value).digest('hex');
const hash=/^[a-f0-9]{64}$/,uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const timestamp=value=>typeof value==='string'&&Number.isFinite(Date.parse(value))&&new Date(value).toISOString()===value;
const scopeKinds=['shared','personal','users','teams'];
const emptyHash=sha256('[]');

async function readArtifact(runDirectory,entry,name){
 if(!exact(entry,['name','sha256'])||entry.name!==name||!hash.test(entry.sha256))fail('successor_artifact_invalid');
 const bytes=await readProtectedBytes(join(runDirectory,name));
 if(sha256(bytes)!==entry.sha256)fail('successor_artifact_changed');
 return bytes;
}
function snapshotSummary(bytes){
 let snapshot;try{snapshot=JSON.parse(bytes);}catch{fail('successor_snapshot_invalid');}
 if(!exact(snapshot,['formatVersion','scope','tables'])||snapshot.formatVersion!==1||!exact(snapshot.scope,scopeKinds)
  ||!snapshot.tables||typeof snapshot.tables!=='object'||Array.isArray(snapshot.tables)
  ||!['users','personal_vaults','vault_revisions','teams','shared_vaults'].every(k=>Object.hasOwn(snapshot.tables,k)))fail('successor_snapshot_invalid');
 for(const kind of scopeKinds){
  const ids=snapshot.scope[kind];if(!Array.isArray(ids)||ids.some(v=>typeof v!=='string'||!uuid.test(v))||new Set(ids).size!==ids.length)fail('successor_snapshot_invalid');
 }
 for(const [name,t]of Object.entries(snapshot.tables)){
  if(!/^[a-z_][a-z0-9_]*$/.test(name)||!exact(t,['present','columns','count','sha256'])||typeof t.present!=='boolean'||!Array.isArray(t.columns)
   ||t.columns.some(c=>typeof c!=='string'||!/^[a-z_][a-z0-9_]*$/.test(c))||new Set(t.columns).size!==t.columns.length||!Number.isSafeInteger(t.count)||t.count<0||typeof t.sha256!=='string'||!hash.test(t.sha256)
   ||(t.present&&!t.columns.length)||(!t.present&&(t.columns.length||t.count!==0||t.sha256!==emptyHash)))fail('successor_snapshot_invalid');
 }
 // captureNonTestVaultSnapshot writes JSON.stringify(snapshot), with no newline;
 // its summary is the SHA-256 of precisely those bytes, not canonicalMigrationJSON.
 const rawSHA256=sha256(bytes);if(rawSHA256!==sha256(JSON.stringify(snapshot)))fail('successor_snapshot_identity_mismatch');
 return {snapshot,baseline:{unchanged:true,vaultCount:snapshot.scope.shared.length,personalVaultCount:snapshot.scope.personal.length,userCount:snapshot.scope.users.length,sha256:rawSHA256}};
}
export async function readSuccessorBaseline({manifest,runDirectory,originalConfig,config,baseline}){
 const transition=manifest.successorBaseline;
 if(!exact(transition,['version','originalSnapshot','successorSnapshot','ownerAuthorization','failedComparisons'])||transition.version!==1)fail('successor_artifact_invalid');
 const original=snapshotSummary(await readArtifact(runDirectory,transition.originalSnapshot,'ordinary-original-snapshot.json'));
 const successor=snapshotSummary(await readArtifact(runDirectory,transition.successorSnapshot,'ordinary-successor-snapshot.json'));
 if(!equal(original.baseline,baseline))fail('successor_original_mismatch');
 if(scopeKinds.some(k=>!equal([...original.snapshot.scope[k]].sort(),[...successor.snapshot.scope[k]].sort()))
  ||['vaultCount','personalVaultCount','userCount'].some(k=>original.baseline[k]!==successor.baseline[k]))fail('successor_scope_mismatch');
 if(!equal(Object.keys(original.snapshot.tables).sort(),Object.keys(successor.snapshot.tables).sort()))fail('successor_snapshot_invalid');
 const authorization=JSON.parse(await readArtifact(runDirectory,transition.ownerAuthorization,'ordinary-successor-authorization.json'));
 if(!exact(authorization,['version','kind','approved','approvalID','approvedAt','interval','originalRunID','originalSourceSHA','successorRunID','successorSourceSHA','configIdentitySHA256','originalFiles','deployment','runnerHashes','originalSnapshotSHA256','successorSnapshotSHA256','failedComparisons'])
  ||authorization.version!==1||authorization.kind!=='OWNER_AUTHORIZED_SUCCESSOR_ORDINARY_BASELINE'||authorization.approved!==true||typeof authorization.approvalID!=='string'||!uuid.test(authorization.approvalID)
  ||!timestamp(authorization.approvedAt)||!exact(authorization.interval,['startsAt','endsAt'])||!timestamp(authorization.interval.startsAt)||!timestamp(authorization.interval.endsAt)
  ||authorization.approvedAt>authorization.interval.startsAt||authorization.interval.startsAt>=authorization.interval.endsAt
  ||authorization.originalRunID!==originalConfig.runID||authorization.originalSourceSHA!==originalConfig.expectedSourceSHA||authorization.successorRunID!==config.runID||authorization.successorSourceSHA!==config.expectedSourceSHA
  ||authorization.configIdentitySHA256!==manifest.configIdentitySHA256||!equal(authorization.originalFiles,manifest.originalFiles)||!equal(authorization.deployment,manifest.deployment)||!equal(authorization.runnerHashes,manifest.runnerHashes)
  ||authorization.originalSnapshotSHA256!==original.baseline.sha256||authorization.successorSnapshotSHA256!==successor.baseline.sha256||!equal(authorization.failedComparisons,transition.failedComparisons))fail('successor_authorization_required');
 const failures=transition.failedComparisons;
 if(!Array.isArray(failures)||!failures.length||failures.length>8||new Set(failures.map(v=>v?.path)).size!==failures.length)fail('successor_failed_comparison_required');
 for(const entry of failures){
  if(!exact(entry,['path','sha256'])||typeof entry.path!=='string'||typeof entry.sha256!=='string'||!hash.test(entry.sha256))fail('successor_failed_comparison_required');
  const bytes=await readProtectedBytes(entry.path);if(!bytes.length||sha256(bytes)!==entry.sha256)fail('successor_failed_comparison_changed');
 }
 const scope=Object.fromEntries(scopeKinds.map(k=>[k,[...original.snapshot.scope[k]].sort()]));
 return {baseline:successor.baseline,scope:original.snapshot.scope,binding:{authorizationSHA256:transition.ownerAuthorization.sha256,approvalID:authorization.approvalID,originalSnapshotSHA256:original.baseline.sha256,successorSnapshotSHA256:successor.baseline.sha256,scopeSHA256:sha256(canonicalMigrationJSON(scope)),interval:authorization.interval}};
}
export function createSuccessorRequest(successor){
 const requestedAt=new Date().toISOString(),{interval}=successor.binding;
 if(requestedAt<interval.startsAt||requestedAt>=interval.endsAt)fail('successor_authorization_expired');
 return {...successor.binding,requestedAt};
}
export function validateSuccessorProof(proof,request,baseline){
 const binding=request.successorBaseline;
 if(!exact(binding,['authorizationSHA256','approvalID','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256','interval','requestedAt'])
  ||!['authorizationSHA256','originalSnapshotSHA256','successorSnapshotSHA256','scopeSHA256'].every(k=>typeof binding[k]==='string'&&hash.test(binding[k]))
  ||typeof binding.approvalID!=='string'||!uuid.test(binding.approvalID)||!exact(binding.interval,['startsAt','endsAt'])||!timestamp(binding.interval.startsAt)||!timestamp(binding.interval.endsAt)
  ||!timestamp(binding.requestedAt)||binding.interval.startsAt>binding.requestedAt||binding.requestedAt>=binding.interval.endsAt)fail('successor_proof_mismatch');
 validateOrdinaryBaseline(baseline);
 if(baseline.sha256!==binding.successorSnapshotSHA256||!exact(proof,['authorizationSHA256','approvalID','originalSnapshotSHA256','observedSnapshotSHA256','scopeSHA256','observedAt'])
  ||['authorizationSHA256','approvalID','originalSnapshotSHA256','scopeSHA256'].some(k=>proof[k]!==binding[k])||proof.observedSnapshotSHA256!==binding.successorSnapshotSHA256
  ||!timestamp(proof.observedAt)||proof.observedAt<binding.requestedAt||proof.observedAt>=binding.interval.endsAt||proof.observedAt>new Date().toISOString())fail('successor_proof_mismatch');
}
