// Pure planning and consent only. Authenticated storage supplies the complete
// current Team read-set; this module cannot activate, mutate or deliver keys.
import { createHash, createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { canonicalMigrationJSON, validateMigrationResources, migrationRecipients } from './migration-policy.mjs';
import { isUUID } from './security.mjs';
import { requireAccessMutation, teamRoles, validateTeamName } from './team-policy.mjs';

const MAX_VAULTS=10, MAX_RESOURCES=1000, MAX_WRAPPERS=10000, MAX_PREVIEW_MS=300000;
const digest=/^[a-f0-9]{64}$/u;
const compare=(a,b)=>a<b?-1:a>b?1:0;
const hash=value=>createHash('sha256').update(canonicalMigrationJSON(value)).digest('hex');
const positive=n=>Number.isSafeInteger(n)&&n>0;
function fail(code,counts) {
  const error=new Error(code);error.code=code;
  if(counts)error.counts=Object.fromEntries(Object.entries(counts).filter(([,n])=>Number.isSafeInteger(n)&&n>=0));
  throw error;
}
function exact(value,keys,code='invalid_publication_request') {
  if(!value||typeof value!=='object'||Array.isArray(value)
    ||Object.keys(value).sort().join(',')!==[...keys].sort().join(','))fail(code);
}
function groupMutation(value) {
  if(value===null)return null;
  const shapes={CREATE:['action','groupID','name'],RENAME:['action','groupID','name'],DELETE:['action','groupID'],
    ADD_MEMBER:['action','groupID','userID','membershipID','membershipEpoch'],
    REMOVE_MEMBER:['action','groupID','userID','membershipID','membershipEpoch']};
  if(!shapes[value?.action])fail('invalid_publication_request');
  exact(value,shapes[value.action]);
  if(!isUUID(value.groupID)||value.userID!==undefined&&(!isUUID(value.userID)||!isUUID(value.membershipID)||!positive(value.membershipEpoch)))fail('invalid_publication_request');
  // No hidden whitespace rewrite after consent: bind exactly the accepted name.
  if(value.name!==undefined&&validateTeamName(value.name)!==value.name)fail('invalid_publication_request');
  return structuredClone(value);
}
export function validateWholePublicationRequest(request,current) {
  exact(request,['version','teamID','operationID','vaults','groupMutation']);
  if(request.version!==1||!isUUID(request.teamID)||!isUUID(request.operationID)||!Array.isArray(request.vaults)||!Array.isArray(current)||!current.length)fail('invalid_publication_request');
  if(current.length>MAX_VAULTS)fail('publication_limit',{vaults:current.length});
  if(current.some(v=>v.teamID!==request.teamID))fail('publication_scope_mismatch');
  let total=0;
  for(const v of request.vaults){if(!Array.isArray(v?.resources))fail('invalid_publication_request');total+=v.resources.length;}
  if(total>MAX_RESOURCES)fail('publication_limit',{vaults:current.length,resources:total});
  const currentByID=new Map();const priorIDs=new Map();
  for(const v of current) {
    if(!isUUID(v.vaultID)||!isUUID(v.generationID)||!positive(v.sequence)||v.sequence===Number.MAX_SAFE_INTEGER||!digest.test(v.headerHash)||currentByID.has(v.vaultID))fail('invalid_publication_request');
    validateMigrationResources(v.resources);currentByID.set(v.vaultID,v);
    for(const r of v.resources){if(priorIDs.has(r.id))fail('resource_id_collision');priorIDs.set(r.id,{vaultID:v.vaultID,kind:r.kind});}
  }
  const requestedIDs=request.vaults.map(v=>v?.vaultID);
  if(requestedIDs.length!==currentByID.size||new Set(requestedIDs).size!==currentByID.size||requestedIDs.some(id=>!currentByID.has(id)))fail('publication_participating_vaults');
  const ids=new Set();
  const vaults=request.vaults.map(v=>{
    exact(v,['vaultID','resources','policy','contentChanges','custodianDeviceIDs']);
    const resources=validateMigrationResources(v.resources);
    for(const r of v.resources) {
      const old=priorIDs.get(r.id);
      if(ids.has(r.id)||old&&(old.vaultID!==v.vaultID||old.kind!==r.kind))fail('resource_id_collision');
      ids.add(r.id);
    }
    if(!Array.isArray(v.policy)||!Array.isArray(v.contentChanges))fail('invalid_publication_request');
    const changes=new Set();
    for(const change of v.contentChanges){
      exact(change,['resourceID','part']);const r=resources.get(change.resourceID);
      if(!r||!(r.kind==='CREDENTIAL'?['METADATA','SECRET']:['GENERAL']).includes(change.part)||changes.has(change.resourceID+'/'+change.part))fail('invalid_publication_request');
      changes.add(change.resourceID+'/'+change.part);
    }
    if(!Array.isArray(v.custodianDeviceIDs)||!v.custodianDeviceIDs.length||v.custodianDeviceIDs.length>100
      ||v.custodianDeviceIDs.some(id=>!isUUID(id))||new Set(v.custodianDeviceIDs).size!==v.custodianDeviceIDs.length)fail('publication_custodian_unavailable');
    return {vaultID:v.vaultID,resources:structuredClone(v.resources).sort((a,b)=>compare(a.id,b.id)),
      policy:structuredClone(v.policy).sort((a,b)=>compare(a?.id,b?.id)),
      contentChanges:structuredClone(v.contentChanges).sort((a,b)=>compare(a.resourceID+'/'+a.part,b.resourceID+'/'+b.part)),
      custodianDeviceIDs:[...v.custodianDeviceIDs].sort(compare)};
  }).sort((a,b)=>compare(a.vaultID,b.vaultID));
  return {version:1,teamID:request.teamID,operationID:request.operationID,vaults,groupMutation:groupMutation(request.groupMutation)};
}
function checkSnapshot(s,teamID,vaultID) {
  if(!s||s.teamID!==teamID||s.vaultID!==vaultID||!Array.isArray(s.memberships)||!Array.isArray(s.devices)
    ||!Array.isArray(s.groups)||!Array.isArray(s.edges)||!s.raw)fail('publication_scope_mismatch');
  const memberships=new Map(),accounts=new Set(),devices=new Set();
  for(const m of s.memberships){
    if(!isUUID(m.id)||!isUUID(m.userID)||!positive(m.epoch)||!teamRoles.includes(m.role)||memberships.has(m.id)||accounts.has(m.userID))fail('publication_scope_mismatch');
    memberships.set(m.id,m);accounts.add(m.userID);
  }
  for(const d of s.devices){
    const m=memberships.get(d.membershipID);
    if(!m||!isUUID(d.deviceID)||d.accountID!==m.userID||d.membershipEpoch!==m.epoch||devices.has(d.deviceID))fail('publication_scope_mismatch');
    devices.add(d.deviceID);
  }
}
function deltaRows(before,after,currentSnapshot,successorSnapshot,vaultID) {
  const metadata=new Map();
  for(const s of [currentSnapshot,successorSnapshot])for(const m of s.memberships)metadata.set(m.id,m);
  const keys=[...new Set([...Object.keys(before),...Object.keys(after)])].sort(compare);
  return keys.filter(key=>(before[key]??0)!==(after[key]??0)).map(key=>{
    const [membershipID,resourceID]=key.split(':'),m=metadata.get(membershipID);
    return {vaultID,membershipID,accountID:m.userID,membershipEpoch:m.epoch,resourceID,beforeMask:before[key]??0,afterMask:after[key]??0};
  });
}
// A predecessor may retain grants for an already revoked principal. They remain
// authenticated history, but confer no current rights during repair/planning.
export function survivingPublicationPolicy(policy,snapshot){
  return policy.filter(g=>g.principalKind==='USER'
    ?snapshot.memberships.some(m=>m.id===g.membershipID&&m.userID===g.principalID&&m.epoch===g.membershipEpoch)
    :snapshot.groups.some(group=>group.id===g.principalID));
}
export async function deriveWholePublicationPlan({request,current,snapshots,actorRole}) {
  requireAccessMutation(actorRole);
  const canonical=validateWholePublicationRequest(request,current),orderedCurrent=[...current].sort((a,b)=>compare(a.vaultID,b.vaultID));
  const counts={vaults:canonical.vaults.length,resources:0,parts:0,wrappers:0};
  let evaluationCells=0;
  const readSet=[],successor=[],policies=[],recipientSets=[],effectiveDeltas=[],predecessors=[];
  for(const v of canonical.vaults){
    const old=orderedCurrent.find(c=>c.vaultID===v.vaultID),pair=snapshots?.[v.vaultID];
    checkSnapshot(pair?.current,canonical.teamID,v.vaultID);checkSnapshot(pair?.successor,canonical.teamID,v.vaultID);
    evaluationCells+=old.resources.length*pair.current.memberships.length*(old.policy.length+pair.current.edges.length+pair.current.devices.length)
      +v.resources.length*pair.successor.memberships.length*(v.policy.length+pair.successor.edges.length+pair.successor.devices.length);
    if(!Number.isSafeInteger(evaluationCells)||evaluationCells>20000000)fail('publication_limit',{evaluationCells});
    const before={},after={};
    migrationRecipients({resources:old.resources,policy:survivingPublicationPolicy(old.policy,pair.current),snapshot:pair.current,actorRole:'owner',effectiveMasks:before,requireDevices:false});
    const recipients=migrationRecipients({resources:v.resources,policy:v.policy,snapshot:pair.successor,actorRole,effectiveMasks:after});
    const custody=v.custodianDeviceIDs.map(id=>{
      const target=pair.successor.devices.find(d=>d.deviceID===id);
      if(!target||!old.custodianDeviceIDs?.includes(id))fail('publication_custodian_unavailable');
      return target;
    });
    const targetIdentity=d=>({accountID:d.accountID,deviceID:d.deviceID,membershipID:d.membershipID,membershipEpoch:d.membershipEpoch,
      deviceKeyVersion:d.certificate?.payload?.keyVersion??null});
    const parts=[];
    for(const [resourceID,values]of Object.entries(recipients).sort(([a],[b])=>compare(a,b)))for(const [part,targets]of Object.entries(values).sort(([a],[b])=>compare(a,b))){
      counts.parts++;counts.wrappers+=targets.length;
      parts.push({resourceID,part,devices:targets.map(targetIdentity).sort((a,b)=>compare(a.deviceID,b.deviceID))});
    }
    counts.resources+=v.resources.length;counts.parts++;counts.wrappers+=custody.length;
    const predecessor={vaultID:v.vaultID,generationID:old.generationID,sequence:old.sequence,headerHash:old.headerHash};
    predecessors.push(predecessor);
    readSet.push({predecessor,resources:structuredClone(old.resources).sort((a,b)=>compare(a.id,b.id)),
      policy:structuredClone(old.policy).sort((a,b)=>compare(a.id,b.id)),custodianDeviceIDs:[...(old.custodianDeviceIDs??[])].sort(compare),snapshot:pair.current});
    policies.push({vaultID:v.vaultID,policy:v.policy});
    successor.push({vaultID:v.vaultID,sequence:old.sequence+1,previousHash:old.headerHash,resources:v.resources,policyHash:hash(v.policy),snapshot:pair.successor});
    recipientSets.push({vaultID:v.vaultID,parts,custodians:custody.map(targetIdentity).sort((a,b)=>compare(a.deviceID,b.deviceID))});
    effectiveDeltas.push(...deltaRows(before,after,pair.current,pair.successor,v.vaultID));
  }
  if(counts.wrappers>MAX_WRAPPERS)fail('publication_limit',counts);
  return {request:canonical,requestHash:hash(canonical),readSetHash:hash(readSet),successorHash:hash(successor),
    policyHash:hash(policies),recipientHash:hash(recipientSets),predecessors,counts,effectiveDeltas,recipients:recipientSets};
}

function checkBinding(b) {
  exact(b,['version','teamID','operationID','actorAccountID','sessionID','actorDeviceID','keyVersion','requestHash','readSetHash','successorHash','policyHash','recipientHash','predecessors','counts','effectiveAt','rowsHash','rowCount']);
  if(b.version!==1||['teamID','operationID','actorAccountID','sessionID','actorDeviceID'].some(k=>!isUUID(b[k]))||!positive(b.keyVersion)
    ||['requestHash','readSetHash','successorHash','policyHash','recipientHash','rowsHash'].some(k=>!digest.test(b[k]))
    ||!Number.isSafeInteger(b.rowCount)||b.rowCount<0||b.rowCount>22010
    ||typeof b.effectiveAt!=='string'||b.effectiveAt.length>64||!Number.isFinite(Date.parse(b.effectiveAt))
    ||!Array.isArray(b.predecessors)||!b.predecessors.length||b.predecessors.length>MAX_VAULTS)fail('invalid_publication_request');
  const ids=new Set();
  for(const p of b.predecessors){exact(p,['vaultID','generationID','sequence','headerHash']);
    if(!isUUID(p.vaultID)||!isUUID(p.generationID)||!positive(p.sequence)||!digest.test(p.headerHash)||ids.has(p.vaultID))fail('invalid_publication_request');ids.add(p.vaultID);}
  exact(b.counts,['vaults','resources','parts','wrappers']);
  if(Object.values(b.counts).some(n=>!Number.isSafeInteger(n)||n<0)||b.counts.vaults!==ids.size
    ||b.counts.resources>MAX_RESOURCES||b.counts.wrappers>MAX_WRAPPERS)fail('invalid_publication_request');
}
export class WholePublicationPreviewTokens {
  constructor({secret,clock=Date.now,ttlMS=MAX_PREVIEW_MS}={}) {
    if(typeof secret!=='string'||Buffer.byteLength(secret)<32||typeof clock!=='function'||!positive(ttlMS)||ttlMS>MAX_PREVIEW_MS)fail('publication_unavailable');
    this.secret=secret;this.clock=clock;this.ttlMS=ttlMS;this.instanceID=randomUUID();
  }
  signature(body){return createHmac('sha256',this.secret).update('whole-publication-preview-v1\0'+body).digest('base64url');}
  issue(binding) {
    checkBinding(binding);const issuedAt=this.clock(),expiresAt=issuedAt+this.ttlMS;
    if(!Number.isSafeInteger(issuedAt)||issuedAt<0||!Number.isSafeInteger(expiresAt))fail('publication_unavailable');
    const body=Buffer.from(canonicalMigrationJSON({version:1,instanceID:this.instanceID,issuedAt,expiresAt,binding})).toString('base64url');
    if(body.length>16384)fail('invalid_publication_request');
    return body+'.'+this.signature(body);
  }
  open(token,binding) {
    try{checkBinding(binding);}catch{fail('preview_invalidated');}
    const value=this.claims(token);
    if(canonicalMigrationJSON(value.binding)!==canonicalMigrationJSON(binding))fail('preview_invalidated');
    return {issuedAt:value.issuedAt,expiresAt:value.expiresAt};
  }
  claims(token) {
    if(typeof token!=='string'||token.length>16428)fail('preview_invalidated');
    const [body,signature,...extra]=token.split('.');
    if(extra.length||!body||!/^[A-Za-z0-9_-]+$/u.test(body)||!/^[A-Za-z0-9_-]{43}$/u.test(signature??'')
      ||!timingSafeEqual(Buffer.from(signature),Buffer.from(this.signature(body))))fail('preview_invalidated');
    let value;try{value=JSON.parse(Buffer.from(body,'base64url').toString('utf8'));exact(value,['version','instanceID','issuedAt','expiresAt','binding']);}catch{fail('preview_invalidated');}
    try{checkBinding(value.binding);}catch{fail('preview_invalidated');}
    if(value.version!==1||value.instanceID!==this.instanceID
      ||!Number.isSafeInteger(value.issuedAt)||!Number.isSafeInteger(value.expiresAt)||value.expiresAt-value.issuedAt!==this.ttlMS
      ||value.issuedAt>this.clock())fail('preview_invalidated');
    if(value.expiresAt<=this.clock())fail('preview_expired');
    return value;
  }
}
