import test from 'node:test';import assert from 'node:assert/strict';import {EventEmitter} from 'node:events';
import {trackTestPoolClosure,verifyIdlePoolReconnect} from './postgres-pool-teardown.mjs';
import {isolatedPublicationDatabase} from './publication-runtime-fixture.mjs';
import {PostgresStore} from '../src/postgres-store.mjs';
test('pool teardown waits for every actual client end when pool.end resolves early',async()=>{
 const pool=new EventEmitter();pool.end=async()=>{};trackTestPoolClosure(pool);
 const first=new EventEmitter(),second=new EventEmitter();pool.emit('connect',first);pool.emit('connect',second);
 let completed=false;const closing=pool.end().then(()=>{completed=true;});await new Promise(resolve=>setImmediate(resolve));assert.equal(completed,false);
 first.emit('end');await new Promise(resolve=>setImmediate(resolve));assert.equal(completed,false);
 second.emit('end');await closing;assert.equal(completed,true);
});

test('the Cloud pool reconnects after PostgreSQL closes its idle connection',
 {skip:!process.env.TEST_DATABASE_URL},async context=>{
  const db=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  const store=new PostgresStore(db.databaseURL);
  trackTestPoolClosure(store.pool);
  const log=context.mock.method(console,'error',()=>{});
  try{
   await verifyIdlePoolReconnect(store.pool,db.pool);
   await store.ready();
   assert.deepEqual(log.mock.calls.map(call=>call.arguments),[[
    JSON.stringify({level:'error',message:'Idle Cloud database connection lost'}),
   ]]);
  }finally{
   try{await store.close();}finally{await db.cleanup();}
  }
});
