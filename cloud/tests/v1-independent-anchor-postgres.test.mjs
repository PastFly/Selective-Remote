import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
import pg from 'pg';
import {MigrationFence} from '../src/migration-fence.mjs';

const url=process.env.SR_TEST_ANCHOR_DATABASE_URL;
const genesis=createHash('sha256').update('selective-remote/fence-history/v1\0').digest('hex');
const record=(id)=>({teamID:id,vaultID:id,attemptID:id,manifestHash:'a'.repeat(64),schemaFloor:19});

test('independent durable high-water rejects coordinated old journal rollback and supports exact retry', {skip:!url}, async()=>{
 const pool=new pg.Pool({connectionString:url});
 const table='sr_anchor_'+randomUUID().replaceAll('-','');
 const dir=await mkdtemp(join(tmpdir(),'sr-anchor-test-')); const path=join(dir,'journal');
 await writeFile(path,'');
 await pool.query(`CREATE TABLE ${table} (singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), position bigint NOT NULL, digest text NOT NULL)`);
 await pool.query(`INSERT INTO ${table}(position,digest) VALUES (0,$1)`,[genesis]);
 const anchor={
  async read(){const r=await pool.query(`SELECT position,digest FROM ${table} WHERE singleton`);return {position:Number(r.rows[0].position),digest:r.rows[0].digest};},
  async advance(previous,next){const r=await pool.query(`UPDATE ${table} SET position=$3,digest=$4 WHERE singleton AND position=$1 AND digest=$2 RETURNING position`,[previous.position,previous.digest,next.position,next.digest]); if(r.rowCount!==1)throw Error('anchor_conflict');},
 };
 try {
  const fence=new MigrationFence(path,{anchor});
  await fence.intent(record('11111111-1111-4111-8111-111111111111'));
  const old=await readFile(path);
  await fence.intent(record('22222222-2222-4222-8222-222222222222'));
  const current=await readFile(path);
  assert.equal((await anchor.read()).position,2);
  await fence.intent(record('22222222-2222-4222-8222-222222222222'));
  assert.equal((await anchor.read()).position,2,'exact retry cannot advance twice');
  await writeFile(path,old);
  await assert.rejects(()=>fence.snapshot(),/deployment_anchor_mismatch/);
  await assert.rejects(()=>fence.intent(record('33333333-3333-4333-8333-333333333333')),/deployment_anchor_mismatch/);
  await writeFile(path,current);
  assert.equal((await fence.snapshot()).pending.length,2);
 } finally {await pool.query(`DROP TABLE ${table}`);await pool.end();await rm(dir,{recursive:true,force:true});}
});

test('anchor response loss is resolved by exact replay and never accepts an unrelated append', {skip:!url}, async()=>{
 const pool=new pg.Pool({connectionString:url});const table='sr_anchor_'+randomUUID().replaceAll('-','');
 const dir=await mkdtemp(join(tmpdir(),'sr-anchor-retry-'));const path=join(dir,'journal');await writeFile(path,'');
 await pool.query(`CREATE TABLE ${table} (singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), position bigint NOT NULL, digest text NOT NULL)`);
 await pool.query(`INSERT INTO ${table}(position,digest) VALUES (0,$1)`,[genesis]);
 let loseReply=true;
 const anchor={async read(){const r=await pool.query(`SELECT position,digest FROM ${table}`);return {position:Number(r.rows[0].position),digest:r.rows[0].digest};},
  async advance(old,next){const r=await pool.query(`UPDATE ${table} SET position=$3,digest=$4 WHERE position=$1 AND digest=$2 RETURNING position`,[old.position,old.digest,next.position,next.digest]);
   if(r.rowCount!==1)throw Error('anchor_conflict');if(loseReply){loseReply=false;throw Error('anchor_reply_lost');}},};
 try{
  const fence=new MigrationFence(path,{anchor}),first=record('11111111-1111-4111-8111-111111111111');
  await assert.rejects(()=>fence.intent(first),/anchor_reply_lost/);
  await assert.rejects(()=>fence.snapshot(),/deployment_fence_locked/);
  await assert.rejects(()=>fence.intent(record('22222222-2222-4222-8222-222222222222')),/deployment_fence_locked/);
  await fence.intent(first);
  assert.equal((await anchor.read()).position,1);
  assert.equal((await fence.snapshot()).pending.length,1);
 }finally{await pool.query(`DROP TABLE ${table}`);await pool.end();await rm(dir,{recursive:true,force:true});}
});

