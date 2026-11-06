// Production controller/crypto regression with synthetic in-memory transport and storage.
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {createTeamVaultController,synchronizeTeamVault} from '../public/team-vault-sync.js';
import {generateTeamDeviceIdentity,unwrapTeamVaultKeyForDevice,encryptTeamVaultPayload} from '../public/team-vault-crypto.js';
import * as lifecycle from './browser/staging-real-lifecycle.mjs';
const {stagingV1Records}=lifecycle;
import * as team from '../public/team-vault-sync.js';
import test from 'node:test';
const scope={type:'team',teamID:'11111111-1111-4111-8111-111111111111',vaultID:'22222222-2222-4222-8222-222222222222'};
const membershipID='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
function memoryRepository(initial=null){let value=initial&&structuredClone(initial);return{async load(){return value&&structuredClone(value);},async save(next){value=structuredClone(next);},async remove(){value=null;}};}
function controller(repository,identity){return createTeamVaultController({repository,identity,scope,cryptoValue:webcrypto,now:()=> '2026-10-26T12:00:00.000Z'});}
function oldRunnerPredicate({remote,state,cached,document},kind='populated'){
 return !state.dirty&&remote.revision===state.serverRevision&&document.records.length===(kind==='populated'?4:0)&&!['ciphertext','nonce','authTag','contentHash'].some(k=>remote[k]!==cached.envelope[k]);
}
async function fixture({populated=true}={}){
 const identities=await Promise.all(['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'].map(async deviceID=>({deviceID,...await generateTeamDeviceIdentity(webcrypto)})));
 const keyDevices=identities.map(identity=>({deviceID:identity.deviceID,membershipID,membershipEpoch:1,publicKeyAlgorithm:'p256-ecdh-v1',publicKey:identity.publicKey}));
 let revision=0,envelope=null,wrappers=new Map(),puts=0;
 const client={session:()=>({id:'SYNTHETIC-session'}),async listTeamKeyDevices(request){assert.deepEqual(request,scope);return{scope,devices:keyDevices.map(d=>({...d,hasWrapper:wrappers.has(d.deviceID)}))};},async getTeamVault(request){assert.deepEqual(request,scope);return{scope,id:scope.vaultID,teamID:scope.teamID,name:'TEST-ONLY-CODEX-SYNTHETIC',revision,keyGeneration:1,rotationRequired:false,envelopeVersion:envelope?.envelopeVersion??null,...Object.fromEntries(['ciphertext','nonce','authTag','contentHash'].map(k=>[k,envelope?.[k]??null])),wrapper:structuredClone(wrappers.get(identities[0].deviceID)??null)};},async putTeamVault(request,next){assert.deepEqual(request,scope);assert.equal(next.keyGeneration,1);if(next.baseRevision!==revision)return{conflict:true,revision,keyGeneration:1};if(next.wrappers)wrappers=new Map(next.wrappers.map(w=>[w.deviceID,structuredClone(w)]));envelope=structuredClone(next);delete envelope.wrappers;revision++;puts++;return{conflict:false,revision,keyGeneration:1};}};
 const repository=memoryRepository(),owner=controller(repository,identities[0]);
 const initialized=await synchronizeTeamVault({client,controller:owner,role:'owner'});assert.equal(initialized.status,'initialized');assert.equal(wrappers.size,2);
 const initial={remote:await client.getTeamVault(scope),state:await owner.syncState(),cached:await repository.load(),document:owner.document()};
 assert.equal(oldRunnerPredicate(initial,'empty'),true);
 // Match initialized recovery: unlock an existing clean empty revision-one cache.
 owner.lock();await owner.unlock();
 if(populated)for(const record of stagingV1Records())await owner.upsert(record);
 const beforeUpload=await repository.load();
 const synchronized=await synchronizeTeamVault({client,controller:owner,role:'owner'});
 const remote=await client.getTeamVault(scope),state=await owner.syncState(),cached=await repository.load(),document=owner.document();
 return{client,owner,repository,identity:identities[0],scope,remote,state,cached,document,initial,beforeUpload,synchronized,puts:()=>puts,wrappers:()=>wrappers.size};
}
async function validDifferentRemote(f,mutate){
 const vaultKey=await unwrapTeamVaultKeyForDevice({privateKey:f.identity.privateKey,wrapper:f.remote.wrapper,...scope,keyGeneration:1,deviceID:f.identity.deviceID,cryptoValue:webcrypto});
 const changed=structuredClone(f.document);mutate(changed);
 const encrypted=await encryptTeamVaultPayload({vaultKey,payload:changed,scope,baseRevision:f.remote.revision-1,keyGeneration:1,cryptoValue:webcrypto});
 return{...structuredClone(f.remote),...encrypted};
}

