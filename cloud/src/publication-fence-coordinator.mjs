import {randomUUID} from 'node:crypto';
import {canonicalMigrationJSON,migrationHash,verifyMigrationManifest} from './migration-policy.mjs';
import {publicationHash,verifyReaderHeader} from '../public/vault-publication-v1.js';
import {validateFenceEvent,fenceIntentDigest} from './migration-fence-journal.mjs';
import {v1CiphertextHash,v1EnvelopeHash,v1TeamWrappersSQL} from './v1-data-fence.mjs';

const same=(a,b)=>canonicalMigrationJSON(a)===canonicalMigrationJSON(b);
const abortProofs=new WeakMap();
function fail(code){throw Error(code);}

export class PublicationFenceCoordinator{
  #intents=new Map();
  constructor({fence}){
    if(typeof fence?.append!=='function'||typeof fence?.snapshot!=='function')fail('deployment_fence_required');
    this.fence=fence;
  }
  async beforeCommit(fields){
    const copy=structuredClone(fields),isV1=copy.kind==='V1';
    if(isV1)delete copy.kind;
    const intent=validateFenceEvent({...copy,version:2,type:isV1?'V1_PENDING_INTENT':'PENDING_INTENT',intentID:randomUUID()});
    await this.fence.append(intent);
    this.#intents.set(intent.intentID,{...structuredClone(intent),intentDigest:fenceIntentDigest(intent)});
    return structuredClone(intent);
  }
  async #pending(intentID){
    if(this.#intents.has(intentID))return this.#intents.get(intentID);
    const state=await this.fence.snapshot();
    const intent=[...state.pending,...(state.v1Pending??[])].find(item=>item.intentID===intentID);
    if(!intent)fail('deployment_fence_intent_not_found');
    this.#intents.set(intentID,structuredClone(intent));return intent;
  }
  async confirmCommit({intentID,readCommittedOutcome}){
    if(typeof readCommittedOutcome!=='function')fail('deployment_fence_readback_required');
    const intent=await this.#pending(intentID),outcome=await readCommittedOutcome(structuredClone(intent));
    if(!outcome)fail('deployment_fence_pending');
    if(intent.type==='V1_PENDING_INTENT'){
      if(outcome.kind!=='V1'||['operationID','vaultKind','ownerID','vaultID','baseRevision','revision','ciphertextHash','envelopeHash'].some(key=>outcome[key]!==intent[key]))fail('deployment_fence_mismatch');
    }else if(outcome.kind!==intent.kind||outcome.operationID!==intent.operationID||!same(outcome.vaults,intent.vaults))fail('deployment_fence_mismatch');
    // Cache retains only the exact authenticated intent, allowing the same
    // confirmation to retry its durability barriers after a failed append.
    await this.fence.append({version:2,type:intent.type==='V1_PENDING_INTENT'?'V1_CONFIRMED_COMMIT':'CONFIRMED_COMMIT',intentID,intentDigest:intent.intentDigest});
    this.#intents.delete(intentID);
    return {status:'confirmed',intentID};
  }
  async proveAbort({intentID,proof}){
    const provenance=proof&&typeof proof==='object'?abortProofs.get(proof):null;
    if(!provenance||provenance.coordinator!==this||provenance.intentID!==intentID)fail('invalid_deployment_abort_proof');
    const intent=await this.#pending(intentID);
    if(intent.legacy||intent.intentDigest!==provenance.intentDigest)fail('invalid_deployment_abort_proof');
    await this.fence.append({version:2,type:intent.type==='V1_PENDING_INTENT'?'V1_PROVEN_ABORT':'PROVEN_ABORT',intentID,intentDigest:intent.intentDigest});
    this.#intents.delete(intentID);
    abortProofs.delete(proof);return {status:'aborted',intentID};
  }
  async reconcile({intentID,readCommittedOutcome}){
    if(this.#intents.has(intentID)){
      try{return await this.confirmCommit({intentID,readCommittedOutcome});}
      catch(error){if(error.message==='deployment_fence_pending')return {status:'pending',intentID};throw error;}
    }
    const state=await this.fence.snapshot(),intent=[...state.pending,...(state.v1Pending??[])].find(item=>item.intentID===intentID);
    if(!intent){
      const outcome=[...state.outcomes,...(state.v1Outcomes??[])].find(item=>item.intentID===intentID);
      if(!outcome)fail('deployment_fence_intent_not_found');
      return {status:['CONFIRMED_COMMIT','V1_CONFIRMED_COMMIT'].includes(outcome.type)?'confirmed':'aborted',intentID};
    }
    this.#intents.set(intentID,structuredClone(intent));
    try{return await this.confirmCommit({intentID,readCommittedOutcome});}
    catch(error){if(error.message==='deployment_fence_pending')return {status:'pending',intentID};throw error;}
  }
}

