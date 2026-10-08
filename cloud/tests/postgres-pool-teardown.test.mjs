import test from 'node:test';import assert from 'node:assert/strict';import {EventEmitter} from 'node:events';
import {trackTestPoolClosure} from './postgres-pool-teardown.mjs';
test('pool teardown waits for every actual client end when pool.end resolves early',async()=>{
 const pool=new EventEmitter();pool.end=async()=>{};trackTestPoolClosure(pool);
 const first=new EventEmitter(),second=new EventEmitter();pool.emit('connect',first);pool.emit('connect',second);
 let completed=false;const closing=pool.end().then(()=>{completed=true;});await new Promise(resolve=>setImmediate(resolve));assert.equal(completed,false);
 first.emit('end');await new Promise(resolve=>setImmediate(resolve));assert.equal(completed,false);
 second.emit('end');await closing;assert.equal(completed,true);
});
