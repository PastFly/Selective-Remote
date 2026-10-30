import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
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

import * as lifecycle from './browser/staging-real-lifecycle.mjs';
import * as keys from '../public/team-vault-crypto.js';
import * as team from '../public/team-vault-sync.js';
import * as trust from '../public/device-trust-v1.js';
import {generateVaultKey} from '../public/vault-crypto.js';
import {createEmptyVaultDocument} from '../public/vault-model.js';
import {canonicalMigrationJSON} from '../public/vault-v2-migration.js';
const publicDigest=value=>createHash('sha256').update(canonicalMigrationJSON(value)).digest('hex');
async function initializedBrowserFixture(document=createEmptyVaultDocument()){
 const f=fixture(),{options:o,values:v}=f,origin='https://cloud.pastfly.ru';o.identity={deviceID:o.identity.deviceID,...await keys.generateTeamDeviceIdentity()};
 const scope={type:'team',teamID:o.partial.created.teamID,vaultID:o.partial.created.vaults[0].vaultID},vaultKey=await generateVaultKey(),recipient={membershipID:o.partial.membershipID,membershipEpoch:1,deviceID:o.identity.deviceID};
 const wrapper=await keys.wrapTeamVaultKeyForDevice({vaultKey,recipient:{...recipient,publicKey:o.identity.publicKey},...scope,keyGeneration:1});
 const envelope=await keys.encryptTeamVaultPayload({vaultKey,payload:document,scope,baseRevision:0,keyGeneration:1});
 v.remote={revision:1,keyGeneration:1,rotationRequired:false,...envelope,wrapper};
 v.local={deviceID:o.identity.deviceID,scope,keyGeneration:1,localRevision:1,serverRevision:1,syncedLocalRevision:1,envelope,wrapper};
 const root=await trust.createTrustRoot({endpoint:origin,accountID:o.userID}),certificate=await trust.issueDeviceCertificate({root,accountID:o.userID,deviceID:o.identity.deviceID,publicKey:o.identity.publicKey,keyVersion:1,issuedAt:1,serial:randomUUID()}),checkpoint=await trust.signDeviceDirectory({root,accountID:o.userID,version:1,certificates:[certificate]});
 const pin={endpoint:origin,accountID:o.userID,rootFingerprint:root.fingerprint,highWater:1,checkpointDigest:await trust.deviceDirectoryDigest(checkpoint)};
 v.snapshot={state:'ROOT_PUBLISHED',rootPublicKey:root.publicKey,rootFingerprint:root.fingerprint,custodianDeviceID:o.identity.deviceID,checkpoint,certificates:[certificate]};v.recipients=[{...recipient,hasWrapper:true,publicKey:o.identity.publicKey}];
 v.members=[{id:o.partial.membershipID,epoch:1,userID:o.userID,role:'owner'}];v.invitations=[];o.client.listTeamMembers=async()=>v.members;o.client.listTeamInvitations=async()=>v.invitations;
 o.client.deviceTrustSnapshot=async()=>v.snapshot;o.client.listTeamKeyDevices=async()=>({devices:v.recipients});
 o.team={...team,createIndexedDBTeamVaultRepository:()=>({load:async()=>v.local,save:async()=>{throw Error('guard_must_not_write');}})};
 o.keys=keys;o.trust=trust;o.pin=pin;o.origin=origin;
 o.initialized={created:o.partial.created,membershipID:o.partial.membershipID,membershipEpoch:1,envelopeSHA256:publicDigest(envelope),wrappers:[{...recipient,wrapperSHA256:publicDigest(wrapper)}],requiredRecipients:[recipient],ownerTrust:{accountID:o.userID,deviceID:o.identity.deviceID,rootFingerprint:root.fingerprint,publicKeyFingerprint:await keys.teamDevicePublicKeyFingerprint(o.identity.publicKey),signedDirectorySHA256:publicDigest(checkpoint),certificateSHA256:publicDigest(certificate)}};
 return f;
}
test('initialized browser guard decrypts actual clean empty remote/cache without writes and retains created IDs',async()=>{
 assert.equal(typeof lifecycle.stagingInitializedBootstrapGuard,'function');const f=await initializedBrowserFixture();
 assert.deepEqual(await lifecycle.stagingInitializedBootstrapGuard(f.options),f.values.saved);
});
test('initialized browser rejects nonempty or dirty cache, ciphertext, wrapper, recipients and trust changes',async()=>{
 assert.equal(typeof lifecycle.stagingInitializedBootstrapGuard,'function');
 for(const mutate of [f=>f.values.local.localRevision=2,f=>f.values.local.syncedLocalRevision=0,f=>f.values.local.serverRevision=0,f=>f.values.local.envelope={...f.values.local.envelope,ciphertext:'bad'},f=>f.values.local.wrapper={...f.values.local.wrapper,authTag:'bad'},f=>f.values.remote={...f.values.remote,ciphertext:'bad'},f=>f.values.remote={...f.values.remote,wrapper:{...f.values.remote.wrapper,authTag:'bad'}},f=>f.values.recipients=[],f=>f.values.recipients[0].hasWrapper=false,f=>f.values.recipients[0].deviceID=randomUUID(),f=>f.values.vaults.push({id:randomUUID()}),f=>f.values.team.membershipEpoch=2,f=>f.values.legacy={},f=>f.values.expected={},f=>f.options.pin={...f.options.pin,rootFingerprint:'0'.repeat(64)},f=>f.values.snapshot={...f.values.snapshot,checkpoint:{...f.values.snapshot.checkpoint,signature:'bad'}}]){
  const f=await initializedBrowserFixture();mutate(f);await assert.rejects(lifecycle.stagingInitializedBootstrapGuard(f.options));
 }
 for(const document of [{...createEmptyVaultDocument(),records:[{id:randomUUID(),type:'host',data:{title:'existing'},version:{deviceID:randomUUID(),counter:1},modifiedAt:1}]},{...createEmptyVaultDocument(),tombstones:[{id:randomUUID(),version:{deviceID:randomUUID(),counter:1},deletedAt:1}]},{...createEmptyVaultDocument(),vectorClock:{[randomUUID()]:1}}]){
  const f=await initializedBrowserFixture(document);await assert.rejects(lifecycle.stagingInitializedBootstrapGuard(f.options));
 }
});
test('serialized initialized guard is self-contained and old guard still rejects revision one',async()=>{
 assert.equal(typeof lifecycle.stagingInitializedBootstrapGuard,'function');const f=await initializedBrowserFixture();await assert.rejects(stagingPartialBootstrapGuard(f.options),/partial_bootstrap_changed/);
 await (0,eval)('('+lifecycle.stagingInitializedBootstrapGuard.toString()+')')({installOnly:true});try{assert.deepEqual(await globalThis.__prcInspectInitializedBootstrap(f.options),f.values.saved);}finally{delete globalThis.__prcInspectInitializedBootstrap;}
});

