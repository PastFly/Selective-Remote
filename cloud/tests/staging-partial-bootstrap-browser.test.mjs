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
