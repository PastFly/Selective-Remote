import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=await readFile(new URL('../src/server.mjs',import.meta.url),'utf8');
// Execute the actual startup function; transport seams cannot bind a socket or
// send mail. Real process/request coverage is in vault-publication-store tests.
const startup=source.slice(source.indexOf('async function start()'),source.indexOf('\nlet outboxPumpRunning'));
function scenario({initiallyBlocked=false,blockDuringSMTP=false}={}){
  const events=[];let blocked=initiallyBlocked;
  const start=vm.runInNewContext(`(${startup})`,{
    checkDeployment:async()=>{events.push('check');if(blocked)throw Error('deployment_fence_pending');},
    config:{allowRegistration:true,port:8080,host:'127.0.0.1'},
    mailer:{verifyConnection:async()=>{events.push('smtp');await Promise.resolve();if(blockDuringSMTP)blocked=true;}},
    server:{listen:()=>events.push('listen')},scheduleOutboxPump:()=>events.push('pump'),
    store:{close:async()=>events.push('close')},process:{exit:()=>{throw Error('exit');}},console:{error(){},log(){}},
  });
  return {start,events};
}
test('initial compatibility denial never binds or schedules outbox',async()=>{
  const s=scenario({initiallyBlocked:true});await assert.rejects(s.start(),/deployment_fence_pending/);
  assert.deepEqual(s.events,['check']);
});
test('fence change during awaited SMTP verification prevents listen and pump',async()=>{
  const s=scenario({blockDuringSMTP:true});await assert.rejects(s.start(),/deployment_fence_pending/);
  assert.deepEqual(s.events,['check','smtp','check']);
});
test('compatible startup verifies again after SMTP and then binds',async()=>{
  const s=scenario();await s.start();assert.deepEqual(s.events,['check','smtp','check','listen','pump']);
});