test('initialized browser rechecks owner-only membership and no invitations immediately before writes',async()=>{
 for(const mutate of [f=>f.values.members.push({...f.values.members[0],id:randomUUID(),userID:randomUUID()}),f=>f.values.members[0].epoch=2,f=>f.values.members[0].role='editor',f=>f.values.invitations.push({id:randomUUID()})]){
  const f=await initializedBrowserFixture();mutate(f);await assert.rejects(lifecycle.stagingInitializedBootstrapGuard(f.options),/initialized_bootstrap_changed/);
 }
});

test('initialized browser observation records actual decrypted revisions, ciphertext and wrapper digests',async()=>{
 const f=await initializedBrowserFixture(),v=await lifecycle.stagingInitializedBootstrapGuard({...f.options,observationOnly:true});
 assert.equal(v.envelopeSHA256,publicDigest(f.values.local.envelope));assert.equal(v.ownWrapperSHA256,publicDigest(f.values.local.wrapper));assert.equal(v.serverRevision,1);assert.equal(v.localRevision,1);assert.deepEqual(v.emptyCounts,{records:0,tombstones:0,vectorClock:0});assert.equal(v.deviceID,f.options.identity.deviceID);assert.equal(v.vaultID,f.values.local.scope.vaultID);assert.ok(Date.parse(v.observedAt));
});

test('uploaded browser helper is explicit and serialized; initialized mode remains strict',async()=>{
 assert.equal(typeof lifecycle.stagingUploadedBootstrapContinuation,'function');
 const f=await initializedBrowserFixture();f.values.remote.revision=2;
 await assert.rejects(lifecycle.stagingInitializedBootstrapGuard(f.options));
 await (0,eval)('('+lifecycle.stagingUploadedBootstrapContinuation.toString()+')')({installOnly:true});
 assert.equal(typeof globalThis.__prcContinueUploadedBootstrap,'function');delete globalThis.__prcContinueUploadedBootstrap;
});