async function verify(f,overrides={}){
 return lifecycle.stagingLegacyRoundtripGuard({team,identity:f.identity,scope,controller:f.owner,cached:f.cached,remote:f.remote,expectedRecordCount:4,...overrides});
}
test('legacy roundtrip authenticates independent ciphertexts with actual controllers and preserves persistent cache',async()=>{
 const f=await fixture(),before=await f.repository.load(),transient=[];
 const observedTeam={...team,createIndexedDBTeamVaultRepository(){throw Error('persistent_access_forbidden');},createTeamVaultController(options){const c=team.createTeamVaultController(options);transient.push(c);return c;}};
 try{
  assert.equal(typeof lifecycle.stagingLegacyRoundtripGuard,'function');
  assert.equal(oldRunnerPredicate(f),false);assert.equal(f.state.dirty,false);assert.equal(f.state.serverRevision,2);
  const legacy=await verify(f,{team:observedTeam});
  assert.deepEqual(legacy,{envelope:{baseRevision:1,keyGeneration:1,envelopeVersion:1,...Object.fromEntries(['ciphertext','nonce','authTag','contentHash'].map(k=>[k,f.remote[k]]))},wrapper:f.remote.wrapper,keyGeneration:1,revision:2});
  assert.notDeepEqual(legacy.envelope,f.cached.envelope);assert.deepEqual(await f.repository.load(),before);assert.deepEqual(f.owner.document(),f.document);assert.equal(f.puts(),2);
  assert.equal(transient.length,2);for(const c of transient)assert.equal(await c.status(),'locked');
 }finally{f.owner.lock();}
});
test('legacy semantic oracle rejects authenticated wrong content, tamper, exact scope identity and metadata drift',async()=>{
 const f=await fixture(),before=await f.repository.load();
 try{
  const changed=await validDifferentRemote(f,d=>{d.records.find(r=>r.type==='credential').data.secret='SYNTHETIC-wrong-secret';});await assert.rejects(verify(f,{remote:changed}),/legacy_roundtrip_failed/);
  const missing=await validDifferentRemote(f,d=>d.records.pop());await assert.rejects(verify(f,{remote:missing}),/legacy_roundtrip_failed/);
  for(const edit of [r=>r.ciphertext=(r.ciphertext[0]==='A'?'B':'A')+r.ciphertext.slice(1),r=>r.wrapper.membershipEpoch=2,r=>r.wrapper.deviceID='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',r=>r.keyGeneration=2,r=>r.revision++,r=>r.scope.teamID='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',r=>r.id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',r=>r.teamID='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',r=>r.rotationRequired=true]){const remote=structuredClone(f.remote);edit(remote);await assert.rejects(verify(f,{remote}),/legacy_roundtrip_failed/);}
  for(const edit of [c=>c.envelope=f.initial.cached.envelope,c=>c.syncedLocalRevision--,c=>c.localRevision++,c=>c.serverRevision--,c=>c.keyGeneration++,c=>c.scope.vaultID='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',c=>c.deviceID='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',c=>c.wrapper.membershipID='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee']){const cached=structuredClone(f.cached);edit(cached);await assert.rejects(verify(f,{cached}),/legacy_roundtrip_failed/);}
  assert.deepEqual(await f.repository.load(),before);
  await f.owner.upsert({id:f.document.records[0].id,type:f.document.records[0].type,data:{...f.document.records[0].data,title:'SYNTHETIC-unsynced'}});await assert.rejects(verify(f),/legacy_roundtrip_failed/);
 }finally{f.owner.lock();}
});
test('legacy verifier locks transient controllers after authentication failure and is self-contained when serialized',async()=>{
 const f=await fixture(),transient=[],before=await f.repository.load();
 const observedTeam={...team,createTeamVaultController(options){const c=team.createTeamVaultController(options);transient.push(c);return c;}};
 try{
  const remote=await validDifferentRemote(f,d=>{d.records[0].data.title='SYNTHETIC-wrong-document';});await assert.rejects(verify(f,{team:observedTeam,remote}),/legacy_roundtrip_failed/);assert.equal(transient.length,2);for(const c of transient)assert.equal(await c.status(),'locked');
  await (0,eval)('('+lifecycle.stagingLegacyRoundtripGuard.toString()+')')({installOnly:true});try{assert.deepEqual(await globalThis.__prcVerifyLegacyRoundtrip({team,identity:f.identity,scope,controller:f.owner,cached:f.cached,remote:f.remote,expectedRecordCount:4}),await verify(f));}finally{delete globalThis.__prcVerifyLegacyRoundtrip;}
  assert.deepEqual(await f.repository.load(),before);
 }finally{f.owner.lock();}
});
test('legacy zero-record initialization returns authenticated actual server envelope',async()=>{
 const f=await fixture({populated:false});try{const before=await f.repository.load(),legacy=await verify(f,{expectedRecordCount:0});assert.equal(legacy.revision,1);assert.deepEqual(legacy.envelope,f.cached.envelope);assert.deepEqual(await f.repository.load(),before);}finally{f.owner.lock();}
});
