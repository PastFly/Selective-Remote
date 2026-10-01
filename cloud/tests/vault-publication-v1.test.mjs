import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto, randomUUID } from 'node:crypto';
import { publicationBytes, publicationHash, wrapperCommitment, verifyWrapperProof,
  prepareReaderProjection, verifyReaderHeader, verifyReaderDescriptor, verifyReaderInventory,
  validateReaderProjection } from '../public/vault-publication-v1.js';
import { migrationFixture } from './vault-v2-migration-fixtures.mjs';
import { generateTeamDeviceIdentity } from '../public/team-vault-crypto.js';
import { encryptResourcePart, wrapResourceCEK } from '../public/resource-crypto-v2.js';

const c = webcrypto;
async function fixture() {
  const f = await migrationFixture(), resourceID = randomUUID();
  const context = {teamID:f.scope.teamID,vaultID:f.scope.vaultID,resourceID,part:'GENERAL',
    keyVersion:1,policyVersion:1,registryVersion:1,resourceVersion:1,manifestVersion:1};
  const cek = new Uint8Array(32).fill(17), recipients = [], wrappers = [];
  for (let n=0;n<3;n++) {
    const identity = n===0 ? f.identity : await generateTeamDeviceIdentity(c);
    const recipient = n===0 ? {...f.recipient,deviceKeyVersion:1} : {
      accountID:randomUUID(),membershipID:randomUUID(),membershipEpoch:1,
      deviceID:randomUUID(),deviceKeyVersion:1};
    recipients.push(recipient);
    wrappers.push(await wrapResourceCEK({cek,context:{teamID:context.teamID,vaultID:context.vaultID,
      resourceID,part:'GENERAL',keyVersion:1,membershipID:recipient.membershipID,
      membershipEpoch:1,deviceID:recipient.deviceID},recipientPublicKey:identity.publicKey,cryptoValue:c}));
  }
  const envelope = await encryptResourcePart({cek,context,plaintext:new TextEncoder().encode('{"title":"Host"}'),cryptoValue:c});
  const resources = [{id:resourceID,kind:'HOST',parentFolderID:null,sourceOrdinal:0}];
  const objects = [{resourceID,part:'GENERAL',envelope,wrappers}];
  const input = {scope:f.scope,resources,objects,recipients,root:f.root,
    publisherAccountID:f.accountID,publisherDeviceID:f.deviceID,publisherKeyVersion:1,cryptoValue:c};
  return {...f,resources,objects,recipients,input,projection:await prepareReaderProjection(input)};
}

