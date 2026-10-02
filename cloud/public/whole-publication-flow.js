import { accessID, validateMask } from './access-model.js';
import { canonicalMigrationJSON, migrationBytes, migrationHash, fromBase64 } from './vault-v2-migration.js';
import { verifyDeviceForWrapping, verifyHistoricalDeviceCertificate, advancePinnedTrust } from './device-trust-v1.js';
import { verifyReaderHeader, verifyReaderDescriptor, verifyReaderInventory, verifyWrapperProof, publicationHash } from './vault-publication-v1.js';
import { unwrapResourceCEK, decryptResourcePart } from './resource-crypto-v2.js';
import { collectWholePublicationPreview, createWholePublicationCoordinator } from './whole-publication-client.js';
import { folderSourceKey } from './legacy-resource-mapping.js';

const copy = value => JSON.parse(canonicalMigrationJSON(value));
const same = (a,b) => canonicalMigrationJSON(a) === canonicalMigrationJSON(b);
const fail = code => { throw Error(code); };
const partsFor = r => r.kind === 'CREDENTIAL' ? ['METADATA','SECRET'] : ['GENERAL'];
const compare = (a,b) => a < b ? -1 : a > b ? 1 : 0;
const decode = new TextDecoder('utf-8',{fatal:true});
function capture(getIdentity) {
  const value=getIdentity(); if(!value)fail('publication_context_changed'); const frozen=copy(value);
  const guard=()=>{const now=getIdentity();if(!now||!same(now,frozen))fail('publication_context_changed');};
  return {identity:frozen,guard,async checked(work){guard();const result=await work();guard();return result;}};
}
function currentVault(context,vaultID) { const v=context.current.find(v=>v.vaultID===vaultID);if(!v)fail('publication_scope_mismatch');return v; }

