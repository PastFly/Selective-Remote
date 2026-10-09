import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {stagingPartialBootstrapGuard} from './browser/staging-real-lifecycle.mjs';

function fixture(){
 const runID='partial-bootstrap-test',userID=randomUUID(),identity={deviceID:randomUUID()},membershipID=randomUUID();
 const created={teamID:randomUUID(),actorUserID:userID,actorDeviceID:identity.deviceID,vaults:[{vaultID:randomUUID(),name:`TEST-ONLY-CODEX-${runID}-populated`,attemptID:randomUUID()}]};
 const partial={created,membershipID,membershipEpoch:1};
 const values={saved:structuredClone(created),team:{id:created.teamID,name:`TEST-ONLY-CODEX-${runID}-team`,role:'owner',membershipID,membershipEpoch:1},vaults:[{id:created.vaults[0].vaultID,name:created.vaults[0].name}],policy:{automaticDeviceAdmission:true},remote:{revision:0,keyGeneration:1,rotationRequired:false,envelopeVersion:null,ciphertext:null,nonce:null,authTag:null,contentHash:null,wrapper:null},local:null};
 const calls=[],read=name=>{calls.push(name);return values[name];};
 const client={listTeams:async()=>[read('team')],listSharedVaults:async()=>read('vaults'),getTeamDeviceAdmissionPolicy:async()=>read('policy'),getTeamVault:async()=>read('remote')};
 const options={client,team:{createIndexedDBTeamVaultRepository:()=>({load:async()=>read('local')})},identity,userID,runID,partial,storage:async key=>key==='created'?read('saved'):read(key.startsWith('legacy:')?'legacy':'expected')};
 return {options,values,calls};
}
test('partial bootstrap guard accepts only the saved empty V1 object and does no writes',async()=>{
 const f=fixture();assert.deepEqual(await stagingPartialBootstrapGuard(f.options),f.values.saved);
 assert.deepEqual(f.calls,['saved','team','vaults','policy','remote','local','legacy','expected']);
});
test('partial recovery rejects identity scope policy remote and local drift before initialization',async()=>{
 for(const mutate of [f=>f.values.saved.actorDeviceID=randomUUID(),f=>f.values.saved.vaults[0].attemptID=randomUUID(),f=>f.values.saved.vaults.push({...f.values.saved.vaults[0],vaultID:randomUUID()}),f=>f.values.team.role='admin',f=>f.values.team.membershipEpoch++,f=>f.values.team.name='ordinary',f=>f.values.vaults.push({id:randomUUID(),name:'other'}),f=>f.values.vaults[0].name='ordinary',f=>f.values.policy.automaticDeviceAdmission=false,f=>f.values.remote.revision=1,f=>f.values.remote.rotationRequired=true,f=>f.values.remote.wrapper={},f=>f.values.remote.ciphertext='opaque',f=>f.values.local={envelope:'retained'},f=>f.values.legacy={},f=>f.values.expected={},f=>f.options.partial.created.actorUserID=randomUUID()]){
  const f=fixture();mutate(f);await assert.rejects(stagingPartialBootstrapGuard(f.options),/partial_bootstrap_changed/);
 }
});
test('serialized browser guard preserves behavior and does not create acceptance state',async()=>{
 const install=(0,eval)('('+stagingPartialBootstrapGuard.toString()+')');
 await install({installOnly:true});try{const f=fixture();assert.deepEqual(await globalThis.__prcInspectPartialBootstrap(f.options),f.values.saved);}finally{delete globalThis.__prcInspectPartialBootstrap;}
});
