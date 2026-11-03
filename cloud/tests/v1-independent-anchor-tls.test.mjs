import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {rootCertificates} from 'node:tls';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import pg from 'pg';
import {loadFenceAnchorConfig} from '../src/fence-anchor-config.mjs';
import {createConfiguredMigrationFence} from '../src/configured-migration-fence.mjs';
import {fenceHistoryHead} from '../src/fence-history-head.mjs';
const url=process.env.SR_TEST_ANCHOR_TLS_URL,certPath=process.env.SR_TEST_ANCHOR_TLS_CA;

test('configured anchor uses certificate-verified TLS and rejects a different CA',{skip:!url||!certPath},async()=>{
 const admin=new pg.Pool({connectionString:url,ssl:{ca:await readFile(certPath,'utf8'),rejectUnauthorized:true}});
 const db='sr_anchor_tls_'+randomUUID().replaceAll('-','');await admin.query(`CREATE DATABASE ${db}`);
 const dbURL=new URL(url);dbURL.pathname='/'+db;const target=dbURL.toString();
 const setup=new pg.Pool({connectionString:target,ssl:{ca:await readFile(certPath,'utf8'),rejectUnauthorized:true}});
 const dir=await mkdtemp(join(tmpdir(),'sr-anchor-tls-')),path=join(dir,'journal');await writeFile(path,'');
 const id=randomUUID();
 try{
  await setup.query(await readFile(new URL('../scripts/independent-fence-anchor.sql',import.meta.url),'utf8'));
  await setup.query('INSERT INTO selective_remote_anchor.heads(deployment_id,position,digest) VALUES ($1,0,$2)',[id,fenceHistoryHead([]).digest]);
  const values={PUBLICATION_FENCE_ANCHOR_URL:target,PUBLICATION_FENCE_ANCHOR_ID:id,
   PUBLICATION_FENCE_ANCHOR_CA_BASE64:(await readFile(certPath)).toString('base64')};
  const anchor=loadFenceAnchorConfig(values,'postgresql://runtime:synthetic@separate-primary.invalid/app');
  const configured=createConfiguredMigrationFence({fencePath:path,anchor});
  try{
   assert.equal((await configured.fence.anchor.read()).position,0);
   const ssl=await configured.fence.anchor.queryable.query('SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()');
   assert.equal(ssl.rows[0].ssl,true);
   const id2='11111111-1111-4111-8111-111111111111';
   await configured.fence.intent({teamID:id2,vaultID:id2,attemptID:id2,manifestHash:'a'.repeat(64),schemaFloor:19});
   assert.equal((await configured.fence.anchor.read()).position,1);
  }finally{await configured.close();}
  const wrong=loadFenceAnchorConfig({...values,PUBLICATION_FENCE_ANCHOR_CA_BASE64:Buffer.from(rootCertificates[0]).toString('base64')},'postgresql://runtime:synthetic@separate-primary.invalid/app');
  const rejected=createConfiguredMigrationFence({fencePath:path,anchor:wrong});
  try{await assert.rejects(()=>rejected.fence.snapshot());}finally{await rejected.close();}
 }finally{await setup.end();await admin.query(`DROP DATABASE ${db}`);await admin.end();await rm(dir,{recursive:true,force:true});}
});
