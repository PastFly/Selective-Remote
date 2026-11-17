// Internal operator gate only. Store supplies locked, authenticated migration
// state; this module does not replace its signature/trust/epoch/wrapper checks.
import {constants} from 'node:fs';
import {open, lstat, realpath} from 'node:fs/promises';
import {dirname, isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';
import {migrationHash} from './migration-policy.mjs';

const hashPattern=/^[a-f0-9]{64}$/;
const uuidPattern=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const fail=(code='policy_invalid')=>{throw Error(`staging_activation_${code}`);};
const object=value=>value!==null && typeof value==='object' && !Array.isArray(value);
const matches=(pattern,value)=>typeof value==='string' && pattern.test(value);
function identity(value) {
  return object(value) && Object.keys(value).length===3 && matches(/^[a-f0-9]{40}$/,value.sourceSHA)
    && matches(/^sha256:[a-f0-9]{64}$/,value.imageDigest) && matches(hashPattern,value.controllerDigest);
}
function sameIdentity(left,right) {
  return identity(left) && identity(right) && ['sourceSHA','imageDigest','controllerDigest'].every(key=>left[key]===right[key]);
}

async function protectedFile(path,work) {
  let file;
  try {
    if(typeof path!=='string' || !isAbsolute(path) || await realpath(path)!==path)fail();
    const parent=await lstat(dirname(path));
    if(!parent.isDirectory() || parent.isSymbolicLink() || parent.uid!==process.getuid() || (parent.mode&0o777)!==0o700)fail();
    file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
    const before=await file.stat();
    if(!before.isFile() || before.uid!==process.getuid() || (before.mode&0o777)!==0o600)fail();
    const result=await work(file,before);
    const after=await file.stat(), current=await lstat(path);
    if(current.isSymbolicLink() || ['dev','ino','size','mtimeMs','ctimeMs'].some(key=>before[key]!==after[key])
      || current.dev!==before.dev || current.ino!==before.ino)fail();
    return result;
  } catch(error) {
    if(error.message?.startsWith('staging_activation_'))throw error;
    fail();
  } finally {await file?.close();}
}
const readJSON=path=>protectedFile(path,async(file,stat)=>{
  if(stat.size>1024*1024)fail();
  try {return JSON.parse(await file.readFile('utf8'));} catch {fail();}
});
async function backupHash(path) {
  return protectedFile(path,async(file,stat)=>{
    if(stat.size===0)fail('backup_invalid');
    const hash=createHash('sha256'),buffer=Buffer.alloc(64*1024);
    for(;;){const {bytesRead}=await file.read(buffer,0,buffer.length,null);if(!bytesRead)break;hash.update(buffer.subarray(0,bytesRead));}
    return hash.digest('hex');
  });
}

// Host installer writes this protected file after verifying the deployed image,
// source and checker. HTTP requests and arbitrary environment JSON are not a
// source of controller identity.
export async function readStagingControllerIdentity(path){
  const value=await readJSON(path);
  if(!identity(value))fail();
  return Object.freeze({...value});
}

export function createStagingActivationGuard({policyPath,fence,controllerIdentity}={}) {
  if(!identity(controllerIdentity) || typeof fence?.assertWritable!=='function')fail();
  // Do not retain a caller-owned mutable object as the deployed identity.
  const deployedIdentity={...controllerIdentity};
  return async function guard(payload) {
    const policy=await readJSON(policyPath);
    if(!object(policy) || policy.formatVersion!==1 || policy.environment!=='staging'
      || !matches(/^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/,policy.runID)
      || policy.namePrefix!==`TEST-ONLY-CODEX-${policy.runID}`
      || policy.oldClientGateEnabled!==true || !sameIdentity(policy.controllerIdentity,deployedIdentity)
      || !Array.isArray(policy.vaults) || !policy.vaults.length || !object(policy.confirmation)
      || !matches(uuidPattern,policy.confirmation.attemptID) || !matches(hashPattern,policy.confirmation.manifestHash))fail();
    const seen=new Set();
    for(const entry of policy.vaults){
      if(!object(entry) || !matches(uuidPattern,entry.teamID) || !matches(uuidPattern,entry.vaultID)
        || typeof entry.name!=='string' || !entry.name.startsWith(`${policy.namePrefix}-`)
        || entry.name.length>120 || seen.has(entry.vaultID))fail();
      seen.add(entry.vaultID);
    }
    if(!object(payload) || payload.kind!=='MIGRATION' || !object(payload.input)
      || ['vaults','manifests','snapshots','vaultMetadata'].some(key=>!Array.isArray(payload[key]) || payload[key].length!==1))fail('scope_mismatch');
    const {teamID,vaultID,attemptID}=payload.input;
    const tuple=payload.vaults[0],metadata=payload.vaultMetadata[0],signed=payload.manifests[0],snapshot=payload.snapshots[0];
    const allowed=policy.vaults.find(entry=>entry.teamID===teamID && entry.vaultID===vaultID);
    if(!allowed || payload.operationID!==attemptID || attemptID!==policy.confirmation.attemptID
      || metadata?.id!==vaultID || metadata.team_id!==teamID || metadata.name!==allowed.name || metadata.format_state!=='V1_ACTIVE'
      || tuple?.teamID!==teamID || tuple.vaultID!==vaultID || tuple.generationID!==attemptID || tuple.attemptID!==undefined
      || tuple.sequence!==1 || !matches(hashPattern,tuple.headerHash) || tuple.manifestHash!==policy.confirmation.manifestHash
      || signed?.vaultID!==vaultID || snapshot?.vaultID!==vaultID || !object(snapshot.snapshot)
      || !object(signed.manifest?.payload?.reader))fail('scope_mismatch');
    if(await migrationHash(signed.manifest)!==tuple.manifestHash)fail('scope_mismatch');
    const backup=policy.backup;
    if(!object(backup) || !matches(hashPattern,backup.sha256))fail('backup_invalid');
    const restored=await readJSON(backup.restoreAttestationPath);
    if(!object(restored) || restored.formatVersion!==1 || restored.isolatedRestoreVerified!==true
      || restored.backupSHA256!==backup.sha256 || !sameIdentity(restored.controllerIdentity,deployedIdentity))fail('backup_invalid');
    if(await backupHash(backup.path)!==backup.sha256)fail('backup_invalid');
    // Last asynchronous gate before Store writes durable PENDING_INTENT. This
    // cannot create a missing journal or excuse an unresolved older operation.
    try {if(await fence.assertWritable()!==true)fail('fence_invalid');}
    catch(error){
      if(error.message?.startsWith('deployment_fence_'))throw error;
      fail('fence_invalid');
    }
    return true;
  };
}