async function uploadedBrowserFixture(){
 const f=await initializedBrowserFixture(),o=f.options,v=f.values,scope=v.local.scope,repo={load:async()=>structuredClone(v.local),save:async next=>{v.local=structuredClone(next);}};
 v.remote={...v.remote,scope,id:scope.vaultID,teamID:scope.teamID};
 const initialClient={session:()=>({id:o.userID}),getTeamVault:async()=>structuredClone(v.remote),putTeamVault:async(s,next)=>{v.remote={...v.remote,...next,revision:2};return {revision:2,keyGeneration:1,conflict:false};}};
 const owner=team.createTeamVaultController({repository:repo,identity:o.identity,scope});await owner.unlock();
 for(const record of lifecycle.stagingV1Records())await owner.upsert(record);
 await team.synchronizeTeamVault({client:initialClient,controller:owner,role:'owner'});
 const document=owner.document();owner.lock();
 o.uploaded={...o.initialized,revision:2,envelopeSHA256:publicDigest(Object.fromEntries(['baseRevision','keyGeneration','envelopeVersion','ciphertext','nonce','authTag','contentHash'].map(k=>[k,v.remote[k]])))};
 o.expectedFixture={shapeVersion:1,documentSHA256:publicDigest(document),records:document.records.map(r=>({id:r.id,type:r.type,canonicalSHA256:publicDigest(r)})).sort((a,b)=>a.id.localeCompare(b.id))};
 o.interval={startsAt:new Date(Date.now()-1000).toISOString(),endsAt:new Date(Date.now()+60000).toISOString()};o.memberEmail='member@example.test';o.verifyLegacy=lifecycle.stagingLegacyRoundtripGuard;
 const values=new Map([['created',structuredClone(v.saved)]]),emptyRepos=new Map(),remote=new Map([[scope.vaultID,v.remote]]),writes=[],forbidden=[];let hook=()=>{};
 o.storage=async function(key,value){if(arguments.length===2){values.set(key,structuredClone(value));return;}return structuredClone(values.get(key));};
 o.client.session=()=>({id:o.userID});o.client.getTeamVault=async s=>{hook('get',s);return structuredClone(remote.get(s.vaultID));};
 o.client.createSharedVault=async({teamID,name})=>{writes.push('create');const id=randomUUID();v.vaults.push({id,name});remote.set(id,{scope:{type:'team',teamID,vaultID:id},id,teamID,name,revision:0,keyGeneration:1,rotationRequired:false,envelopeVersion:null,ciphertext:null,nonce:null,authTag:null,contentHash:null,wrapper:null});hook('create');return {id};};
 o.client.putTeamVault=async(s,envelope)=>{assert.notEqual(s.vaultID,scope.vaultID);writes.push('put');const next={...remote.get(s.vaultID),...envelope,revision:1,wrapper:envelope.wrappers.find(w=>w.deviceID===o.identity.deviceID)};delete next.wrappers;remote.set(s.vaultID,next);hook('put');return {conflict:false,revision:1,keyGeneration:1};};
 o.client.listTeamKeyDevices=async s=>({devices:v.recipients.map(r=>({...r,hasWrapper:s.vaultID===scope.vaultID||remote.get(s.vaultID)?.revision===1}))});
 o.client.inviteTeamMember=async({teamID,email,role})=>{writes.push('invite');const result={id:randomUUID(),teamID,email,role};v.invitations.push(result);hook('invite');return result;};
 o.team={...team,createIndexedDBTeamVaultRepository:s=>{
  if(s.vaultID===scope.vaultID)return {load:()=>repo.load(),save:async()=>{forbidden.push('populated-save');throw Error('populated_write');}};
  if(!emptyRepos.has(s.vaultID)){let value=null;emptyRepos.set(s.vaultID,{load:async()=>structuredClone(value),save:async next=>{value=structuredClone(next);}});}return emptyRepos.get(s.vaultID);
 },createTeamVaultController:options=>{
  const c=team.createTeamVaultController(options);
  if(options.scope.vaultID===scope.vaultID)for(const name of ['upsert','initialize','prepareInitialization','prepareUpload'])c[name]=()=>{forbidden.push(name);throw Error('populated_mutation');};
  return c;
 }};
 return {...f,actual:v,document,remote,values,writes,forbidden,hook:fn=>{hook=fn;}};
}
test('uploaded continuation uses real crypto/controllers, skips every populated mutation and only initializes empty then invites',async()=>{
 const f=await uploadedBrowserFixture(),before=structuredClone(f.values.get('created')),cached=structuredClone(f.actual.local),result=await lifecycle.stagingUploadedBootstrapContinuation(f.options);
 assert.equal(result.teamID,before.teamID);assert.deepEqual(result.vaults[0],before.vaults[0]);assert.equal(result.vaults.length,2);assert.deepEqual(f.writes,['create','put','invite']);assert.deepEqual(f.forbidden,[]);assert.deepEqual(f.actual.local,cached);
 assert.equal(f.remote.get(before.vaults[0].vaultID).revision,2);assert.equal(f.values.get('legacy:'+before.vaults[0].vaultID).revision,2);
 assert.deepEqual(f.values.get('expected:'+before.vaults[0].vaultID).records.map(r=>({id:r.id,type:r.type,canonicalSHA256:r.digest})),f.options.expectedFixture.records);
});
test('uploaded continuation refuses digest, IDs, shapes, cache, trust, graph and recipients before any transport write',async()=>{
 for(const mutate of [f=>f.actual.local.localRevision++,f=>f.actual.local.syncedLocalRevision--,f=>f.actual.local.serverRevision--,f=>f.actual.local.envelope={...f.actual.local.envelope,ciphertext:'bad'},f=>f.options.expectedFixture.documentSHA256='0'.repeat(64),f=>f.options.expectedFixture.records[0].id=randomUUID(),f=>f.options.expectedFixture.records[0].canonicalSHA256='0'.repeat(64),f=>f.options.expectedFixture.records.reverse(),f=>f.options.uploaded.envelopeSHA256='0'.repeat(64),f=>f.options.uploaded.wrappers[0].wrapperSHA256='0'.repeat(64),f=>f.options.pin.rootFingerprint='0'.repeat(64),f=>f.options.uploaded.requiredRecipients=[],f=>f.options.uploaded.created.actorDeviceID=randomUUID(),f=>f.options.client.listTeamInvitations=async()=>[{id:randomUUID()}],f=>f.options.client.listSharedVaults=async()=>[],f=>f.options.client.listTeamMembers=async()=>[],f=>f.options.client.getTeamDeviceAdmissionPolicy=async()=>({automaticDeviceAdmission:false})]){
  const f=await uploadedBrowserFixture();mutate(f);await assert.rejects(lifecycle.stagingUploadedBootstrapContinuation(f.options));assert.deepEqual(f.writes,[]);assert.deepEqual(f.forbidden,[]);
 }
});
test('uploaded continuation rejects authenticated equal remote/cache wrong shape despite rebound public digest',async()=>{
 const f=await uploadedBrowserFixture(),o=f.options,scope=o.uploaded.created.vaults[0].vaultID,remote=f.remote.get(scope),repository=o.team.createIndexedDBTeamVaultRepository(remote.scope),cached=await repository.load();
 const key=await keys.unwrapTeamVaultKeyForDevice({privateKey:o.identity.privateKey,wrapper:remote.wrapper,...remote.scope,keyGeneration:1,deviceID:o.identity.deviceID});
 const changed=structuredClone(f.document);changed.records.find(r=>r.type==='host').data.address='ordinary.invalid';
 const envelope=await keys.encryptTeamVaultPayload({vaultKey:key,payload:changed,scope:remote.scope,baseRevision:1,keyGeneration:1});f.remote.set(scope,{...remote,...envelope});
 o.team.createIndexedDBTeamVaultRepository=()=>({load:async()=>({...cached,envelope}),save:async()=>{throw Error('forbidden');}});
 o.expectedFixture={shapeVersion:1,documentSHA256:publicDigest(changed),records:changed.records.map(r=>({id:r.id,type:r.type,canonicalSHA256:publicDigest(r)})).sort((a,b)=>a.id.localeCompare(b.id))};o.uploaded.envelopeSHA256=publicDigest(envelope);
 await assert.rejects(lifecycle.stagingUploadedBootstrapContinuation(o),/uploaded_bootstrap_changed/);assert.deepEqual(f.writes,[]);
});
test('uploaded continuation expiry between mutations and during terminal verification emits no result or subsequent transport',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});
 for(const point of ['create','put','invite']){
  const f=await uploadedBrowserFixture();f.hook(stage=>{if(stage===point)t.mock.timers.tick(61000);});
  await assert.rejects(lifecycle.stagingUploadedBootstrapContinuation(f.options),/uploaded_authorization_expired/);
  assert.deepEqual(f.writes,point==='create'?['create']:point==='put'?['create','put']:['create','put','invite']);assert.deepEqual(f.forbidden,[]);
  assert.ok(f.values.get('legacy:'+f.options.uploaded.created.vaults[0].vaultID));assert.equal(f.values.get('created').vaults.length,2);
 }
});

