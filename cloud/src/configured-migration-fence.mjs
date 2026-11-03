import pg from 'pg';
import {MigrationFence} from './migration-fence.mjs';
import {PostgresFenceAnchor} from './postgres-fence-anchor.mjs';

export function createConfiguredMigrationFence({fencePath,anchor},{Pool=pg.Pool}={}){
 if(!fencePath){if(anchor)throw Error('invalid_deployment_anchor_configuration');return {fence:null,close:async()=>{}};}
 if(!anchor)return {fence:new MigrationFence(fencePath),close:async()=>{}};
 const pool=new Pool({connectionString:anchor.connectionString,ssl:{ca:anchor.ca,rejectUnauthorized:true},max:2,
  connectionTimeoutMillis:5000,query_timeout:10000});
 return {fence:new MigrationFence(fencePath,{anchor:new PostgresFenceAnchor(pool,anchor.deploymentID)}),close:()=>pool.end()};
}
