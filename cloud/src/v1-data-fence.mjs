import { createHash } from 'node:crypto';

const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hash=/^[a-f0-9]{64}$/u;
const integer=value=>{
  if(typeof value==='string'&&/^(0|[1-9][0-9]*)$/u.test(value))value=Number(value);
  return Number.isSafeInteger(value)&&value>=0?value:null;
};
const key=value=>`${value.vaultKind}:${value.vaultID}`;
function validIdentity(value){
  return value&&['PERSONAL','TEAM'].includes(value.vaultKind)&&typeof value.ownerID==='string'&&uuid.test(value.ownerID)
    &&typeof value.vaultID==='string'&&uuid.test(value.vaultID);
}
export function v1CiphertextHash(value){
  if(value!==null&&typeof value!=='string')throw Error('invalid_v1_ciphertext');
  const digest=createHash('sha256').update('selective-remote/v1-ciphertext/v1\0');
  return digest.update(value===null?Buffer.from([0]):Buffer.from([1])).update(value??'','utf8').digest('hex');
}
function canonical(value){
  if(value===null||typeof value==='string'||typeof value==='boolean'||(typeof value==='number'&&Number.isFinite(value)))return JSON.stringify(value);
  if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
  if(value&&typeof value==='object'&&Object.getPrototypeOf(value)===Object.prototype)
    return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
  throw Error('invalid_v1_envelope');
}
export function v1EnvelopeHash(value){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).sort().join(',')!==
    ['authTag','ciphertext','contentHash','envelopeVersion','keyGeneration','nonce','wrappedKey','wrappers'].sort().join(','))throw Error('invalid_v1_envelope');
  const encoded=canonical(value);
  return createHash('sha256').update('selective-remote/v1-envelope/v1\0').update(encoded).digest('hex');
}
// This expression is used only with the fixed internal alias "v".
export const v1TeamWrappersSQL=`(SELECT COALESCE(jsonb_agg(jsonb_build_object(
  'keyGeneration',w.key_generation::text,'membershipID',w.membership_id,'membershipEpoch',w.membership_epoch::text,
  'deviceID',w.device_id,'wrapperVersion',w.wrapper_version,'ephemeralPublicKey',w.ephemeral_public_key,
  'ciphertext',w.ciphertext,'nonce',w.nonce,'authTag',w.auth_tag,'contextHash',w.context_hash,
  'createdByDeviceID',w.created_by_device_id) ORDER BY w.key_generation,w.device_id),'[]'::jsonb)
  FROM public.shared_vault_key_wrappers w WHERE w.vault_id=v.id)`;
export async function readV1VaultState(query){
  const result=await query(`SELECT 'PERSONAL' AS "vaultKind",user_id AS "ownerID",id AS "vaultID",revision,ciphertext,
    jsonb_build_object('envelopeVersion',envelope_version,'wrappedKey',wrapped_key,'ciphertext',ciphertext,'nonce',nonce,'authTag',auth_tag,'contentHash',content_hash,'keyGeneration',NULL,'wrappers',NULL) AS envelope
    FROM public.personal_vaults
    UNION ALL SELECT 'TEAM' AS "vaultKind",v.team_id AS "ownerID",v.id AS "vaultID",v.revision,v.ciphertext,
    jsonb_build_object('envelopeVersion',v.envelope_version,'wrappedKey',NULL,'ciphertext',v.ciphertext,'nonce',v.nonce,'authTag',v.auth_tag,'contentHash',v.content_hash,'keyGeneration',v.key_generation::text,'wrappers',${v1TeamWrappersSQL}) AS envelope
    FROM public.shared_vaults v WHERE v.format_state='V1_ACTIVE'`);
  if(!result||!Array.isArray(result.rows)||result.rows.length>20000)throw Error('deployment_v1_data_mismatch');
  const seen=new Set(),state=[];
  for(const row of result.rows){
    if(!validIdentity(row))throw Error('deployment_v1_data_mismatch');
    const revision=integer(row.revision),id=key(row);
    if(revision===null||seen.has(id)||(revision===0&&row.ciphertext!==null)
      ||(revision>0&&(typeof row.ciphertext!=='string'||!row.ciphertext.length)))throw Error('deployment_v1_data_mismatch');
    if(!row.envelope||row.envelope.ciphertext!==row.ciphertext)throw Error('deployment_v1_data_mismatch');
    let envelopeHash;try{envelopeHash=v1EnvelopeHash(row.envelope);}catch{throw Error('deployment_v1_data_mismatch');}
    seen.add(id);state.push({vaultKind:row.vaultKind,ownerID:row.ownerID,vaultID:row.vaultID,revision,ciphertextHash:v1CiphertextHash(row.ciphertext),envelopeHash});
  }
  return state.sort((a,b)=>a.vaultKind<b.vaultKind?-1:a.vaultKind>b.vaultKind?1:a.vaultID<b.vaultID?-1:a.vaultID>b.vaultID?1:0);
}
export async function assertV1DataFloor(query,snapshot){
  if(!snapshot||typeof snapshot.v1BaselineID!=='string'||!uuid.test(snapshot.v1BaselineID)||!Array.isArray(snapshot.v1Committed)
    ||!Array.isArray(snapshot.v1Pending))throw Error('deployment_v1_history_unavailable');
  if(snapshot.v1Pending.length)throw Error('deployment_fence_pending');
  const expected=new Map();
  for(const item of snapshot.v1Committed){
    if(!validIdentity(item)||integer(item.revision)===null||typeof item.ciphertextHash!=='string'||!hash.test(item.ciphertextHash)||typeof item.envelopeHash!=='string'||!hash.test(item.envelopeHash)||expected.has(key(item)))
      throw Error('deployment_v1_data_mismatch');
    expected.set(key(item),item);
  }
  const rows=await readV1VaultState(query);
  if(rows.length!==expected.size)throw Error('deployment_v1_data_mismatch');
  for(const row of rows){
    const item=expected.get(key(row));
    if(!item||item.ownerID!==row.ownerID||integer(item.revision)!==integer(row.revision)
      ||item.ciphertextHash!==row.ciphertextHash||item.envelopeHash!==row.envelopeHash)throw Error('deployment_v1_data_mismatch');
    expected.delete(key(row));
  }
  if(expected.size)throw Error('deployment_v1_data_mismatch');
  return true;
}
