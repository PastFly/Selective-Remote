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

// Normalized copies make ordering deterministic and prevent caller mutation across awaits.
// Old flat records are supported as evidence, never silently treated as a commit.
export function validateFenceEvent(value){
 if(keys(value,['teamID','vaultID','attemptID','manifestHash','schemaFloor'])){
  if(![19,20].includes(value.schemaFloor))invalid();
  const {schemaFloor,...v}=value;return {...tuple(v,false),schemaFloor};
 }
 if(!object(value)||value.version!==2)invalid();
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
 if(event.version===2&&event.type!=='PENDING_INTENT')invalid();
 const domain=event.version===2?'selective-remote/deployment-fence-intent/v2\0':'selective-remote/deployment-fence-intent/legacy-v1\0';
 return createHash('sha256').update(domain).update(canonical(event)).digest('hex');
}

export function reduceFenceEvents(events){
 if(!Array.isArray(events))invalid();
 const intents=new Map(),outcomes=new Map(),committed=new Map(),pending=new Map(),generations=new Map(),vaultTeams=new Map();
 for(const raw of events){
  const event=validateFenceEvent(raw);
  if(!event.version||event.type==='PENDING_INTENT'){
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
 return {schemaFloor:Math.max(19,...finalCommitted.map(v=>v.schemaFloor),...finalPending.map(p=>p.schemaFloor)),committed:finalCommitted,
  pending:finalPending,outcomes:[...outcomes.values()].sort((a,b)=>compare(a.intentID,b.intentID))};
}
