// Isolated integration-only anchor. The supplied TLS PostgreSQL must be a
// disposable test service; this is not deployment/failure-domain evidence.
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import pg from 'pg';
import {MigrationFence} from '../src/migration-fence.mjs';
import {PostgresFenceAnchor} from '../src/postgres-fence-anchor.mjs';
import {fenceHistoryHead} from '../src/fence-history-head.mjs';

export const syntheticHttpAnchorAvailable=Boolean(process.env.SR_TEST_ANCHOR_TLS_URL&&process.env.SR_TEST_ANCHOR_TLS_CA);
export async function syntheticHttpAnchor(path){
 if(!syntheticHttpAnchorAvailable)throw Error('synthetic_tls_anchor_required');
 const base=new URL(process.env.SR_TEST_ANCHOR_TLS_URL);
 if(!['localhost','127.0.0.1','[::1]'].includes(base.hostname))throw Error('synthetic_tls_anchor_loopback_required');
 const ca=await readFile(process.env.SR_TEST_ANCHOR_TLS_CA,'utf8');
 const admin=new pg.Pool({connectionString:base.toString(),ssl:{ca,rejectUnauthorized:true},max:1});
 const name='sr_anchor_http_'+randomUUID().replaceAll('-','')+'_test',role='sr_anchor_role_'+randomUUID().replaceAll('-',''),password=randomUUID().replaceAll('-','');
 let pool,setup,created=false,roleCreated=false;
 const cleanup=async()=>{try{await pool?.end();await setup?.end();if(created)await admin.query(`DROP DATABASE "${name}"`);if(roleCreated)await admin.query(`DROP ROLE "${role}"`);}finally{await admin.end();}};
 try{
  await admin.query(`CREATE DATABASE "${name}"`);created=true;base.pathname='/'+name;
  setup=new pg.Pool({connectionString:base.toString(),ssl:{ca,rejectUnauthorized:true},max:1});
  await setup.query(await readFile(new URL('../scripts/independent-fence-anchor.sql',import.meta.url),'utf8'));
  const id=randomUUID(),existing=await new MigrationFence(path).readRecords(),head=fenceHistoryHead(existing);
  await setup.query('INSERT INTO selective_remote_anchor.heads(deployment_id,position,digest) VALUES ($1,$2,$3)',[id,head.position,head.digest]);
  await admin.query(`CREATE ROLE "${role}" LOGIN PASSWORD '${password}'`);roleCreated=true;
  await setup.query(`GRANT USAGE ON SCHEMA selective_remote_anchor TO "${role}"`);
  await setup.query(`GRANT EXECUTE ON FUNCTION selective_remote_anchor.read_head(uuid),selective_remote_anchor.advance_head(uuid,bigint,text,text) TO "${role}"`);
  await setup.end();setup=null;
  base.username=role;base.password=password;
  pool=new pg.Pool({connectionString:base.toString(),ssl:{ca,rejectUnauthorized:true},max:2});
  const fence=new MigrationFence(path,{anchor:new PostgresFenceAnchor(pool,id)});
  return {fence,env:{PUBLICATION_FENCE_ANCHOR_URL:base.toString(),PUBLICATION_FENCE_ANCHOR_ID:id,PUBLICATION_FENCE_ANCHOR_CA_BASE64:Buffer.from(ca).toString('base64')},cleanup};
 }catch(error){await cleanup();throw error;}
}