test('uploaded expiry during asynchronous read verification prevents first mutation and terminal result',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});
 for(const terminal of [false,true]){
  const f=await uploadedBrowserFixture();let expired=false;
  f.hook(stage=>{if(!expired&&stage==='get'&&(!terminal||f.writes.includes('invite'))){expired=true;t.mock.timers.tick(61000);}});
  let completed=false;await assert.rejects(lifecycle.stagingUploadedBootstrapContinuation(f.options).then(()=>{completed=true;}),/uploaded_authorization_expired/);
  assert.equal(completed,false);assert.deepEqual(f.writes,terminal?['create','put','invite']:[]);
 }
});
test('human pause expiry blocks the runner continuation after the actual operator wait helper',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});
 const interval={startsAt:new Date(Date.now()-1).toISOString(),endsAt:new Date(Date.now()+1000).toISOString()};let completed=false,nextCalls=0;
 const terminal={question:async()=>{t.mock.timers.tick(1001);return '';}};
 await assert.rejects(lifecycle.waitForLifecycleOperator(terminal,'synthetic acceptance pause',interval).then(()=>{nextCalls++;completed=true;}),/uploaded_authorization_expired/);
 assert.equal(nextCalls,0);assert.equal(completed,false);
});

test('uploaded admission inspects full browser semantics before any exclusive claim or run metadata write',async()=>{
 assert.equal(typeof lifecycle.inspectThenClaimUploaded,'function');
 for(const mutate of [f=>f.actual.local.localRevision++,f=>f.actual.local.syncedLocalRevision--,f=>f.options.expectedFixture.records[0].type='unknown']){
  const f=await uploadedBrowserFixture(),original=f.options.storage;mutate(f);let claims=0;
  f.options.storage=async function(...args){assert.equal(args.length,1);return original(...args);};
  await assert.rejects(lifecycle.inspectThenClaimUploaded({interval:f.options.interval,inspect:()=>lifecycle.stagingUploadedBootstrapContinuation({...f.options,inspectOnly:true}),claim:async()=>{claims++;}}));
  assert.equal(claims,0);assert.deepEqual(f.writes,[]);assert.deepEqual(f.forbidden,[]);assert.equal(f.values.size,1);
 }
});