// The desired request contains only graph/policy changes. Resource plaintext never enters transport requests.
export function buildWholePublicationRequest({context,vaultID,draft,cryptoValue=globalThis.crypto}) {
  accessID(context.teamID);const current=currentVault(context,accessID(vaultID));
  const vaults=context.current.map(v=>({vaultID:v.vaultID,resources:copy(v.resources),policy:copy(v.policy),contentChanges:[],custodianDeviceIDs:[...v.custodianDeviceIDs]}));
  for(const v of vaults)v.policy=v.policy.filter(p=>p.principalKind==='USER'
    ? context.memberships.some(m=>m.userID===p.principalID&&m.id===p.membershipID&&m.epoch===p.membershipEpoch)
    : p.principalKind==='GROUP'?context.groups.some(g=>g.id===p.principalID):false);
  const selected=vaults.find(v=>v.vaultID===vaultID),request={version:1,teamID:context.teamID,operationID:cryptoValue.randomUUID(),vaults,groupMutation:null};
  const resource=id=>{const r=selected.resources.find(r=>r.id===accessID(id));if(!r)fail('publication_resource_missing');return r;};
  const member=id=>{const m=context.memberships.find(m=>m.id===id||m.userID===id);if(!m)fail('publication_membership_stale');return m;};
  const group=id=>{const g=context.groups.find(g=>g.id===id);if(!g)fail('publication_stale');return g;};
  const changed=(r,part)=>{if(!selected.contentChanges.some(p=>p.resourceID===r.id&&p.part===part))selected.contentChanges.push({resourceID:r.id,part});};
  for(const change of draft.changes??[draft]) {
    if(change.type==='GRANT_CREATE') {
      if(change.targetKind==='VAULT'){if(change.targetID!==vaultID)fail('publication_scope_mismatch');validateMask('VAULT',change.permissionMask);}
      else {const r=resource(change.targetID);if((change.targetKind==='FOLDER')!==(r.kind==='FOLDER'))fail('invalid_access_target');validateMask(r.kind,change.permissionMask);}
      const p={id:cryptoValue.randomUUID(),teamID:context.teamID,vaultID,principalKind:change.principalKind,principalID:accessID(change.principalID),targetKind:change.targetKind,targetID:accessID(change.targetID),mask:change.permissionMask,revokedAt:null};
      if(p.principalKind==='USER'){const m=member(p.principalID);p.membershipID=m.id;p.membershipEpoch=m.epoch;}else if(p.principalKind==='GROUP')group(p.principalID);else fail('invalid_access_principal');
      selected.policy.push(p);
    } else if(['GRANT_CHANGE','GRANT_REVOKE'].includes(change.type)) {
      const p=selected.policy.find(p=>p.id===change.grantID);if(!p||change.expectedVersion!==current.sequence)fail('publication_stale');
      if(change.type==='GRANT_REVOKE')selected.policy=selected.policy.filter(p=>p.id!==change.grantID);
      else {validateMask(p.targetKind==='VAULT'?'VAULT':resource(p.targetID).kind,change.permissionMask);p.mask=change.permissionMask;}
    } else if(change.type==='RESOURCE_MOVE') {
      const r=resource(change.resourceID);if(change.expectedResourceVersion!==current.sequence)fail('publication_stale');
      if(change.newParentFolderID!==null&&resource(change.newParentFolderID).kind!=='FOLDER')fail('invalid_access_target');r.parentFolderID=change.newParentFolderID;
      const seen=new Set([r.id]);let p=r.parentFolderID;while(p!==null){if(seen.has(p))fail('folder_cycle');seen.add(p);p=resource(p).parentFolderID;}
      if(['HOST','SNIPPET'].includes(r.kind))changed(r,'GENERAL');
      if(r.kind==='FOLDER')for(const candidate of selected.resources.filter(v=>['FOLDER','HOST','SNIPPET'].includes(v.kind))) {const ancestors=new Set();let p=candidate.id;while(p!==null){if(ancestors.has(p))fail('folder_cycle');ancestors.add(p);if(p===r.id){changed(candidate,'GENERAL');break;}p=resource(p).parentFolderID;}}
    } else if(change.type==='RESOURCE_EDIT') {const r=resource(change.resourceID);if(r.kind==='FOLDER')fail('publication_edit_unsupported');for(const part of partsFor(r))changed(r,part);}
    else if(change.type==='GROUP_CREATE')request.groupMutation={action:'CREATE',groupID:cryptoValue.randomUUID(),name:change.name};
    else if(['GROUP_RENAME','GROUP_DELETE'].includes(change.type)) {
      const g=group(change.groupID);if(g.version!==change.expectedVersion)fail('publication_stale');
      request.groupMutation={action:change.type==='GROUP_DELETE'?'DELETE':'RENAME',groupID:g.id,...(change.type==='GROUP_RENAME'?{name:change.name}:{})};
      if(change.type==='GROUP_DELETE')for(const v of vaults)v.policy=v.policy.filter(p=>p.principalKind!=='GROUP'||p.principalID!==g.id);
    } else if(change.type==='GROUP_MEMBER_ADD') {
      const m=member(change.targetMembershipID);group(change.groupID);request.groupMutation={action:'ADD_MEMBER',groupID:change.groupID,userID:m.userID,membershipID:m.id,membershipEpoch:m.epoch};
    } else if(change.type==='GROUP_MEMBER_REMOVE') {
      const e=context.edges.find(e=>e.id===change.edgeID&&e.groupID===change.groupID);if(!e||e.version!==change.expectedVersion)fail('publication_stale');
      request.groupMutation={action:'REMOVE_MEMBER',groupID:e.groupID,userID:e.userID,membershipID:e.membershipID,membershipEpoch:e.membershipEpoch};
    } else fail('invalid_access_request');
  }
  for(const v of vaults){v.resources.sort((a,b)=>compare(a.id,b.id));v.policy.sort((a,b)=>compare(a.id,b.id));v.contentChanges.sort((a,b)=>compare(a.resourceID+'/'+a.part,b.resourceID+'/'+b.part));v.custodianDeviceIDs.sort(compare);}
  vaults.sort((a,b)=>compare(a.vaultID,b.vaultID));return request;
}

