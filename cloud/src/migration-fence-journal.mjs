import {createHash} from 'node:crypto';

export const FENCE_MAX_BYTES = 4 * 1024 * 1024;
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hash=/^[a-f0-9]{64}$/u;
const isUUID=v=>typeof v==='string'&&uuid.test(v);
const isHash=v=>typeof v==='string'&&hash.test(v);
const invalid=()=>{throw Error('invalid_deployment_fence');};
const conflict=()=>{throw Error('deployment_fence_conflict');};
const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
const keys=(v,names)=>object(v)&&Object.keys(v).sort().join(',')===[...names].sort().join(',');
const compare=(a,b)=>a<b?-1:a>b?1:0;
const compareVault=(a,b)=>compare(a.teamID,b.teamID)||compare(a.vaultID,b.vaultID);
const scope=v=>v.teamID+':'+v.vaultID;
const canonical=v=>Array.isArray(v)?'['+v.map(canonical).join(',')+']':object(v)?'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}':JSON.stringify(v);
const same=(a,b)=>canonical(a)===canonical(b);

function tuple(value,modern){
 const fields=modern?['teamID','vaultID','generationID','sequence','headerHash','manifestHash']:['teamID','vaultID','attemptID','manifestHash'];
 if(!keys(value,fields)||!isUUID(value.teamID)||!isUUID(value.vaultID)||!isHash(value.manifestHash))invalid();
 if(modern){
  if(!isUUID(value.generationID)||!Number.isSafeInteger(value.sequence)||value.sequence<1||!isHash(value.headerHash))invalid();
  return {teamID:value.teamID,vaultID:value.vaultID,generationID:value.generationID,sequence:value.sequence,headerHash:value.headerHash,manifestHash:value.manifestHash};
 }
 if(!isUUID(value.attemptID))invalid();
 return {teamID:value.teamID,vaultID:value.vaultID,attemptID:value.attemptID,manifestHash:value.manifestHash};
}
function v1Tuple(value){
 if(!keys(value,['vaultKind','ownerID','vaultID','revision','ciphertextHash','envelopeHash'])||!['PERSONAL','TEAM'].includes(value.vaultKind)
  ||!isUUID(value.ownerID)||!isUUID(value.vaultID)||!Number.isSafeInteger(value.revision)||value.revision<0||!isHash(value.ciphertextHash)||!isHash(value.envelopeHash))invalid();
 return {vaultKind:value.vaultKind,ownerID:value.ownerID,vaultID:value.vaultID,revision:value.revision,ciphertextHash:value.ciphertextHash,envelopeHash:value.envelopeHash};
}

