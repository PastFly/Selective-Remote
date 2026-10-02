import assert from 'node:assert/strict';
import test from 'node:test';
import { webcrypto, createHash } from 'node:crypto';
import { migrationFixture, uuid, legacy, record } from './vault-v2-migration-fixtures.mjs';
import { prepareLegacyMigration, canonicalMigrationJSON } from '../public/vault-v2-migration.js';
import { createWholePublicationCheckpointRepository } from '../public/whole-publication-client.js';
import { publicationHash, prepareAdministrativeSidecarCommitment } from '../public/vault-publication-v1.js';
import { signDeviceDirectory, deviceDirectoryDigest } from '../public/device-trust-v1.js';
const api = await import('../public/whole-publication-flow.js').catch(() => ({}));
const clone = structuredClone;

test('desired publication applies grant, group and move intents to the full team without changing resource identities', () => {
  assert.equal(typeof api.buildWholePublicationRequest, 'function');
  const teamID=uuid(),vaultID=uuid(),other=uuid(),userID=uuid(),membershipID=uuid(),groupID=uuid(),resourceID=uuid(),folderID=uuid(),grantID=uuid();
  const resource={id:resourceID,kind:'SNIPPET',parentFolderID:null,sourceOrdinal:0};
  const policy={id:grantID,teamID,vaultID:other,principalKind:'GROUP',principalID:groupID,targetKind:'VAULT',targetID:other,mask:1,revokedAt:null};
  const context={teamID,current:[{teamID,vaultID,sequence:3,resources:[resource,{id:folderID,kind:'FOLDER',parentFolderID:null,sourceOrdinal:1}],policy:[],custodianDeviceIDs:[uuid()]},
    {teamID,vaultID:other,sequence:2,resources:[],policy:[policy],custodianDeviceIDs:[uuid()]}],groups:[{id:groupID,name:'Readers',version:1}],edges:[],memberships:[{id:membershipID,userID,epoch:2,role:'member'}]};
  const move=api.buildWholePublicationRequest({context,vaultID,draft:{changes:[{type:'RESOURCE_MOVE',resourceID,newParentFolderID:folderID,expectedResourceVersion:3}]},cryptoValue:webcrypto});
  assert.equal(move.vaults.length,2);assert.equal(move.vaults.find(v=>v.vaultID===vaultID).resources.find(r=>r.id===resourceID).parentFolderID,folderID);
  assert.deepEqual(context.current[0].resources[0],resource);
  const grant=api.buildWholePublicationRequest({context,vaultID,draft:{changes:[{type:'GRANT_CREATE',principalKind:'USER',principalID:userID,targetKind:'RESOURCE',targetID:resourceID,permissionMask:5}]},cryptoValue:webcrypto});
  const created=grant.vaults.find(v=>v.vaultID===vaultID).policy[0];assert.equal(created.membershipID,membershipID);assert.equal(created.membershipEpoch,2);assert.equal(created.mask,5);
  const deletion=api.buildWholePublicationRequest({context,vaultID,draft:{type:'GROUP_DELETE',groupID,expectedVersion:1},cryptoValue:webcrypto});
  assert.deepEqual(deletion.groupMutation,{action:'DELETE',groupID});assert.deepEqual(deletion.vaults.find(v=>v.vaultID===other).policy,[]);
  assert.throws(()=>api.buildWholePublicationRequest({context,vaultID,draft:{changes:[{type:'RESOURCE_MOVE',resourceID,newParentFolderID:folderID,expectedResourceVersion:2}]},cryptoValue:webcrypto}),/publication_stale/);
  const revoked=clone(context);revoked.current[1].policy.push({...policy,id:uuid(),principalKind:'USER',principalID:userID,membershipID,membershipEpoch:1});revoked.groups=[];
  const cleaned=api.buildWholePublicationRequest({context:revoked,vaultID,draft:{type:'GROUP_CREATE',name:'New'},cryptoValue:webcrypto});assert.deepEqual(cleaned.vaults.find(v=>v.vaultID===other).policy,[]);assert.equal(revoked.current[1].policy.length,2);
});

