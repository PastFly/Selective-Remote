// Administrative policy inspection uses only a coherently selected ACTIVE
// generation. Wrapper presence is delivery evidence, never proof of decryption.
import {compileEffectiveAccess} from './effective-access.mjs';
import {permissionBits,requiredCryptoParts,usabilityByPermission} from './access-policy.mjs';
import {verifyReaderHeader,verifyReaderDescriptor} from '../public/vault-publication-v1.js';
import {migrationHash,migrationBytes,fromBase64} from '../public/vault-v2-migration.js';
import {isUUID} from './security.mjs';
const fail=code=>{throw Error(code);};
// ACTIVE Folder names are encrypted GENERAL content; foundation PREPARING
// requirements intentionally retain their separate no-content semantics.
const activeCryptoParts=(kind,mask)=>kind==='FOLDER'&&(mask&permissionBits.View)?['GENERAL']:requiredCryptoParts(kind,mask);
export async function inspectPublication({a,snapshot},input,page,deviceNames=new Map()){
 const publisher=snapshot.devices.find(d=>d.accountID===a.projection.header.payload.publisherAccountID&&d.deviceID===a.projection.header.payload.publisherDeviceID&&d.certificate.payload.keyVersion===a.projection.header.payload.publisherKeyVersion);
 if(!publisher)fail('publication_repair_required');
 const rootPublicKey=publisher.rootPublicKey;
 if(await verifyReaderHeader({header:a.projection.header,rootPublicKey,teamID:a.team_id,vaultID:a.vault_id})!==a.header_hash||a.manifest.payload.policyHash!==await migrationHash(a.policy)||a.manifest.payload.scope?.teamID!==a.team_id||a.manifest.payload.scope?.vaultID!==a.vault_id||a.manifest.payload.scope?.attemptID!==a.id||await migrationHash(a.manifest.payload.resources)!==await migrationHash(a.resources))fail('publication_repair_required');
 const key=await crypto.subtle.importKey('raw',fromBase64(rootPublicKey),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
 if(!await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,fromBase64(a.manifest.signature),migrationBytes(a.manifest.payload)))fail('publication_repair_required');
 const resources=new Map(a.resources.map(r=>[r.id,{...r,teamID:a.team_id,vaultID:a.vault_id,deletedAt:null}]));
 const member=id=>{const m=snapshot.memberships.find(m=>m.userID===id);if(!m)fail('team_not_found');return m;};
 const group=id=>{if(!snapshot.groups.some(g=>g.id===id))fail('access_group_not_found');};
 const policy=(id,m,groupID=null)=>{
  const target=resources.get(id);if(!target)fail('access_resource_not_found');
  const ancestors=[],seen=new Set([id]);let next=target.parentFolderID;
  while(next!==null){const p=resources.get(next);if(!p||seen.has(next)||ancestors.length>=64)fail('invalid_access_ancestry');seen.add(next);ancestors.push(p);next=p.parentFolderID;}
  const groupIDs=groupID?[groupID]:snapshot.edges.filter(e=>e.membershipID===m.id&&e.membershipEpoch===m.epoch&&e.userID===m.userID).map(e=>e.groupID);
  const result=compileEffectiveAccess({target,ancestors,membership:m,groupIDs,grants:groupID?a.policy.filter(g=>g.principalKind==='GROUP'):a.policy,requiresCrypto:false});
  return {policyAllowed:result.policyAllowed,policyMask:result.policyMask,paths:result.paths,blockedReasons:result.policyAllowed?[]:['POLICY_DENIED']};
 };
 const effective=async()=>{
  const m=member(input.subjectUserID),p=policy(input.resourceID,m),deviceID=input.subjectDeviceID;
  if(!isUUID(deviceID))fail('invalid_access_device');
  const device=snapshot.devices.find(d=>d.deviceID===deviceID&&d.accountID===m.userID&&d.membershipID===m.id&&d.membershipEpoch===m.epoch);
  const row=device&&a.projection.recipients.find(r=>r.inventory.payload.accountID===m.userID&&r.inventory.payload.deviceID===deviceID&&r.inventory.payload.membershipID===m.id&&r.inventory.payload.membershipEpoch===m.epoch);
  const available=new Set();
  for(const item of (row?.proofs??[]).filter(r=>r.resourceID===input.resourceID)){
   const w=item.entry?.wrapper?.context;
   if(item.entry.accountID!==m.userID||item.entry.deviceKeyVersion!==device.certificate.payload.keyVersion||!w||w.deviceID!==deviceID||w.membershipID!==m.id||w.membershipEpoch!==m.epoch)fail('publication_repair_required');
   const descriptor=a.projection.descriptors.find(d=>d.payload.resourceID===item.resourceID&&d.payload.part===item.part);if(!descriptor)fail('publication_repair_required');
   await verifyReaderDescriptor({descriptor,header:a.projection.header,rootPublicKey,entry:item.entry,proof:item.proof});available.add(item.part);
  }
  const target=resources.get(input.resourceID),content=p.policyMask&7;
  const parts=content?activeCryptoParts(target.kind,content):[],cryptoAvailableByPermission={};
  for(const [name,bit]of Object.entries(permissionBits))if(content&bit){const required=activeCryptoParts(target.kind,target.kind==='CREDENTIAL'&&name==='Edit'?bit|2:bit);cryptoAvailableByPermission[name==='View'&&target.kind==='CREDENTIAL'?'ViewMetadata':name]=!required.length?'NOT_REQUIRED':device&&required.every(p=>available.has(p))?'WRAP_PRESENT_UNVERIFIED':'NO';}
  const cryptoAvailable=!device||!content?'NO':!parts.length?'NOT_REQUIRED':parts.every(p=>available.has(p))?'WRAP_PRESENT_UNVERIFIED':'NO';
  return {policyEffective:p,deviceUsability:{deviceID,effectiveUsable:cryptoAvailable==='NOT_REQUIRED'?'YES':cryptoAvailable==='WRAP_PRESENT_UNVERIFIED'?'UNKNOWN':'NO',cryptoAvailable,cryptoAvailableByPermission,effectiveUsableByPermission:usabilityByPermission(cryptoAvailableByPermission),blockedReasons:!device?['DEVICE_NOT_ADMITTED']:!content?['POLICY_DENIED']:cryptoAvailable==='NO'?['KEY_UNAVAILABLE']:[]}};
 };
 if(input.inspection==='effective')return effective();
 if(input.inspection==='who')return page(snapshot.memberships.map(m=>({id:m.userID,m})),item=>{const p=policy(input.resourceID,item.m);return p.policyAllowed?{userID:item.id,policyEffective:p}:null;});
 if(input.inspection==='resources'){
  if(!['USER','GROUP'].includes(input.principalKind)||!isUUID(input.principalID))fail('invalid_access_request');
  const m=input.principalKind==='USER'?member(input.principalID):{id:input.principalID,userID:input.principalID,epoch:1};if(input.principalKind==='GROUP')group(input.principalID);
  return page([...resources.values()],r=>{const p=policy(r.id,m,input.principalKind==='GROUP'?input.principalID:null);return p.policyAllowed?{resourceID:r.id,policyEffective:p}:null;});
 }
 if(input.inspection==='devices'){
  const m=member(input.subjectUserID);
  return page(snapshot.raw.devices.filter(d=>d.user_id===m.userID&&!d.revoked_at),d=>({id:d.id,name:deviceNames.get(d.id)??d.id,platform:d.platform,admitted:snapshot.devices.some(v=>v.deviceID===d.id&&v.membershipID===m.id&&v.membershipEpoch===m.epoch)}));
 }
 fail('invalid_access_request');
}