test('independent PostgreSQL anchor is durable, monotonic and prevents its runtime role from resetting history', {skip:!url}, async()=>{
 const {PostgresFenceAnchor}=await import('../src/postgres-fence-anchor.mjs');
 const admin=new pg.Pool({connectionString:url});const db='sr_anchor_test_'+randomUUID().replaceAll('-','');
 await admin.query(`CREATE DATABASE ${db}`);
 const dbURL=new URL(url);dbURL.pathname='/'+db;
 const pool=new pg.Pool({connectionString:dbURL.toString()});const id=randomUUID(),integratedID=randomUUID();
 const dir=await mkdtemp(join(tmpdir(),'sr-anchor-integrated-'));const path=join(dir,'journal');await writeFile(path,'');
 const role='sr_anchor_client_'+randomUUID().replaceAll('-','');
 const ddl=await readFile(new URL('../scripts/independent-fence-anchor.sql',import.meta.url),'utf8');
 try {
  await pool.query(ddl);
  await pool.query(`CREATE ROLE ${role} NOLOGIN`);
  await pool.query(`GRANT USAGE ON SCHEMA selective_remote_anchor TO ${role}`);
  await pool.query(`GRANT EXECUTE ON FUNCTION selective_remote_anchor.read_head(uuid), selective_remote_anchor.advance_head(uuid,bigint,text,bigint,text) TO ${role}`);
  await pool.query('INSERT INTO selective_remote_anchor.heads (deployment_id,position,digest) VALUES ($1,0,$2)',[id,genesis]);
  await pool.query('INSERT INTO selective_remote_anchor.heads (deployment_id,position,digest) VALUES ($1,0,$2)',[integratedID,genesis]);
  const client=await pool.connect();
  try{
   await client.query(`SET ROLE ${role}`);
   const anchor=new PostgresFenceAnchor(client,id);
   const zero=await anchor.read();assert.deepEqual(zero,{position:0,digest:genesis});
   const one={position:1,digest:'b'.repeat(64)};
   await anchor.advance(zero,one);await anchor.advance(zero,one);
   assert.deepEqual(await anchor.read(),one);
   await assert.rejects(()=>anchor.advance(one,zero),/invalid_deployment_anchor/);
   await assert.rejects(()=>client.query('UPDATE selective_remote_anchor.heads SET position=0'));
   await assert.rejects(()=>client.query('DELETE FROM selective_remote_anchor.heads'));
   await assert.rejects(()=>client.query('SELECT selective_remote_anchor.advance_head($1,NULL,$2,0,$3)',[id,one.digest,genesis]),/invalid_deployment_anchor/);
   assert.deepEqual(await anchor.read(),one);
   await assert.rejects(()=>new PostgresFenceAnchor(client,randomUUID()).read(),/deployment_anchor_unavailable/);
   const integrated=new PostgresFenceAnchor(client,integratedID),fence=new MigrationFence(path,{anchor:integrated});
   await fence.intent(record('11111111-1111-4111-8111-111111111111'));
   const old=await readFile(path);
   await fence.intent(record('22222222-2222-4222-8222-222222222222'));
   await writeFile(path,old);
   await assert.rejects(()=>fence.snapshot(),/deployment_anchor_mismatch/);
  } finally {await client.query('RESET ROLE');client.release();}
 } finally {
  await pool.query('DROP SCHEMA IF EXISTS selective_remote_anchor CASCADE');
  await pool.query(`DROP ROLE IF EXISTS ${role}`);
  await pool.end();
  await admin.query(`DROP DATABASE ${db}`);await admin.end();
  await rm(dir,{recursive:true,force:true});
 }
});

test('anchor refuses a read served by a standby even when its row looks valid', async()=>{
 const {PostgresFenceAnchor}=await import('../src/postgres-fence-anchor.mjs');
 const anchor=new PostgresFenceAnchor({query:async()=>({rows:[{position:'0',digest:genesis,is_replica:true}]})},'11111111-1111-4111-8111-111111111111');
 await assert.rejects(()=>anchor.read(),/deployment_anchor_unavailable/);
});