async function fixture() {
  const f=await migrationFixture(),initial=await prepareLegacyMigration({...f,document:legacy([record('credential',{kind:'password',title:'Login',username:'alice',secret:'SYNTHETIC-SECRET'})]),policy:[],
    recipientTargets:()=>[f.recipient],persistCheckpoint:async()=>{},cryptoValue:webcrypto,readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,custodianDeviceIDs:[f.deviceID],custodianTargets:[f.recipient],verifyIdentityReservations:async()=>{}}});
  const header=initial.readerProjection.header,headerHash=await publicationHash('header',header,webcrypto),own=initial.readerProjection.recipients[0];
  const predecessor={vaultID:f.scope.vaultID,generationID:f.scope.attemptID,sequence:1,headerHash};
  const context={teamID:f.scope.teamID,current:[{teamID:f.scope.teamID,...predecessor,resources:initial.resources,policy:[],custodianDeviceIDs:[f.deviceID]}]};
  const publisher={...f.recipient,keyVersion:1,generationID:f.scope.attemptID,headerHash};
  const directory={header,headerHash,generationID:f.scope.attemptID,scope:f.scope,manifest:initial.manifest,publisher,administrativeResourceID:initial.administrativeSidecar.resourceID,
    inventory:own.inventory,descriptors:initial.readerProjection.descriptors,nextCursor:null};
  const side=(await prepareAdministrativeSidecarCommitment(initial.administrativeSidecar,[f.recipient],webcrypto)).items[0];
  const transport={repairDirectory:async()=>clone(directory),repairPart:async(_p,_v,resourceID,part)=>part==='ADMINISTRATIVE'?{...clone(side),resourceID,part:'SECRET',envelope:clone(initial.administrativeSidecar.envelope),headerHash,generationID:f.scope.attemptID,manifest:clone(initial.manifest),scope:clone(f.scope),publisher:clone(publisher)}:
    {headerHash,generationID:f.scope.attemptID,descriptor:clone(initial.readerProjection.descriptors.find(d=>d.payload.resourceID===resourceID&&d.payload.part===part)),envelope:clone(initial.objects.find(o=>o.resourceID===resourceID&&o.part===part).envelope),...clone(own.proofs.find(p=>p.resourceID===resourceID&&p.part===part))}};
  const identity={endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,keyVersion:1,sessionID:uuid()};
  return {...f,initial,context,directory,transport,localIdentity:identity,preview:{token:'bound-repair-preview',request:{teamID:f.scope.teamID,operationID:uuid()},binding:{predecessors:[predecessor]}},getIdentity:()=>clone(identity)};
}
test('repair authenticates the actual initial manifest, all ordinary parts, and administrative own-wrapper proof',async()=>{
  assert.equal(typeof api.repairWholePublicationSources,'function');const f=await fixture();
  const sources=await api.repairWholePublicationSources({...f,privateKey:f.identity.privateKey,devicePrivateKey:f.identity.privateKey,ownIdentity:f.getIdentity(),cryptoValue:webcrypto});
  const id=f.initial.resources.find(r=>r.kind==='CREDENTIAL').id;
  assert.equal(sources.plaintextByVault[f.scope.vaultID].parts[id].SECRET.record.data.secret,'SYNTHETIC-SECRET');
  assert.equal(sources.administrativeByVault[f.scope.vaultID].data.generationID,f.scope.attemptID);
  const broken=clone(f.directory);broken.manifest.signature=broken.manifest.signature.replace(/^./u,broken.manifest.signature[0]==='A'?'B':'A');
  await assert.rejects(api.repairWholePublicationSources({...f,transport:{...f.transport,repairDirectory:async()=>broken},devicePrivateKey:f.identity.privateKey,ownIdentity:f.getIdentity(),cryptoValue:webcrypto}),/publication_manifest_invalid/);
  await assert.rejects(api.repairWholePublicationSources({...f,pinnedTrust:{loadPin:async()=>null},devicePrivateKey:f.identity.privateKey,ownIdentity:f.getIdentity(),cryptoValue:webcrypto}),/publisher_trust_unverified/);
});
test('repair rejects omitted SECRET, forged sidecar custody, and identity changes; historical publisher never advances pins',async()=>{
  const f=await fixture(),base={...f,devicePrivateKey:f.identity.privateKey,ownIdentity:f.getIdentity(),cryptoValue:webcrypto};
  const omitted=clone(f.directory);omitted.descriptors=omitted.descriptors.filter(d=>d.payload.part!=='SECRET');
  await assert.rejects(api.repairWholePublicationSources({...base,transport:{...f.transport,repairDirectory:async()=>omitted}}),/publication_incomplete/);
  await assert.rejects(api.repairWholePublicationSources({...base,transport:{...f.transport,repairPart:async(...args)=>{const result=await f.transport.repairPart(...args);if(args[3]==='ADMINISTRATIVE')result.entry.wrapper.context.deviceID=uuid();return result;}}}),/publication_wrapper_proof_invalid/);
  const current=await signDeviceDirectory({root:f.root,accountID:f.accountID,version:2,certificates:[f.recipient.certificate],cryptoValue:webcrypto});
  const highPin={endpoint:f.endpoint,accountID:f.accountID,rootFingerprint:f.root.fingerprint,highWater:2,checkpointDigest:await deviceDirectoryDigest(current,webcrypto)};let advanced=0;
  f.directory.publisher.historical=true;
  await api.repairWholePublicationSources({...base,pinnedTrust:{loadPin:async()=>highPin,advancePin:async()=>advanced++}});assert.equal(advanced,0);assert.equal(highPin.highWater,2);
  let changed=false;
  await assert.rejects(api.repairWholePublicationSources({...base,getIdentity:()=>changed?null:f.getIdentity(),transport:{...f.transport,repairDirectory:async()=>{changed=true;return f.directory;}}}),/publication_context_changed/);
});