async function inspectPreclaimFixture(f){
 const o=f.options,account=o.uploaded.ownerTrust;
 await lifecycle.stagingLegacyRoundtripGuard({installOnly:true});await lifecycle.stagingUploadedBootstrapContinuation({installOnly:true});
 const readRecord=async(name,store,key)=>{
  if(name==='selective-remote-cloud'&&store==='local-vault'){
   if(key==='team-device-key:'+o.identity.deviceID)return o.identity;
   if(key===`team-vault:${o.uploaded.created.teamID}:${o.uploaded.created.vaults[0].vaultID}`)return structuredClone(f.actual.local);
  }
  if(name==='selective-remote-device-trust-v1'&&store==='records'){
   if(key==='pin:'+o.origin+'|'+o.userID)return o.pin;
   if(key==='root:'+o.origin+'|'+o.userID)return {endpoint:o.origin,accountID:o.userID,publicKey:f.actual.snapshot.rootPublicKey};
  }
  if(name==='selective-remote-real-'+o.runID&&store==='run')return structuredClone(f.values.get(key));
  throw Error('unexpected_read');
 };
 try{
  const inspect=(0,eval)('('+lifecycle.inspectUploadedBrowser.toString()+')');
  return await inspect({...o,email:'owner@example.test',account,failureCodes:['uploaded_bootstrap_changed','legacy_roundtrip_failed','uploaded_authorization_expired','preserved_identity_changed','readonly_storage_required','product_trust_required']},{team:o.team,keys:o.keys,trust:o.trust,readRecord,client:{...o.client,restoreSession:async()=>({id:o.userID,email:'owner@example.test'}),deviceID:()=>o.identity.deviceID}});
 }finally{delete globalThis.__prcVerifyLegacyRoundtrip;delete globalThis.__prcContinueUploadedBootstrap;}
}
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
test('actual preclaim page inspection rejects dirty stale and authenticated wrong-shape content before exclusive files',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'uploaded-preclaim-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 for(const kind of ['dirty','stale','wrong-shape']){
  const f=await uploadedBrowserFixture();
  if(kind==='dirty')f.actual.local.syncedLocalRevision--;
  if(kind==='stale')f.actual.local.serverRevision--;
  if(kind==='wrong-shape'){
   const id=f.options.uploaded.created.vaults[0].vaultID,remote=f.remote.get(id),key=await keys.unwrapTeamVaultKeyForDevice({privateKey:f.options.identity.privateKey,wrapper:remote.wrapper,...remote.scope,keyGeneration:1,deviceID:f.options.identity.deviceID}),changed=structuredClone(f.document);
   changed.records.find(r=>r.type==='host').data.address='ordinary.invalid';
   const envelope=await keys.encryptTeamVaultPayload({vaultKey:key,payload:changed,scope:remote.scope,baseRevision:1,keyGeneration:1});f.remote.set(id,{...remote,...envelope});f.actual.local.envelope=envelope;
  }
  let calls=0;const claimPath=join(dir,kind+'-claim.json'),admissionPath=join(dir,kind+'-admission.json');
  await assert.rejects(lifecycle.inspectThenClaimUploaded({interval:f.options.interval,inspect:async()=>{const result=await inspectPreclaimFixture(f);if(result.outcome!=='PASS')throw Error(result.failureCode);},claim:async()=>{calls++;await writeFile(claimPath,'consumed',{flag:'wx'});await writeFile(admissionPath,'admitted',{flag:'wx'});}}));
  assert.equal(calls,0);await assert.rejects(readFile(claimPath),{code:'ENOENT'});await assert.rejects(readFile(admissionPath),{code:'ENOENT'});assert.deepEqual(f.writes,[]);assert.deepEqual(f.forbidden,[]);assert.equal(f.values.size,1);
 }
});
test('valid preclaim page inspection precedes claim, and drift after consumption still denies before any mutation',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'uploaded-preclaim-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const f=await uploadedBrowserFixture(),events=[],before=structuredClone(f.actual.local),claimPath=join(dir,'claim.json'),admissionPath=join(dir,'admission.json');
 await lifecycle.inspectThenClaimUploaded({interval:f.options.interval,inspect:async()=>{const result=await inspectPreclaimFixture(f);assert.equal(result.outcome,'PASS');events.push('inspect');},claim:async()=>{events.push('claim');await writeFile(claimPath,'consumed',{flag:'wx'});await writeFile(admissionPath,'admitted',{flag:'wx'});}});
 assert.deepEqual(events,['inspect','claim']);assert.deepEqual(f.actual.local,before);assert.equal(f.values.size,1);assert.deepEqual(f.writes,[]);assert.deepEqual(f.forbidden,[]);
 f.actual.local.syncedLocalRevision--;
 await assert.rejects(lifecycle.stagingUploadedBootstrapContinuation(f.options));assert.deepEqual(f.writes,[]);assert.equal(await readFile(claimPath,'utf8'),'consumed');assert.equal(await readFile(admissionPath,'utf8'),'admitted');
});
test('expiry during preclaim semantic inspection prevents exclusive claim',async t=>{
 t.mock.timers.enable({apis:['Date'],now:Date.now()});const f=await uploadedBrowserFixture();let claims=0;
 await assert.rejects(lifecycle.inspectThenClaimUploaded({interval:f.options.interval,inspect:async()=>{assert.equal((await inspectPreclaimFixture(f)).outcome,'PASS');t.mock.timers.tick(61000);},claim:async()=>{claims++;}}),/uploaded_authorization_expired/);assert.equal(claims,0);assert.equal(f.values.size,1);
});