// The abort capability never crosses the transaction adapter. A caller's JSON,
// a new process, or ROLLBACK after any COMMIT dispatch cannot manufacture it.
export function createPublicationFenceTransaction({query,fence,coordinator:providedCoordinator,readCommittedOutcome}){
  let coordinator,intent,commitDispatched=false,rolledBack=false,abortProven=false;
  return {
    get commitDispatched(){return commitDispatched;},
    get intentID(){return intent?.intentID??null;},
    async beforeCommit(fields){
      if(intent||commitDispatched||rolledBack)fail('deployment_fence_transaction_state');
      coordinator=providedCoordinator??new PublicationFenceCoordinator({fence});
      intent=await coordinator.beforeCommit(fields);return structuredClone(intent);
    },
    async commit(){if(commitDispatched||rolledBack)fail('deployment_fence_transaction_state');commitDispatched=true;return query('COMMIT');},
    async confirm(){
      if(!intent)return;
      return coordinator.confirmCommit({intentID:intent.intentID,
        readCommittedOutcome:readCommittedOutcome??(pending=>pending.type==='V1_PENDING_INTENT'
          ?readCommittedV1Outcome({query,intent:pending}):readCommittedPublicationOutcome({query,intent:pending}))});
    },
    async rollback(){
      await query('ROLLBACK');
      rolledBack=true;
      if(!intent||commitDispatched||abortProven)return;
      const proof={};
      abortProofs.set(proof,{coordinator,intentID:intent.intentID,intentDigest:fenceIntentDigest(intent)});
      const result=await coordinator.proveAbort({intentID:intent.intentID,proof});abortProven=true;return result;
    },
  };
}

// Positive evidence only: a missing historical revision is unresolved, never
// proof that a transaction aborted. The ciphertext itself is never journaled.
export async function readCommittedV1Outcome({query,intent}){
  const personal=intent.vaultKind==='PERSONAL';
  if(!personal&&intent.vaultKind!=='TEAM')fail('deployment_fence_mismatch');
  const table=personal?'personal_vaults':'shared_vaults';
  const history=personal?'vault_revisions':'shared_vault_revisions';
  const owner=personal?'user_id':'team_id';
  const envelope=alias=>`jsonb_build_object('envelopeVersion',${alias}.envelope_version,'wrappedKey',${personal?`${alias}.wrapped_key`:'NULL'},'ciphertext',${alias}.ciphertext,'nonce',${alias}.nonce,'authTag',${alias}.auth_tag,'contentHash',${alias}.content_hash,'keyGeneration',${personal?'NULL':`${alias}.key_generation::text`},'wrappers',${personal?'NULL':v1TeamWrappersSQL})`;
  const result=await query(`SELECT v.id AS vault_id,v.${owner} AS owner_id,r.revision,r.ciphertext,
      v.revision AS current_revision,v.ciphertext AS current_ciphertext,${envelope('r')} AS envelope,${envelope('v')} AS current_envelope
    FROM public.${table} v JOIN public.${history} r ON r.vault_id=v.id
    WHERE v.id=$1 AND v.${owner}=$2 AND r.revision=$3`,[intent.vaultID,intent.ownerID,intent.revision]);
  if(!Array.isArray(result?.rows))fail('deployment_fence_mismatch');
  if(!result.rows.length)return null;
  if(result.rows.length!==1)fail('deployment_fence_mismatch');
  const parseRevision=value=>{
    if(typeof value==='string'&&/^(0|[1-9][0-9]*)$/u.test(value))value=Number(value);
    return Number.isSafeInteger(value)&&value>=0?value:null;
  };
  const row=result.rows[0],revision=parseRevision(row.revision),current=parseRevision(row.current_revision);
  let historyEnvelope,currentEnvelope;
  try{historyEnvelope=v1EnvelopeHash(row.envelope);currentEnvelope=v1EnvelopeHash(row.current_envelope);}catch{fail('deployment_fence_mismatch');}
  if(row.vault_id!==intent.vaultID||row.owner_id!==intent.ownerID||!Number.isSafeInteger(revision)||revision!==intent.revision
    ||!Number.isSafeInteger(current)||current!==revision||v1CiphertextHash(row.ciphertext)!==intent.ciphertextHash
    ||historyEnvelope!==intent.envelopeHash
    ||(current===revision&&(v1CiphertextHash(row.current_ciphertext)!==intent.ciphertextHash||currentEnvelope!==intent.envelopeHash)))fail('deployment_fence_mismatch');
  return {kind:'V1',operationID:intent.operationID,vaultKind:intent.vaultKind,ownerID:intent.ownerID,vaultID:intent.vaultID,
    baseRevision:intent.baseRevision,revision:intent.revision,ciphertextHash:intent.ciphertextHash,envelopeHash:intent.envelopeHash};
}