test('active access driver publishes a same-ID edit only after complete approval, fresh encryption, durable checkpoint and receipt readback',async()=>{
  assert.equal(typeof api.createWholePublicationAccessDriver,'function');const f=await fixture();
  const hash=value=>createHash('sha256').update(canonicalMigrationJSON(value)).digest('hex'),stored=new Map(),uploaded=[];let projection,manifest,lastReceipt,approved=false,committed=false,readbackAllowed=false;
  const ctx={...f.context,sessionID:f.localIdentity.sessionID,actorKeyVersion:1,actorRole:'owner',environment:'staging',publicationAvailable:true,groups:[],edges:[],memberships:[{id:f.recipient.membershipID,userID:f.accountID,epoch:1,role:'owner'}]};
  const target={...f.recipient,deviceKeyVersion:1},subject={accountID:f.accountID,deviceID:f.deviceID,membershipID:f.recipient.membershipID,membershipEpoch:1,deviceKeyVersion:1};let preview;
  const transport={...f.transport,context:async()=>clone(ctx),preview:async request=>{
    if(preview)return clone(preview);
    const generationID=uuid(),predecessor=f.preview.binding.predecessors[0],snapshot={devices:[target],sourceRevision:1,policyVersion:2};
    const scope={...f.scope,attemptID:generationID,policyVersion:2,snapshotHash:hash(snapshot)},generation={vaultID:f.scope.vaultID,generationID,sequence:2,previousHash:predecessor.headerHash,scope,snapshot};
    const rows=request.vaults[0].resources.flatMap(r=>(r.kind==='CREDENTIAL'?['METADATA','SECRET']:['GENERAL']).map(part=>({type:'PART',vaultID:f.scope.vaultID,resourceID:r.id,part,devices:[target]})));
    rows.push({type:'CUSTODY',vaultID:f.scope.vaultID,devices:[target]});
    const binding={version:1,teamID:f.scope.teamID,operationID:request.operationID,actorAccountID:f.accountID,actorDeviceID:f.deviceID,sessionID:ctx.sessionID,keyVersion:1,
      requestHash:hash(request),readSetHash:'d'.repeat(64),predecessors:[predecessor],counts:{vaults:1,resources:request.vaults[0].resources.length,parts:rows.length,wrappers:rows.length},effectiveAt:'2026-10-02T00:00:00Z',rowCount:rows.length,rowsHash:hash(rows)};
    binding.policyHash=hash(request.vaults.map(v=>({vaultID:v.vaultID,policy:v.policy})));scope.sourceHash=hash({operationID:request.operationID,requestHash:binding.requestHash,readSetHash:binding.readSetHash,predecessor:predecessor.headerHash});
    binding.recipientHash=hash([{vaultID:f.scope.vaultID,parts:rows.filter(r=>r.type==='PART').map(r=>({resourceID:r.resourceID,part:r.part,devices:[subject]})),custodians:[subject]}]);
    binding.successorHash=hash([{vaultID:f.scope.vaultID,sequence:2,previousHash:predecessor.headerHash,resources:request.vaults[0].resources,policyHash:hash(request.vaults[0].policy),snapshot}]);
    preview={request:clone(request),token:'signed-preview',binding,generations:[generation],rows,nextCursor:null};return clone(preview);
  },start:async()=>{assert.equal(approved,true);assert.ok([...stored.keys()].some(k=>k.startsWith('checkpoint:')));return{};},
  putPart:async(_op,_vault,object)=>uploaded.push(clone(object)),putProjection:async(_op,_vault,p)=>{projection=clone(p);},validate:async(_op,manifests)=>{manifest=clone(manifests[0].manifest);},
  receipt:async()=>lastReceipt??null,commit:async()=>{committed=true;return lastReceipt={operationID:preview.request.operationID,teamID:f.scope.teamID,requestHash:preview.binding.requestHash,actorAccountID:f.accountID,actorDeviceID:f.deviceID,vaults:[{vaultID:f.scope.vaultID,generationID:projection.header.payload.generationID,sequence:2,headerHash:await publicationHash('header',projection.header,webcrypto)}],committedAt:'2026-10-02T00:01:00Z'};},
  readback:async()=>{if(!readbackAllowed)throw Error('team_permission_denied');return {vaultID:f.scope.vaultID,header:projection.header,headerHash:await publicationHash('header',projection.header,webcrypto),manifest};}};
  const repository=createWholePublicationCheckpointRepository({cryptoValue:webcrypto,storage:{load:async k=>clone(stored.get(k)??null),putIfAbsent:async(k,v)=>{if(!stored.has(k))stored.set(k,clone(v));return clone(stored.get(k));},save:async(k,v)=>stored.set(k,clone(v)),keys:async()=>[...stored.keys()]}});
  const driver=api.createWholePublicationAccessDriver({transport,sessionIdentity:()=>({endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,sessionEpoch:'1'}),getLocalKeys:async()=>({root:f.root,identity:f.identity,pinnedTrust:f.pinnedTrust}),checkpointRepository:repository,cryptoValue:webcrypto});
  await driver.getContext({teamID:f.scope.teamID,vaultID:f.scope.vaultID});
  const original=(await api.repairWholePublicationSources({...f,devicePrivateKey:f.identity.privateKey,ownIdentity:f.getIdentity(),cryptoValue:webcrypto})).plaintextByVault[f.scope.vaultID].parts[f.initial.resources[0].id].SECRET.record;
  const edited={...original,modifiedAt:1800000001,version:2,data:{...original.data,secret:'EDITED-SYNTHETIC-SECRET'}};
  const impact=await driver.preview({teamID:f.scope.teamID,vaultID:f.scope.vaultID},{type:'RESOURCE_EDIT',resourceID:f.initial.resources[0].id,record:edited});
  assert.equal(impact.complete,true);assert.equal(uploaded.length,0);assert.equal(committed,false);approved=true;
  await assert.rejects(driver.commit({teamID:f.scope.teamID,vaultID:f.scope.vaultID},impact),/publication_readback_required|team_permission_denied/);
  assert.equal(lastReceipt.vaults[0].sequence,2);assert.equal(committed,true);assert.equal(uploaded.length,2);assert.equal(driver.writesBlocked,true);
  const recoveryContext={...ctx,recoveryOnly:true,operationState:'COMMITTED',actorRole:null,groups:[],edges:[],memberships:[],current:lastReceipt.vaults.map(v=>({...v,teamID:f.scope.teamID,resources:[],policy:[],custodianDeviceIDs:[]}))};
  let keyLoads=0;const reloaded=api.createWholePublicationAccessDriver({transport:{...transport,context:async options=>{assert.equal(options.operationID,lastReceipt.operationID);return recoveryContext;},preview:async()=>{throw Error('recovery_preview');},start:async()=>{throw Error('recovery_start');},putPart:async()=>{throw Error('recovery_upload');}},sessionIdentity:()=>({endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,sessionEpoch:'1'}),getLocalKeys:async()=>{keyLoads++;throw Error('private_key_rehydration');},checkpointRepository:repository,cryptoValue:webcrypto});
  const recoveryScope={teamID:f.scope.teamID,vaultID:f.scope.vaultID};assert.equal((await reloaded.getContext(recoveryScope)).policyMutationAvailable,false);assert.equal(reloaded.enabled,false);
  await assert.rejects(reloaded.resumePrepared(recoveryScope),/publication_readback_required|team_permission_denied/);assert.equal(reloaded.writesBlocked,true);readbackAllowed=true;assert.deepEqual(await reloaded.resumePrepared(recoveryScope),lastReceipt);assert.equal(reloaded.writesBlocked,false);assert.equal(keyLoads,0);assert.equal(uploaded.length,2);
  assert.equal(uploaded[1].resourceID,f.initial.resources[0].id);assert.notEqual(uploaded[1].envelope.nonce,f.initial.objects.find(o=>o.part==='SECRET').envelope.nonce);
  const cek=await (await import('../public/resource-crypto-v2.js')).unwrapResourceCEK({wrapper:uploaded[1].wrappers[0],context:uploaded[1].wrappers[0].context,privateKey:f.identity.privateKey,cryptoValue:webcrypto});
  const plaintext=await (await import('../public/resource-crypto-v2.js')).decryptResourcePart({envelope:uploaded[1].envelope,context:uploaded[1].envelope.context,cek,cryptoValue:webcrypto});cek.fill(0);
  assert.equal(JSON.parse(new TextDecoder().decode(plaintext)).record.data.secret,'EDITED-SYNTHETIC-SECRET');plaintext.fill(0);
});
test('renewed-session READY recovery discovers metadata before context and permits only authenticated discard',async()=>{
  const f=await fixture(),events=[],old={endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,teamID:f.scope.teamID,operationID:uuid(),sessionID:uuid(),keyVersion:1};let forgotten=false,keys=0;
  const context={...f.context,sessionID:uuid(),actorKeyVersion:1,actorRole:'owner',environment:'staging',publicationAvailable:true,operationState:'READY',groups:[],edges:[],memberships:[]};
  const repository={discover:async()=>{events.push('metadata');return forgotten?[]:[old];},pending:async()=>{throw Error('old_session_payload_rehydrated');},forgetDiscarded:async(scope,result)=>{assert.equal(scope.operationID,old.operationID);assert.equal(result.state,'DISCARDED');forgotten=true;}};
  const transport={receipt:async op=>{assert.equal(op,old.operationID);events.push('receipt');return null;},context:async options=>{events.push(options?.operationID?'owned-context':'context');if(!forgotten)assert.equal(options.operationID,old.operationID);return context;},discard:async op=>{events.push('discard');return {operationID:op,state:'DISCARDED'};}};
  const driver=api.createWholePublicationAccessDriver({transport,sessionIdentity:()=>({endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,sessionEpoch:'new'}),getLocalKeys:async()=>{keys++;throw Error('keys_should_not_be_loaded');},checkpointRepository:repository,cryptoValue:webcrypto});
  const scope={teamID:f.scope.teamID,vaultID:f.scope.vaultID},gate=await driver.getContext(scope);assert.deepEqual(events,['metadata','receipt','owned-context']);assert.equal(gate.policyMutationAvailable,false);assert.equal(driver.canResumePending,false);
  await assert.rejects(driver.resumePrepared(scope),/publication_session_renewed/);await driver.discardPrepared(scope);assert.equal(keys,0);assert.equal(forgotten,true);
  assert.equal((await driver.getContext(scope)).policyMutationAvailable,true);assert.equal(driver.pendingOperationID,null);
});