export async function repairWholePublicationSources({context,preview,transport,pinnedTrust,devicePrivateKey,ownIdentity,getIdentity,loadHighWater,saveHighWater,cryptoValue=globalThis.crypto}) {
  const c=capture(getIdentity);if(!same(ownIdentity,c.identity)||!devicePrivateKey)fail('publication_local_keys_required');
  if(typeof loadHighWater!=='function'||typeof saveHighWater!=='function')fail('publication_storage_failed');
  const plaintextByVault={},administrativeByVault={};
  for(const vault of context.current) {
    const historyScope={endpoint:c.identity.endpoint,accountID:c.identity.accountID,deviceID:c.identity.deviceID,teamID:context.teamID,vaultID:vault.vaultID};
    const highWater=await c.checked(()=>loadHighWater(historyScope));
    const predecessor=preview.binding.predecessors.find(p=>p.vaultID===vault.vaultID);
    if(!predecessor||['generationID','sequence','headerHash'].some(k=>predecessor[k]!==vault[k]))fail('publication_stale');
    let directory=null,cursor=null;const descriptors=[],cursors=new Set();
    do {
      const page=await c.checked(()=>transport.repairDirectory(preview,vault.vaultID,cursor));
      if(!Array.isArray(page.descriptors)||page.descriptors.length>100)fail('publication_incomplete');
      const base=copy({...page,descriptors:[],nextCursor:null});if(directory&&!same(directory,base))fail('publication_changed');directory??=base;descriptors.push(...page.descriptors);
      cursor=page.nextCursor;if(cursor!==null){if(typeof cursor!=='string'||cursors.has(cursor))fail('publication_incomplete');cursors.add(cursor);}
      if(descriptors.length>2000)fail('publication_limit');
    }while(cursor!==null);
    const h=directory.header?.payload,b=directory.publisher,s=directory.scope;
    if(!h||directory.headerHash!==predecessor.headerHash||directory.generationID!==predecessor.generationID||h.generationID!==predecessor.generationID||h.sequence!==predecessor.sequence
      ||s?.teamID!==context.teamID||s.vaultID!==vault.vaultID||s.attemptID!==predecessor.generationID||b?.generationID!==h.generationID||b.headerHash!==directory.headerHash
      ||b.accountID!==h.publisherAccountID||b.deviceID!==h.publisherDeviceID||b.keyVersion!==h.publisherKeyVersion)fail('publication_changed');
    const pin=await c.checked(()=>pinnedTrust.loadPin(c.identity.endpoint,b.accountID));let verified;
    try {
      if(b.historical===true)await c.checked(()=>verifyHistoricalDeviceCertificate({...b,trust:pin,expectedAccountID:b.accountID,expectedDeviceID:b.deviceID,expectedKeyVersion:b.keyVersion,cryptoValue}));
      else {verified=await c.checked(()=>verifyDeviceForWrapping({...b,trust:pin,expectedDeviceID:b.deviceID,cryptoValue}));if(b.certificate.payload.keyVersion!==b.keyVersion)fail('publisher_trust_unverified');}
    }catch(error){c.guard();fail('publisher_trust_unverified');}
    if(verified){const next=advancePinnedTrust(pin,{...pin,highWater:verified.highWater,checkpointDigest:verified.checkpointDigest});if(!same(pin,next))await c.checked(()=>pinnedTrust.advancePin(pin,next));}
    const verifyHistory=water=>c.checked(()=>verifyReaderHeader({header:directory.header,rootPublicKey:b.rootPublicKey,teamID:context.teamID,vaultID:vault.vaultID,highWater:water,cryptoValue}));
    if(await verifyHistory(highWater)!==directory.headerHash)fail('publication_changed');
    const m=directory.manifest,p=m?.payload;
    try {
      const key=await c.checked(()=>cryptoValue.subtle.importKey('raw',fromBase64(b.rootPublicKey),{name:'ECDSA',namedCurve:'P-256'},false,['verify']));
      if(!p||p.version!==2||!same(p.scope,s)||!same([...p.resources].sort((a,b)=>compare(a.id,b.id)),[...vault.resources].sort((a,b)=>compare(a.id,b.id)))
        ||p.policyHash!==await c.checked(()=>migrationHash(vault.policy,cryptoValue))
        ||!await c.checked(()=>cryptoValue.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,fromBase64(m.signature),migrationBytes(p))))fail('publication_manifest_invalid');
    }catch(error){c.guard();fail('publication_manifest_invalid');}
    const subject=directory.inventory?.payload;if(subject?.accountID!==c.identity.accountID||subject.deviceID!==c.identity.deviceID)fail('publication_subject_mismatch');
    const currentActor=context.memberships?.find(m=>m.userID===c.identity.accountID);if(context.memberships&&(!currentActor||currentActor.id!==subject.membershipID||currentActor.epoch!==subject.membershipEpoch))fail('publication_subject_mismatch');
    await c.checked(()=>verifyReaderInventory({inventory:directory.inventory,descriptors,header:directory.header,rootPublicKey:b.rootPublicKey,subject,cryptoValue}));
    const required=vault.resources.flatMap(r=>partsFor(r).map(part=>r.id+'/'+part)).sort(compare);
    if(!same(descriptors.map(d=>d.payload.resourceID+'/'+d.payload.part).sort(compare),required))fail('publication_custodian_materialization_required');
    for(const descriptor of descriptors)await c.checked(()=>verifyReaderDescriptor({descriptor,header:directory.header,rootPublicKey:b.rootPublicKey,cryptoValue}));
    const cores=descriptors.map(({payload:{headerHash,...core}})=>core).sort((a,b)=>compare(a.resourceID+'/'+a.part,b.resourceID+'/'+b.part));
    if(await c.checked(()=>publicationHash('descriptors',cores,cryptoValue))!==h.descriptorCommitment)fail('publication_incomplete');
    async function decrypt(wire,resourceID,part,expectedContext) {
      const e=wire.entry,w=e?.wrapper?.context;
      if(wire.headerHash!==directory.headerHash||wire.generationID!==h.generationID)fail('publication_changed');
      if(!w||e.accountID!==c.identity.accountID||e.deviceKeyVersion!==c.identity.keyVersion||w.deviceID!==c.identity.deviceID||w.membershipID!==subject.membershipID||w.membershipEpoch!==subject.membershipEpoch
        ||w.teamID!==context.teamID||w.vaultID!==vault.vaultID||w.resourceID!==resourceID||w.part!==part||w.keyVersion!==expectedContext.keyVersion)fail('publication_subject_mismatch');
      const cek=await c.checked(()=>unwrapResourceCEK({wrapper:e.wrapper,context:w,privateKey:devicePrivateKey,cryptoValue}));let plaintext;
      try {plaintext=await c.checked(()=>decryptResourcePart({envelope:wire.envelope,context:expectedContext,cek,cryptoValue}));return JSON.parse(decode.decode(plaintext));}
      finally {cek.fill(0);plaintext?.fill(0);}
    }
    const parts={};
    for(const descriptor of descriptors) {
      const d=descriptor.payload,r=vault.resources.find(r=>r.id===d.resourceID);
      if(!r||d.kind!==r.kind||d.parentFolderID!==r.parentFolderID)fail('publication_changed');
      const wire=await c.checked(()=>transport.repairPart(preview,vault.vaultID,d.resourceID,d.part));if(!same(wire.descriptor,descriptor))fail('publication_changed');
      await c.checked(()=>verifyReaderDescriptor({descriptor,header:directory.header,rootPublicKey:b.rootPublicKey,envelope:wire.envelope,entry:wire.entry,proof:wire.proof,cryptoValue}));
      const payload=await decrypt(wire,d.resourceID,d.part,d.context),link=payload?.link;
      if(!link||link.teamID!==context.teamID||link.vaultID!==vault.vaultID||link.generationID!==h.generationID||link.resourceID!==r.id||link.kind!==r.kind||link.part!==d.part)fail('publication_plaintext_invalid');
      (parts[r.id]??={})[d.part]=payload;
    }
    const commitment=p.reader?.sidecarCommitment;if(!commitment||commitment.resourceID!==directory.administrativeResourceID)fail('publication_administrative_unavailable');
    const wire=await c.checked(()=>transport.repairPart(preview,vault.vaultID,commitment.resourceID,'ADMINISTRATIVE'));
    if(wire.resourceID!==commitment.resourceID||wire.part!=='SECRET'||!same(wire.manifest,m)||!same(wire.scope,s)||!same(wire.publisher,b)
      ||wire.envelope?.context?.teamID!==context.teamID||wire.envelope.context.vaultID!==vault.vaultID||wire.envelope.context.resourceID!==commitment.resourceID||wire.envelope.context.part!=='SECRET'
      ||await c.checked(()=>publicationHash('ciphertext',wire.envelope,cryptoValue))!==commitment.envelopeHash)fail('publication_administrative_unavailable');
    await c.checked(()=>verifyWrapperProof({entry:wire.entry,proof:wire.proof,root:commitment.wrapperRoot,cryptoValue}));
    const data=await decrypt(wire,commitment.resourceID,'SECRET',wire.envelope.context);if(data.generationID!==h.generationID)fail('publication_administrative_unavailable');
    await verifyHistory(await c.checked(()=>loadHighWater(historyScope)));
    await c.checked(()=>saveHighWater(historyScope,{sequence:h.sequence,hash:directory.headerHash},c.guard));
    plaintextByVault[vault.vaultID]={verified:true,predecessor:copy(predecessor),parts};administrativeByVault[vault.vaultID]={verified:true,predecessor:copy(predecessor),data};
  }
  c.guard();return {plaintextByVault,administrativeByVault};
}