async function readGeneration(query,vault){
  const generationID=vault.generationID??vault.attemptID;
  const row=(await query(`SELECT a.* FROM vault_migration_attempts a
    WHERE a.id=$1 AND a.team_id=$2 AND a.vault_id=$3`,[generationID,vault.teamID,vault.vaultID])).rows[0];
  if(!row||row.state!=='V2_ACTIVE')return null;
  if(row.manifest_hash!==vault.manifestHash||await migrationHash(row.manifest)!==vault.manifestHash)fail('deployment_fence_mismatch');
  const payload=row.manifest?.payload;
  if(payload?.scope?.teamID!==vault.teamID||payload.scope.vaultID!==vault.vaultID||payload.scope.attemptID!==generationID)fail('deployment_fence_mismatch');
  const rootPublicKey=row.snapshot?.actorRootPublicKey;
  await verifyMigrationManifest({manifest:row.manifest,rootPublicKey,expected:{scope:row.scope,policy:row.policy,resources:row.resources,
    parts:payload.parts,...(payload.reader?{reader:payload.reader}:{})}});
  if(vault.generationID||payload.reader){
    const projection=(await query('SELECT projection,header_hash FROM vault_publication_projections WHERE attempt_id=$1 AND team_id=$2 AND vault_id=$3',[generationID,vault.teamID,vault.vaultID])).rows[0];
    if(!projection)fail('deployment_fence_mismatch');
    const header=projection.projection?.header;
    const headerHash=await verifyReaderHeader({header,rootPublicKey,teamID:vault.teamID,vaultID:vault.vaultID});
    if(headerHash!==projection.header_hash||header.payload.generationID!==generationID
      ||await publicationHash('projection',projection.projection)!==payload.reader?.projectionHash
      ||(vault.generationID&&(headerHash!==vault.headerHash||header.payload.sequence!==vault.sequence)))fail('deployment_fence_mismatch');
  }
  return row;
}

// Operator-only positive evidence reader. It never infers abort from absence and
// reads immutable generation rows, so a legitimate later successor is harmless.
export async function readCommittedPublicationOutcome({query,intent}){
  const {kind,operationID,vaults}=intent;
  let receipt=null;
  if(kind==='PUBLICATION'){
    const op=(await query('SELECT *,to_jsonb(committed_at) AS committed_time FROM team_publication_operations WHERE id=$1 AND team_id=$2',[operationID,vaults[0].teamID])).rows[0];
    if(!op||op.state!=='COMMITTED')return null;
    receipt=(await query('SELECT body FROM team_publication_receipts WHERE operation_id=$1 AND team_id=$2',[operationID,vaults[0].teamID])).rows[0]?.body;
    if(!receipt)return null;
    if(receipt.operationID!==operationID||receipt.teamID!==op.team_id||receipt.requestHash!==op.request_hash
      ||receipt.actorAccountID!==op.actor_user_id||receipt.actorDeviceID!==op.actor_device_id||receipt.committedAt!==op.committed_time
      ||!Array.isArray(receipt.vaults)||receipt.vaults.length!==vaults.length)fail('deployment_fence_mismatch');
    const linked=(await query('SELECT vault_id,attempt_id,sequence FROM team_publication_generations WHERE operation_id=$1 AND team_id=$2 ORDER BY vault_id',[operationID,op.team_id])).rows;
    if(linked.length!==vaults.length)fail('deployment_fence_mismatch');
    for(const vault of vaults){
      const expected={vaultID:vault.vaultID,generationID:vault.generationID,sequence:vault.sequence,headerHash:vault.headerHash};
      if(receipt.vaults.filter(v=>same(v,expected)).length!==1||!linked.some(v=>v.vault_id===vault.vaultID&&v.attempt_id===vault.generationID&&Number(v.sequence)===vault.sequence))fail('deployment_fence_mismatch');
    }
  }else if(kind!=='MIGRATION'||vaults.length!==1||operationID!==(vaults[0].generationID??vaults[0].attemptID))fail('deployment_fence_mismatch');
  for(const vault of vaults)if(!await readGeneration(query,vault))return null;
  return {kind,operationID,vaults:structuredClone(vaults),receipt};
}
