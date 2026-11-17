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
  const result=await this.queryable.query(`SELECT h."position",h.digest,pg_catalog.pg_is_in_recovery() AS is_replica,
    (pg_catalog.current_setting('fsync')='on' AND pg_catalog.current_setting('full_page_writes')='on') AS durable_settings,
    NOT (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls
      OR pg_catalog.pg_has_role(r.oid,n.nspowner,'MEMBER') OR pg_catalog.pg_has_role(r.oid,c.relowner,'MEMBER')
      OR pg_catalog.pg_has_role(r.oid,reader.proowner,'MEMBER') OR pg_catalog.pg_has_role(r.oid,writer.proowner,'MEMBER')
      OR pg_catalog.pg_has_role(r.oid,d.datdba,'MEMBER') OR pg_catalog.has_database_privilege(r.oid,d.oid,'CREATE')
      OR EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m WHERE m.member=r.oid)
      OR pg_catalog.has_schema_privilege(r.oid,n.oid,'CREATE')
      OR pg_catalog.has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')) AS constrained_role
    FROM selective_remote_anchor.read_head($1::uuid) h
    JOIN pg_catalog.pg_roles r ON r.rolname=current_user
    JOIN pg_catalog.pg_database d ON d.datname=pg_catalog.current_database()
    JOIN pg_catalog.pg_namespace n ON n.nspname='selective_remote_anchor'
    JOIN pg_catalog.pg_class c ON c.relnamespace=n.oid AND c.relname='heads' AND c.relkind='r'
    JOIN pg_catalog.pg_proc reader ON reader.oid='selective_remote_anchor.read_head(uuid)'::pg_catalog.regprocedure
    JOIN pg_catalog.pg_proc writer ON writer.oid='selective_remote_anchor.advance_head(uuid,bigint,text,text)'::pg_catalog.regprocedure`,[this.deploymentID]);
  if(!Array.isArray(result?.rows)||result.rows.length!==1)throw Error('deployment_anchor_unavailable');
  const row=result.rows[0];
  if(row.is_replica!==false||row.constrained_role!==true||row.durable_settings!==true)throw Error('deployment_anchor_unavailable');
  if(typeof row.position!=='string'||!/^(0|[1-9][0-9]*)$/u.test(row.position))throw Error('invalid_deployment_anchor');
  const head={position:Number(row.position),digest:row.digest};
  if(!sameFenceHistoryHead(head,head))throw Error('invalid_deployment_anchor');
  return head;
 }
 async advance(before,after,event){
  if(!sameFenceHistoryHead(before,before)||!sameFenceHistoryHead(after,after)
   ||!sameFenceHistoryHead(nextFenceHistoryHead(before,event),after))throw Error('invalid_deployment_anchor');
  const current=await this.read();
  if(!sameFenceHistoryHead(current,before)&&!sameFenceHistoryHead(current,after))throw Error('deployment_anchor_conflict');
  const encoded=JSON.stringify(validateFenceEvent(event))+'\n';
  const result=await this.queryable.query('SELECT selective_remote_anchor.advance_head($1::uuid,$2::bigint,$3::text,$4::text) AS advanced',
   [this.deploymentID,before.position,before.digest,encoded]);
  if(result?.rows?.length!==1||result.rows[0].advanced!==true)throw Error('deployment_anchor_unavailable');
 }
}
