import {nextFenceHistoryHead,sameFenceHistoryHead} from './fence-history-head.mjs';
import {validateFenceEvent} from './migration-fence-journal.mjs';

// The pool must connect to a separately administered durable primary. The
// runtime role receives EXECUTE on these functions, never direct table rights.
export class PostgresFenceAnchor {
 constructor(queryable,deploymentID){
  if(typeof queryable?.query!=='function'||typeof deploymentID!=='string'
    ||!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(deploymentID))
   throw Error('invalid_deployment_anchor');
  this.queryable=queryable;this.deploymentID=deploymentID;
 }
 async read(){
  const result=await this.queryable.query('SELECT "position",digest,pg_catalog.pg_is_in_recovery() AS is_replica FROM selective_remote_anchor.read_head($1::uuid)',[this.deploymentID]);
  if(!Array.isArray(result?.rows)||result.rows.length!==1)throw Error('deployment_anchor_unavailable');
  const row=result.rows[0];
  if(row.is_replica!==false)throw Error('deployment_anchor_unavailable');
  if(typeof row.position!=='string'||!/^(0|[1-9][0-9]*)$/u.test(row.position))throw Error('invalid_deployment_anchor');
  const head={position:Number(row.position),digest:row.digest};
  if(!sameFenceHistoryHead(head,head))throw Error('invalid_deployment_anchor');
  return head;
 }
 async advance(before,after,event){
  if(!sameFenceHistoryHead(before,before)||!sameFenceHistoryHead(after,after)
   ||!sameFenceHistoryHead(nextFenceHistoryHead(before,event),after))throw Error('invalid_deployment_anchor');
  const encoded=JSON.stringify(validateFenceEvent(event))+'\n';
  const result=await this.queryable.query('SELECT selective_remote_anchor.advance_head($1::uuid,$2::bigint,$3::text,$4::text) AS advanced',
   [this.deploymentID,before.position,before.digest,encoded]);
  if(result?.rows?.length!==1||result.rows[0].advanced!==true)throw Error('deployment_anchor_unavailable');
 }
}
