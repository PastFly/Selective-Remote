import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto as c} from 'node:crypto';
import {migrationFixture,legacy,record} from './vault-v2-migration-fixtures.mjs';
import {prepareLegacyMigration,openMigrationCheckpoint} from '../public/vault-v2-migration.js';
import {decryptResourcePart,unwrapResourceCEK} from '../public/resource-crypto-v2.js';
import {validateReaderProjection} from '../public/vault-publication-v1.js';

async function prepare(f,document,extra={}) {
  return prepareLegacyMigration({...f,document,policy:[],recipientTargets:()=>[f.recipient],cryptoValue:c,
    persistCheckpoint:async()=>{},readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,
      custodianDeviceIDs:[f.deviceID],verifyIdentityReservations:async()=>{}},...extra});
}
async function open(f,object) {
  const wrapper=object.wrappers.find(w=>w.context.deviceID===f.deviceID);
  const cek=await unwrapResourceCEK({wrapper,context:wrapper.context,privateKey:f.identity.privateKey,cryptoValue:c});
  try{return JSON.parse(new TextDecoder().decode(await decryptResourcePart({envelope:object.envelope,
    context:object.envelope.context,cek,cryptoValue:c})));}finally{cek.fill(0);}
}
test('representative schema-1 export produces linked typed parts and a metadata-only custodian sidecar',async()=>{
  const f=await migrationFixture(),credential=record('credential',{title:'Label',kind:'password',username:'alice',secret:'TEST-ONLY-SECRET'});
  const doc=legacy([record('host',{title:'Host',address:'example.test',folder:'A/B'}),credential,
    record('snippet',{title:'Snippet',text:'echo test',folder:'Snippets'}),record('forwarding',{configuration:'{"bindHost":"127.0.0.1"}'})]);
  doc.records.forEach(r=>{r.version={[f.deviceID]:2};r.modifiedAt='2026-10-01T00:00:00Z';});
  const result=await prepare(f,doc);assert.ok(result.readerProjection);
  await validateReaderProjection({projection:result.readerProjection,scope:f.scope,resources:result.resources,
    objects:result.objects,recipients:[{...f.recipient,deviceKeyVersion:1}],rootPublicKey:f.root.publicKey,cryptoValue:c});
  const metadata=await open(f,result.objects.find(o=>o.resourceID===credential.id&&o.part==='METADATA'));
  assert.deepEqual(metadata.metadata,{title:'Label',kind:'password',username:'alice'});
  assert.equal(metadata.link.teamID,f.scope.teamID);assert.equal(metadata.link.kind,'CREDENTIAL');
  assert.equal(metadata.link.resourceID,credential.id);assert.equal(JSON.stringify(metadata).includes('TEST-ONLY-SECRET'),false);
  const secret=await open(f,result.objects.find(o=>o.resourceID===credential.id&&o.part==='SECRET'));
  assert.deepEqual(secret.record,credential);
  const sidecar=await open(f,result.administrativeSidecar);
  assert.equal(sidecar.generationID,f.scope.attemptID);assert.equal(JSON.stringify(sidecar).includes('TEST-ONLY-SECRET'),false);
  assert.equal(JSON.stringify(sidecar).includes('Label'),false);assert.deepEqual(sidecar.sourceMetadata.tombstones,doc.tombstones);
  assert.equal(result.administrativeSidecar.wrappers.length,1);
});
test('reader preparation requires fresh global reservation verification before encrypting, and resumes identical signed bytes',async()=>{
  const f=await migrationFixture(),doc=legacy([record('host',{title:'Host'})]);let saved;
  await assert.rejects(prepare(f,doc,{readerPublication:{publisherAccountID:f.accountID,publisherKeyVersion:1,
    custodianDeviceIDs:[f.deviceID],verifyIdentityReservations:async()=>{throw Error('reservation_stale');}}}),/reservation_stale/);
  const first=await prepare(f,doc,{persistCheckpoint:async v=>{saved=v;}});
  const resumed=await prepare(f,doc,{checkpoint:saved});
  assert.deepEqual(resumed.readerProjection,first.readerProjection);assert.deepEqual(resumed.manifest,first.manifest);
  assert.deepEqual(resumed.administrativeSidecar,first.administrativeSidecar);
  const state=await openMigrationCheckpoint({checkpoint:saved,key:f.checkpointKey,scope:f.scope,cryptoValue:c});
  assert.equal(state.readerProjection.header.payload.generationID,f.scope.attemptID);
});