function applyLocalChanges(sources,request,draft,vaultID) {
  const parts=sources.plaintextByVault[vaultID].parts,vault=request.vaults.find(v=>v.vaultID===vaultID);
  for(const change of draft.changes??[draft])if(change.type==='RESOURCE_EDIT') {
    const payload=parts[change.resourceID],before=payload?.SECRET?.record??payload?.GENERAL?.record,after=change.record;
    if(!before||!after||after.id!==before.id||after.type!==before.type||!after.data||typeof after.data!=='object')fail('publication_plaintext_invalid');
    if(payload.SECRET){payload.SECRET.record=copy(after);payload.METADATA.metadata={...payload.METADATA.metadata,title:String(after.data.title??''),username:String(after.data.username??''),kind:String(after.data.kind??'password')};}
    else payload.GENERAL.record=copy(after);
  }
  if(!(draft.changes??[draft]).some(c=>c.type==='RESOURCE_MOVE'))return;
  const paths=new Map(),visiting=new Set();
  function folderPath(id) {
    if(id===null)return '';if(paths.has(id))return paths.get(id);if(visiting.has(id))fail('folder_cycle');visiting.add(id);
    const r=vault.resources.find(r=>r.id===id),folder=parts[id]?.GENERAL?.folder;if(r?.kind!=='FOLDER'||!folder)fail('publication_plaintext_invalid');
    const parent=folderPath(r.parentFolderID),path=[parent,folder.component].filter(Boolean).join('/');visiting.delete(id);paths.set(id,path);return path;
  }
  const mapping=sources.administrativeByVault[vaultID].data.mapping;
  for(const r of vault.resources.filter(r=>r.kind==='FOLDER')) {
    const folder=parts[r.id].GENERAL.folder,path=folderPath(r.id);if(folder.path===path)continue;
    const key=folderSourceKey(folder.type,path);if(mapping&&mapping[key]&&mapping[key]!==r.id)fail('folder_mapping_conflict');
    if(mapping){for(const [old,id] of Object.entries(mapping))if(id===r.id)delete mapping[old];mapping[key]=r.id;}folder.path=path;
  }
  // Folder labels inside records follow the authenticated graph, preserving legacy IDs and other fields.
  for(const r of vault.resources.filter(r=>['HOST','SNIPPET'].includes(r.kind))) {
    const record=parts[r.id].GENERAL.record,newPath=folderPath(r.parentFolderID);
    if((record.data.folder??'')!==newPath)record.data.folder=newPath;
  }
}