// Normalized copies make ordering deterministic and prevent caller mutation across awaits.
// Old flat records are supported as evidence, never silently treated as a commit.
export function validateFenceEvent(value){
 if(keys(value,['teamID','vaultID','attemptID','manifestHash','schemaFloor'])){
  if(![19,20].includes(value.schemaFloor))invalid();
  const {schemaFloor,...v}=value;return {...tuple(v,false),schemaFloor};
 }
 if(!object(value)||value.version!==2)invalid();
 if(value.type==='V1_WRITER_FLOOR'){
  if(!keys(value,['version','type','writerProtocol'])||value.writerProtocol!==1)invalid();
  return {version:2,type:value.type,writerProtocol:value.writerProtocol};
 }
 if(value.type==='V1_BASELINE'){
  if(!keys(value,['version','type','baselineID','vaults'])||!isUUID(value.baselineID)
   ||!Array.isArray(value.vaults)||value.vaults.length>20000)invalid();
  const vaults=value.vaults.map(v1Tuple).sort((a,b)=>compare(a.vaultKind,b.vaultKind)||compare(a.vaultID,b.vaultID));
  if(new Set(vaults.map(v=>v.vaultKind+':'+v.vaultID)).size!==vaults.length)invalid();
  return {version:2,type:value.type,baselineID:value.baselineID,vaults};
 }
 if(value.type==='V1_PENDING_INTENT'){
  if(!keys(value,['version','type','intentID','operationID','vaultKind','ownerID','vaultID','baseRevision','revision','ciphertextHash','envelopeHash'])
   ||!isUUID(value.intentID)||!isUUID(value.operationID)||!['PERSONAL','TEAM'].includes(value.vaultKind)
   ||!isUUID(value.ownerID)||!isUUID(value.vaultID)||!Number.isSafeInteger(value.baseRevision)||value.baseRevision<0
   ||!Number.isSafeInteger(value.revision)||value.revision!==value.baseRevision+1||!isHash(value.ciphertextHash)||!isHash(value.envelopeHash))invalid();
  return {version:2,type:value.type,intentID:value.intentID,operationID:value.operationID,vaultKind:value.vaultKind,
   ownerID:value.ownerID,vaultID:value.vaultID,baseRevision:value.baseRevision,revision:value.revision,ciphertextHash:value.ciphertextHash,envelopeHash:value.envelopeHash};
 }
 if(['V1_CONFIRMED_COMMIT','V1_PROVEN_ABORT'].includes(value.type)){
  if(!keys(value,['version','type','intentID','intentDigest'])||!isUUID(value.intentID)||!isHash(value.intentDigest))invalid();
  return {version:2,type:value.type,intentID:value.intentID,intentDigest:value.intentDigest};
 }
 if(value.type==='PENDING_INTENT'){
  if(!keys(value,['version','type','intentID','operationID','kind','schemaFloor','vaults'])||!isUUID(value.intentID)||!isUUID(value.operationID))invalid();
  if(!((value.kind==='MIGRATION'&&[19,20].includes(value.schemaFloor))||(value.kind==='PUBLICATION'&&value.schemaFloor===22)))invalid();
  if(!Array.isArray(value.vaults)||!value.vaults.length||value.vaults.length>10||(value.kind==='MIGRATION'&&value.vaults.length!==1))invalid();
  const vaults=value.vaults.map(v=>tuple(v,value.schemaFloor!==19)).sort(compareVault);
  if(new Set(vaults.map(v=>v.vaultID)).size!==vaults.length||new Set(vaults.map(v=>v.teamID)).size!==1)invalid();
  return {version:2,type:value.type,intentID:value.intentID,operationID:value.operationID,kind:value.kind,schemaFloor:value.schemaFloor,vaults};
 }
 if(!['CONFIRMED_COMMIT','PROVEN_ABORT'].includes(value.type)||!keys(value,['version','type','intentID','intentDigest'])||
  !(isUUID(value.intentID)||(typeof value.intentID==='string'&&/^legacy:[a-f0-9]{64}$/u.test(value.intentID)))||!isHash(value.intentDigest))invalid();
 return {version:2,type:value.type,intentID:value.intentID,intentDigest:value.intentDigest};
}

export function fenceIntentDigest(value){
 const event=validateFenceEvent(value);
 if(event.version===2&&!['PENDING_INTENT','V1_PENDING_INTENT'].includes(event.type))invalid();
 const domain=event.type==='V1_PENDING_INTENT'?'selective-remote/v1-writer-fence-intent/v1\0':event.version===2?'selective-remote/deployment-fence-intent/v2\0':'selective-remote/deployment-fence-intent/legacy-v1\0';
 return createHash('sha256').update(domain).update(canonical(event)).digest('hex');
}

