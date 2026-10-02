// Dormant internal delivery adapter. Runtime/UI delivery is not automatically
// enabled. The configured sink must durably deduplicate idempotencyKey before
// acknowledging; a lost acknowledgement necessarily repeats the same event.
import {randomUUID} from 'node:crypto';
import {isUUID} from './security.mjs';
export class WholePublicationOutbox {
  constructor(pool,{environment,enabled,allowedVaultIDs=[],deliver}={}){
    this.pool=pool;this.allowed=allowedVaultIDs.filter(isUUID);this.deliver=deliver;this.owner=randomUUID();
    this.enabled=enabled===true&&environment==='staging'&&this.allowed.length>0&&typeof deliver==='function';
  }
  async dispatchOne(){
    if(!this.enabled)return false;
    const row=(await this.pool.query(`WITH pending AS (
      SELECT b.id FROM team_publication_outbox b JOIN team_publication_operations o ON o.id=b.operation_id AND o.team_id=b.team_id
      WHERE o.state='COMMITTED' AND b.vault_id=ANY($1::uuid[]) AND b.delivered_at IS NULL AND b.available_at<=clock_timestamp()
        AND (b.claimed_at IS NULL OR b.claimed_at<clock_timestamp()-interval '5 minutes')
      ORDER BY b.available_at,b.id LIMIT 1 FOR UPDATE OF b SKIP LOCKED)
      UPDATE team_publication_outbox b SET claimed_at=clock_timestamp(),claim_owner=$2
      FROM pending WHERE b.id=pending.id RETURNING b.*`,[this.allowed,this.owner])).rows[0];
    if(!row)return false;
    const event={kind:'effective_access_changed',idempotencyKey:`whole-publication:${row.operation_id}:${row.id}`,
      operationID:row.operation_id,teamID:row.team_id,vaultID:row.vault_id,resourceID:row.resource_id,
      accountID:row.user_id,membershipID:row.membership_id,membershipEpoch:Number(row.membership_epoch),
      beforeMask:row.before_mask,afterMask:row.after_mask};
    try{
      await this.deliver(Object.freeze(event));
      const result=await this.pool.query('UPDATE team_publication_outbox SET delivered_at=clock_timestamp(),claimed_at=NULL,claim_owner=NULL WHERE id=$1 AND claim_owner=$2 AND delivered_at IS NULL',[row.id,this.owner]);
      return result.rowCount===1;
    }catch{
      await this.pool.query("UPDATE team_publication_outbox SET claimed_at=NULL,claim_owner=NULL,available_at=clock_timestamp()+interval '30 seconds' WHERE id=$1 AND claim_owner=$2 AND delivered_at IS NULL",[row.id,this.owner]);
      return false;
    }
  }
}
