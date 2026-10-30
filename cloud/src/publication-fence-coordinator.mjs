import {randomUUID} from 'node:crypto';
import {canonicalMigrationJSON,migrationHash,verifyMigrationManifest} from './migration-policy.mjs';
import {publicationHash,verifyReaderHeader} from '../public/vault-publication-v1.js';
import {validateFenceEvent,fenceIntentDigest} from './migration-fence-journal.mjs';

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
    const intent=validateFenceEvent({...structuredClone(fields),version:2,type:'PENDING_INTENT',intentID:randomUUID()});
    await this.fence.append(intent);
    this.#intents.set(intent.intentID,{...structuredClone(intent),intentDigest:fenceIntentDigest(intent)});
    return structuredClone(intent);
  }
  async #pending(intentID){
    if(this.#intents.has(intentID))return this.#intents.get(intentID);
    const intent=(await this.fence.snapshot()).pending.find(item=>item.intentID===intentID);
    if(!intent)fail('deployment_fence_intent_not_found');
    this.#intents.set(intentID,structuredClone(intent));return intent;
  }
  async confirmCommit({intentID,readCommittedOutcome}){
    if(typeof readCommittedOutcome!=='function')fail('deployment_fence_readback_required');
    const intent=await this.#pending(intentID),outcome=await readCommittedOutcome(structuredClone(intent));
    if(!outcome)fail('deployment_fence_pending');
    if(outcome.kind!==intent.kind||outcome.operationID!==intent.operationID||!same(outcome.vaults,intent.vaults))fail('deployment_fence_mismatch');
    // Cache retains only the exact authenticated intent, allowing the same
    // confirmation to retry its durability barriers after a failed append.
    await this.fence.append({version:2,type:'CONFIRMED_COMMIT',intentID,intentDigest:intent.intentDigest});
    this.#intents.delete(intentID);
    return {status:'confirmed',intentID};
  }
  async proveAbort({intentID,proof}){
    const provenance=proof&&typeof proof==='object'?abortProofs.get(proof):null;
    if(!provenance||provenance.coordinator!==this||provenance.intentID!==intentID)fail('invalid_deployment_abort_proof');
    const intent=await this.#pending(intentID);
    if(intent.legacy||intent.intentDigest!==provenance.intentDigest)fail('invalid_deployment_abort_proof');
    await this.fence.append({version:2,type:'PROVEN_ABORT',intentID,intentDigest:intent.intentDigest});
    this.#intents.delete(intentID);
    abortProofs.delete(proof);return {status:'aborted',intentID};
  }
  async reconcile({intentID,readCommittedOutcome}){
    if(this.#intents.has(intentID)){
      try{return await this.confirmCommit({intentID,readCommittedOutcome});}
      catch(error){if(error.message==='deployment_fence_pending')return {status:'pending',intentID};throw error;}
    }
    const state=await this.fence.snapshot(),intent=state.pending.find(item=>item.intentID===intentID);
    if(!intent){
      const outcome=state.outcomes.find(item=>item.intentID===intentID);
      if(!outcome)fail('deployment_fence_intent_not_found');
      return {status:outcome.type==='CONFIRMED_COMMIT'?'confirmed':'aborted',intentID};
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
        readCommittedOutcome:readCommittedOutcome??(pending=>readCommittedPublicationOutcome({query,intent:pending}))});
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