test('checkpoint before START remains fenced after missing context; only confirmed cancellation and later null receipt clear it',async()=>{
  const f=await fixture(),events=[],old={endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID,teamID:f.scope.teamID,operationID:uuid(),sessionID:f.localIdentity.sessionID,keyVersion:1};let forgotten=false,receipt=null,discardFailure=true,renewed=false;
  const context={...f.context,sessionID:f.localIdentity.sessionID,actorKeyVersion:1,actorRole:'owner',environment:'staging',publicationAvailable:true,groups:[],edges:[],memberships:[]};
  const repository={discover:async()=>forgotten?[]:[old],load:async()=>{throw Error('missing_operation_payload_loaded');},forgetDiscarded:async(_scope,result)=>{assert.equal(result.state,'DISCARDED');events.push('forget');forgotten=true;}};
  const transport={receipt:async()=>{events.push('receipt');return receipt;},context:async options=>{events.push(options?.operationID?'owned':'normal');if(options?.operationID)throw Error('publication_operation_not_found');return context;},discard:async op=>{events.push('discard');if(discardFailure)throw Error('team_permission_denied');if(renewed)current=null;return {operationID:op,state:'DISCARDED'};}};
  let current={endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID};
  const driver=api.createWholePublicationAccessDriver({transport,sessionIdentity:()=>current,getLocalKeys:async()=>{throw Error('private_keys_loaded');},checkpointRepository:repository,cryptoValue:webcrypto}),scope={teamID:f.scope.teamID,vaultID:f.scope.vaultID};
  assert.equal((await driver.getContext(scope)).policyMutationAvailable,false);assert.deepEqual(events,['receipt','owned','normal']);assert.equal(driver.canResumePending,false);assert.equal(forgotten,false);
  await assert.rejects(driver.discardPrepared(scope),/team_permission_denied/);assert.equal(forgotten,false);
  discardFailure=false;receipt={operationID:old.operationID};await assert.rejects(driver.discardPrepared(scope),/publication_readback_required/);assert.equal(forgotten,false);
  receipt=null;await driver.getContext(scope);renewed=true;await assert.rejects(driver.discardPrepared(scope),/publication_context_changed/);assert.equal(forgotten,false);
  current={endpoint:f.endpoint,accountID:f.accountID,deviceID:f.deviceID};renewed=false;await driver.getContext(scope);events.length=0;await driver.discardPrepared(scope);assert.deepEqual(events,['discard','receipt','forget']);assert.equal((await driver.getContext(scope)).policyMutationAvailable,true);
});