test('canonical publication bytes match independently calculated literal UTF-8 vector', async () => {
  assert.equal(Buffer.from(publicationBytes('vector',{b:'é',a:1})).toString('hex'),
    '73656c6563746976652d72656d6f74652f7075626c69636174696f6e2f763100766563746f72007b2261223a312c2262223a22c3a9227d');
  assert.equal(await publicationHash('vector',{b:'é',a:1},c),'257d82987fce97825cedb0acac86e742bbbae1fb6b6ba84251df7f8d64fd3b19');
});
test('odd wrapper proof authenticates exact recipient bytes and rejects orientation/count/substitution', async () => {
  const f=await fixture(), p=f.projection.recipients[2].proofs[0];
  await verifyWrapperProof({entry:p.entry,proof:p.proof,root:f.projection.descriptors[0].payload.wrapperRoot,cryptoValue:c});
  for (const change of [x=>x.entry.wrapper.context.deviceID=randomUUID(),x=>x.proof.total=2,
    x=>x.proof.index=(x.proof.index+1)%3,x=>x.proof.siblings[0]='0'.repeat(64)]) {
    const changed=structuredClone(p);change(changed);
    await assert.rejects(verifyWrapperProof({...changed,root:f.projection.descriptors[0].payload.wrapperRoot,cryptoValue:c}));
  }
  const entries=f.projection.recipients.map(x=>x.proofs[0].entry);
  await assert.rejects(wrapperCommitment([entries[0],entries[0]],c),/duplicate_wrapper/);
  await assert.rejects(wrapperCommitment([],c),/wrapper_set_empty/);
});
test('signed header rejects scope tamper, rollback, fork and unsigned extra fields', async () => {
  const f=await fixture(), header=f.projection.header;
  const hash=await verifyReaderHeader({header,rootPublicKey:f.root.publicKey,teamID:f.scope.teamID,
    vaultID:f.scope.vaultID,highWater:null,cryptoValue:c});
  assert.match(hash,/^[a-f0-9]{64}$/);
  for(const change of [h=>h.payload.vaultID=randomUUID(),h=>h.payload.sequence=2,h=>h.extra=true]) {
    const h=structuredClone(header);change(h);
    await assert.rejects(verifyReaderHeader({header:h,rootPublicKey:f.root.publicKey,
      teamID:f.scope.teamID,vaultID:f.scope.vaultID,cryptoValue:c}));
  }
  await assert.rejects(verifyReaderHeader({header,rootPublicKey:f.root.publicKey,teamID:f.scope.teamID,
    vaultID:f.scope.vaultID,highWater:{sequence:2,hash:'1'.repeat(64)},cryptoValue:c}),/publication_rollback/);
  await assert.rejects(verifyReaderHeader({header,rootPublicKey:f.root.publicKey,teamID:f.scope.teamID,
    vaultID:f.scope.vaultID,highWater:{sequence:1,hash:'1'.repeat(64)},cryptoValue:c}),/publication_fork/);
});
test('descriptor binds header, resource kind, ciphertext and recipient wrapper proof', async () => {
  const f=await fixture(), descriptor=f.projection.descriptors[0], proof=f.projection.recipients[0].proofs[0];
  await verifyReaderDescriptor({descriptor,header:f.projection.header,rootPublicKey:f.root.publicKey,
    envelope:f.objects[0].envelope,...proof,cryptoValue:c});
  for (const change of [x=>x.payload.kind='SNIPPET',x=>x.payload.headerHash='0'.repeat(64),
    x=>x.payload.context.resourceVersion=2]) {
    const changed=structuredClone(descriptor);change(changed);
    await assert.rejects(verifyReaderDescriptor({descriptor:changed,header:f.projection.header,
      rootPublicKey:f.root.publicKey,envelope:f.objects[0].envelope,...proof,cryptoValue:c}));
  }
  const altered=structuredClone(f.objects[0].envelope);altered.authTag='A'.repeat(22);
  await assert.rejects(verifyReaderDescriptor({descriptor,header:f.projection.header,rootPublicKey:f.root.publicKey,
    envelope:altered,...proof,cryptoValue:c}),/publication_ciphertext_mismatch/);
});
test('signed inventory proves completeness and cannot clear models from withheld pages or another device', async () => {
  const f=await fixture(), inventory=f.projection.recipients.find(r=>r.inventory.payload.deviceID===f.deviceID).inventory, subject=f.recipients[0];
  await verifyReaderInventory({inventory,descriptors:f.projection.descriptors,header:f.projection.header,
    rootPublicKey:f.root.publicKey,subject,cryptoValue:c});
  await assert.rejects(verifyReaderInventory({inventory,descriptors:[],header:f.projection.header,
    rootPublicKey:f.root.publicKey,subject,cryptoValue:c}),/publication_incomplete/);
  await assert.rejects(verifyReaderInventory({inventory,descriptors:f.projection.descriptors,header:f.projection.header,
    rootPublicKey:f.root.publicKey,subject:f.recipients[1],cryptoValue:c}),/publication_subject_mismatch/);
});
test('READY validation rejects omitted projection part and mismatched administrative objects', async () => {
  const f=await fixture();await validateReaderProjection({...f.input,projection:f.projection,rootPublicKey:f.root.publicKey});
  const projection=structuredClone(f.projection);projection.descriptors=[];
  await assert.rejects(validateReaderProjection({...f.input,projection,rootPublicKey:f.root.publicKey}));
  const objects=structuredClone(f.objects);objects[0].wrappers.pop();
  await assert.rejects(validateReaderProjection({...f.input,objects,projection:f.projection,rootPublicKey:f.root.publicKey}));
});
test('projection cannot prepare a wrapper for another resource or omit required Credential SECRET', async () => {
  const f=await fixture(),objects=structuredClone(f.objects);
  objects[0].wrappers[0].context.resourceID=randomUUID();
  await assert.rejects(prepareReaderProjection({...f.input,objects}),/publication_scope_mismatch/);
  const resources=structuredClone(f.resources);resources[0].kind='CREDENTIAL';
  await assert.rejects(prepareReaderProjection({...f.input,resources}),/publication_incomplete/);
});