export function reduceFenceEvents(events){
 if(!Array.isArray(events))invalid();
 const intents=new Map(),outcomes=new Map(),committed=new Map(),pending=new Map(),generations=new Map(),vaultTeams=new Map();
 const v1Intents=new Map(),v1Outcomes=new Map(),v1Committed=new Map(),v1Pending=new Map(),v1Owners=new Map(),v1Operations=new Map();
 let writerFloor=0,v1Baseline=null;
 for(const raw of events){
  const event=validateFenceEvent(raw);
  if(event.type==='V1_WRITER_FLOOR'){if(pending.size||v1Pending.size)conflict();writerFloor=Math.max(writerFloor,event.writerProtocol);continue;}
  if(event.type==='V1_BASELINE'){
   if((writerFloor!==0&&!v1Baseline)||v1Intents.size||pending.size||v1Pending.size)conflict();
   if(v1Baseline){if(!same(v1Baseline,event))conflict();continue;}
   v1Baseline=event;
   for(const item of event.vaults){const key=item.vaultKind+':'+item.vaultID;v1Owners.set(key,item.ownerID);v1Committed.set(key,item);}
   continue;
  }
  if(event.type==='V1_PENDING_INTENT'){
   if(writerFloor!==1||!v1Baseline||pending.size)conflict();
   const digest=fenceIntentDigest(event),old=v1Intents.get(event.intentID);
   const intent={...event,intentDigest:digest},key=event.vaultKind+':'+event.vaultID;
   if(old){if(!same(old,intent))conflict();continue;}
   if(v1Operations.has(event.operationID))conflict();
   if(v1Owners.has(key)&&v1Owners.get(key)!==event.ownerID)conflict();
   if([...v1Pending.values()].some(p=>p.vaultKind===event.vaultKind&&p.vaultID===event.vaultID))conflict();
   const previous=v1Committed.get(key);
   if(event.baseRevision!==(previous?.revision??0))conflict();
   v1Owners.set(key,event.ownerID);v1Operations.set(event.operationID,event.intentID);v1Intents.set(event.intentID,intent);v1Pending.set(event.intentID,intent);continue;
  }
  if(event.type==='V1_CONFIRMED_COMMIT'||event.type==='V1_PROVEN_ABORT'){
   const intent=v1Intents.get(event.intentID);if(!intent||intent.intentDigest!==event.intentDigest)conflict();
   const old=v1Outcomes.get(event.intentID);if(old){if(!same(old,event))conflict();continue;}
   if(event.type==='V1_CONFIRMED_COMMIT')v1Committed.set(intent.vaultKind+':'+intent.vaultID,
    {vaultKind:intent.vaultKind,ownerID:intent.ownerID,vaultID:intent.vaultID,revision:intent.revision,ciphertextHash:intent.ciphertextHash,envelopeHash:intent.envelopeHash});
   v1Pending.delete(event.intentID);v1Outcomes.set(event.intentID,event);continue;
  }
  if(!event.version||event.type==='PENDING_INTENT'){
   if(v1Pending.size)conflict();
   const intentDigest=fenceIntentDigest(event);
   const intent=event.version===2?{...event,intentDigest}:{version:1,type:'PENDING_INTENT',legacy:true,intentID:'legacy:'+intentDigest,
    operationID:event.attemptID,kind:'MIGRATION',schemaFloor:event.schemaFloor,
    vaults:[{teamID:event.teamID,vaultID:event.vaultID,attemptID:event.attemptID,manifestHash:event.manifestHash}],intentDigest};
   const old=intents.get(intent.intentID);
   if(old){if(!same(old,intent))conflict();continue;}
   for(const v of intent.vaults){
    if(vaultTeams.has(v.vaultID)&&vaultTeams.get(v.vaultID)!==v.teamID)conflict();vaultTeams.set(v.vaultID,v.teamID);
    if([...pending.values()].some(p=>p.vaults.some(w=>scope(w)===scope(v))))conflict();
    const previous=committed.get(scope(v));
    if(previous){
     if(previous.sequence!==undefined){
      if(v.sequence===undefined||v.sequence<previous.sequence)conflict();
      if(v.sequence===previous.sequence&&['generationID','headerHash','manifestHash'].some(k=>v[k]!==previous[k]))conflict();
     }else if(v.sequence===undefined){if(v.attemptID!==previous.attemptID||v.manifestHash!==previous.manifestHash)conflict();}
     else if(v.sequence===1&&v.generationID!==previous.attemptID)conflict();
     if(intent.schemaFloor<previous.schemaFloor)conflict();
    }
    const generationID=v.generationID??v.attemptID,known=generations.get(generationID);
    if(known){
     if(['teamID','vaultID','manifestHash'].some(k=>known[k]!==v[k]))conflict();
     if(known.sequence!==undefined&&(known.sequence!==v.sequence||known.headerHash!==v.headerHash))conflict();
    }
    if(!known||v.sequence!==undefined)generations.set(generationID,v);
   }
   intents.set(intent.intentID,intent);pending.set(intent.intentID,intent);
  }else{
   const intent=intents.get(event.intentID);if(!intent||intent.intentDigest!==event.intentDigest)conflict();
   const old=outcomes.get(event.intentID);if(old){if(!same(old,event))conflict();continue;}
   if(intent.legacy&&event.type==='PROVEN_ABORT')conflict();
   if(event.type==='CONFIRMED_COMMIT')for(const v of intent.vaults)committed.set(scope(v),{...v,schemaFloor:intent.schemaFloor});
   pending.delete(event.intentID);outcomes.set(event.intentID,event);
  }
 }
 const finalCommitted=[...committed.values()].sort(compareVault),finalPending=[...pending.values()].sort((a,b)=>compare(a.intentID,b.intentID));
 return {...(writerFloor?{writerFloor}:{}),...(v1Baseline?{v1BaselineID:v1Baseline.baselineID,v1Pending:[...v1Pending.values()],v1Committed:[...v1Committed.values()],v1Outcomes:[...v1Outcomes.values()]}:{}),schemaFloor:Math.max(19,...finalCommitted.map(v=>v.schemaFloor),...finalPending.map(p=>p.schemaFloor)),committed:finalCommitted,
  pending:finalPending,outcomes:[...outcomes.values()].sort((a,b)=>compare(a.intentID,b.intentID))};
}