export function createWholePublicationAccessDriver({transport,sessionIdentity,getLocalKeys,checkpointRepository,publicationRepository,cryptoValue=globalThis.crypto}) {
  let context=null,pending=null,disposed=false;
  const getIdentity=()=>{
    const base=sessionIdentity();if(disposed||!context||!base)return null;
    return {...base,sessionID:context.sessionID,keyVersion:context.actorKeyVersion,predecessors:context.current.map(({vaultID,generationID,sequence,headerHash})=>({vaultID,generationID,sequence,headerHash})).sort((a,b)=>compare(a.vaultID,b.vaultID))};
  };
  const checkScope=scope=>{if(!context||scope.teamID!==context.teamID||!context.current.some(v=>v.vaultID===scope.vaultID))fail('publication_scope_mismatch');};
  async function local(c) {const keys=await c.checked(()=>getLocalKeys(copy(c.identity)));if(!keys?.root?.privateKey||!keys?.identity?.privateKey||!keys.pinnedTrust)fail('publication_local_keys_required');return keys;}
  const loadHighWater=scope=>{if(typeof publicationRepository?.loadHighWater!=='function')fail('publication_storage_failed');return publicationRepository.loadHighWater(scope);};
  const saveHighWater=(scope,water,guard)=>{if(typeof publicationRepository?.advanceHighWater!=='function')fail('publication_storage_failed');return publicationRepository.advanceHighWater(scope,water,guard);};
  const recordHighWater=async(receipt,guard)=>{
    const c=capture(getIdentity);
    for(const vault of receipt.vaults){
      const scope={endpoint:c.identity.endpoint,accountID:c.identity.accountID,deviceID:c.identity.deviceID,teamID:receipt.teamID,vaultID:vault.vaultID};
      const observed=await c.checked(()=>loadHighWater(scope));guard();
      // Receipt recovery is read-only: an independently observed later generation
      // already fences replay and must survive completion of this earlier commit.
      if(observed&&observed.sequence>vault.sequence)continue;
      await c.checked(()=>saveHighWater(scope,{sequence:vault.sequence,hash:vault.headerHash},()=>{c.guard();guard();}));
    }
  };
  const rowsFor=scope=>{checkScope(scope);const v=currentVault(context,scope.vaultID);return v.resources.map(r=>({...r,teamID:context.teamID,vaultID:v.vaultID,policyKind:r.kind,resourceVersion:v.sequence,version:v.sequence}));};
  const driver={
    get enabled(){return !disposed&&context?.publicationAvailable===true&&context.recoveryOnly!==true;},
    get writesBlocked(){return pending?.coordinator?.writesBlocked??!!pending?.prepared;},
    get pendingReceipt(){return pending?.coordinator?.pendingReceipt??pending?.remoteReceipt??null;},
    get pendingOperationID(){return pending?.prepared?(pending.metadata?.operationID??pending.preview.request.operationID):null;},
    get canResumePending(){return !!pending?.prepared && !pending.renewed && !pending.lost && !pending.absent;},
    getIdentity,
    async getContext(scope) {
      const start=capture(sessionIdentity),metadata=typeof checkpointRepository.discover==='function'?await start.checked(()=>checkpointRepository.discover({...start.identity,teamID:scope.teamID},start.guard)):[];
      if(metadata.length>10)fail('publication_resume_required');let value,chosen=null,remoteReceipt=null,absent=false;
      for(const saved of metadata) {
        const receipt=await start.checked(()=>transport.receipt(saved.operationID));let candidate;
        try{candidate=await start.checked(()=>transport.context({operationID:saved.operationID}));}catch(error){if(error.message==='publication_ready_attempt_exists')continue;
          if(error.message!=='publication_operation_not_found'||receipt)throw error;
          // Absence does not clear the local operation fence. Show cancellation
          // only after the normal current-authority gate permits recovery.
          candidate=await start.checked(()=>transport.context());absent=true;}
        if(candidate.operationState==='DISCARDED'){
          if(await start.checked(()=>transport.receipt(saved.operationID)))fail('publication_readback_required');
          await start.checked(()=>checkpointRepository.forgetDiscarded(saved,{operationID:saved.operationID,state:'DISCARDED'},start.guard));continue;}
        chosen=saved;remoteReceipt=receipt;value=candidate;break;
      }
      value??=await start.checked(()=>transport.context());
      const recoveryOnly=value.recoveryOnly===true;
      if(recoveryOnly && (!chosen||!remoteReceipt||remoteReceipt.operationID!==chosen.operationID||remoteReceipt.teamID!==scope.teamID
        ||remoteReceipt.actorAccountID!==start.identity.accountID||remoteReceipt.actorDeviceID!==start.identity.deviceID
        ||value.operationState!=='COMMITTED'||value.actorRole!==null
        ||!same(value.current.map(({vaultID,generationID,sequence,headerHash})=>({vaultID,generationID,sequence,headerHash})),remoteReceipt.vaults)
        ||value.current.some(v=>['resources','policy','custodianDeviceIDs'].some(k=>!Array.isArray(v[k])||v[k].length))
        ||['groups','edges','memberships'].some(k=>!Array.isArray(value[k])||value[k].length)))fail('publication_receipt_invalid');
      if(disposed||value.teamID!==scope.teamID||value.publicationAvailable!==true||value.environment!=='staging'||!recoveryOnly&&!['owner','admin'].includes(value.actorRole))fail('publication_unavailable');
      context=copy(value);checkScope(scope);pending=null;
      const c=capture(getIdentity);
      if(chosen){
        const renewed=recoveryOnly||chosen.sessionID!==context.sessionID||chosen.keyVersion!==context.actorKeyVersion;
        pending={metadata:chosen,remoteReceipt,renewed,absent,vaultID:scope.vaultID,prepared:true,coordinator:null};
        if(!renewed&&!absent){try{const stored=await c.checked(()=>checkpointRepository.load(chosen,c.guard));pending.preview={request:stored.state.request,binding:stored.state.binding};}catch(error){if(error.message!=='publication_checkpoint_lost')throw error;pending.lost=true;}}
      }
      return {formatState:'V2_ACTIVE',wholePublication:true,policyMutationAvailable:!pending,groupMutationAvailable:!pending,blockers:pending?['publication_resume_required']:[]};
    },
    resources(scope){return {rows:rowsFor(scope),nextCursor:null};},
    grants(scope){checkScope(scope);const v=currentVault(context,scope.vaultID);return {rows:v.policy.filter(p=>p.revokedAt===null).map(p=>({id:p.id,principal_kind:p.principalKind,principal_id:p.principalID,target_kind:p.targetKind,target_id:p.targetID,permission_mask:p.mask,version:v.sequence})),nextCursor:null};},
    groups(){return {rows:copy(context.groups),nextCursor:null};},
    groupMembers(groupID){return {rows:copy(context.edges.filter(e=>e.groupID===groupID)),nextCursor:null};},
    getResource(scope,resourceID){const row=rowsFor(scope).find(r=>r.id===resourceID);if(!row)fail('publication_resource_missing');return row;},
    async preview(scope,draft) {
      checkScope(scope);if(pending?.prepared)fail('publication_resume_required');const c=capture(getIdentity),intent=copy(draft);
      const request=buildWholePublicationRequest({context,vaultID:scope.vaultID,draft:intent,cryptoValue}),preview=await c.checked(()=>collectWholePublicationPreview({request,transport,getIdentity,cryptoValue}));
      pending={preview,intent,vaultID:scope.vaultID,prepared:false,coordinator:null};
      return {...copy(preview),wholePublication:true,complete:true,details:preview.rows.filter(r=>r.type==='DELTA').map(row=>({...copy(row),kind:context.current.find(v=>v.vaultID===row.vaultID)?.resources.find(r=>r.id===row.resourceID)?.kind}))};
    },
    async readRecord(reference) {
      checkScope(reference);const r=driver.getResource(reference,reference.resourceID);if(r.kind==='FOLDER')fail('publication_edit_unsupported');
      const request=buildWholePublicationRequest({context,vaultID:reference.vaultID,draft:{type:'RESOURCE_EDIT',resourceID:r.id},cryptoValue}),c=capture(getIdentity);
      const preview=await c.checked(()=>collectWholePublicationPreview({request,transport,getIdentity,cryptoValue})),keys=await local(c);
      const sources=await c.checked(()=>repairWholePublicationSources({context,preview,transport,pinnedTrust:keys.pinnedTrust,devicePrivateKey:keys.identity.privateKey,ownIdentity:c.identity,getIdentity,loadHighWater,saveHighWater,cryptoValue}));
      const parts=sources.plaintextByVault[reference.vaultID].parts[r.id];return copy(parts.SECRET?.record??parts.GENERAL?.record);
    },
    async commit(scope,approved) {
      checkScope(scope);const p=pending;if(!p||p.vaultID!==scope.vaultID||!same(p.preview.binding,approved.binding)||!same(p.preview.request,approved.request))fail('publication_resume_changed');
      const c=capture(getIdentity);
      if(!p.coordinator){const keys=await local(c);p.coordinator=createWholePublicationCoordinator({...keys,endpoint:c.identity.endpoint,deviceID:c.identity.deviceID,transport,checkpointRepository,getIdentity,recordHighWater,cryptoValue,
        readback:receipt=>Promise.all(receipt.vaults.map(v=>transport.readback(receipt.operationID,v.vaultID)))});}
      if(p.prepared){const resumed=await c.checked(()=>p.coordinator.resume({request:p.preview.request}));if(resumed?.committedAt){pending=null;return resumed;}}
      else {
        const keys=await local(c),sources=await c.checked(()=>repairWholePublicationSources({context,preview:p.preview,transport,pinnedTrust:keys.pinnedTrust,devicePrivateKey:keys.identity.privateKey,ownIdentity:c.identity,getIdentity,loadHighWater,saveHighWater,cryptoValue}));
        applyLocalChanges(sources,p.preview.request,p.intent,p.vaultID);
        await c.checked(()=>p.coordinator.prepare({request:p.preview.request,token:p.preview.token,...sources,onPrepared:()=>{p.prepared=true;},confirm:fresh=>same(fresh.binding,p.preview.binding)&&same(fresh.generations,p.preview.generations)}));
      }
      const receipt=await c.checked(()=>p.coordinator.commit({request:p.preview.request}));pending=null;return receipt;
    },
    async resumePrepared(scope){
      if(!pending?.prepared||pending.lost)fail('publication_checkpoint_lost');
      if(pending.absent)fail('publication_resume_required');
      if(pending.renewed){
        if(!pending.remoteReceipt)fail('publication_session_renewed');const c=capture(getIdentity),metadata=pending.metadata;
        const stored=await c.checked(()=>checkpointRepository.load(metadata,c.guard));
        const coordinator=createWholePublicationCoordinator({transport,checkpointRepository,getIdentity,recordHighWater,cryptoValue,readback:receipt=>Promise.all(receipt.vaults.map(v=>transport.readback(receipt.operationID,v.vaultID)))});
        pending.coordinator=coordinator;const receipt=await c.checked(()=>coordinator.recoverCommitted({request:stored.state.request,checkpointIdentity:metadata}));pending=null;return receipt;
      }
      return driver.commit(scope,pending.preview);
    },
    async discardPrepared(scope){checkScope(scope);if(!pending?.metadata||pending.remoteReceipt||pending.coordinator?.pendingReceipt)fail('publication_readback_required');
      const c=capture(getIdentity),metadata=pending.metadata,result=await c.checked(()=>transport.discard(metadata.operationID));
      if(result?.operationID!==metadata.operationID||result.state!=='DISCARDED')fail('publication_response_invalid');
      const receipt=await c.checked(()=>transport.receipt(metadata.operationID));
      if(receipt){pending.remoteReceipt=receipt;fail('publication_readback_required');}
      await c.checked(()=>checkpointRepository.forgetDiscarded(metadata,result,c.guard));pending=null;return result;
    },
    dispose(){disposed=true;pending=null;context=null;},
  };return driver;
}
