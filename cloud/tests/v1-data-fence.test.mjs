import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { v1CiphertextHash, v1EnvelopeHash, assertV1DataFloor, readV1VaultState } from '../src/v1-data-fence.mjs';

const envelope=ciphertext=>({envelopeVersion:1,wrappedKey:{},ciphertext,nonce:'nonce',authTag:'tag',contentHash:'hash',keyGeneration:null,wrappers:null});

test('V1 data floor rejects rollback, same-revision substitution, missing and extra Vault identities',async()=>{
  const record={vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),revision:2,ciphertextHash:v1CiphertextHash('bmV3'),envelopeHash:v1EnvelopeHash(envelope('bmV3'))};
  const snapshot={v1BaselineID:randomUUID(),v1Committed:[record],v1Pending:[]};
  const row={vaultKind:record.vaultKind,ownerID:record.ownerID,vaultID:record.vaultID,revision:'2',ciphertext:'bmV3',envelope:envelope('bmV3')};
  const query=rows=>async()=>({rows});
  assert.equal(await assertV1DataFloor(query([row]),snapshot),true);
  for(const rows of [[],[{...row,revision:'1'}],[{...row,ciphertext:'c3RhbGU'}],[{...row,revision:'3'}],
    [{...row,ownerID:randomUUID()}],[row,{...row,vaultID:randomUUID()}],[row,row]])
    await assert.rejects(assertV1DataFloor(query(rows),snapshot),/deployment_v1_data_mismatch/);
  await assert.rejects(assertV1DataFloor(query([row]),{}),/deployment_v1_history_unavailable/);
});

test('null and empty ciphertext have distinct domain-separated commitments',()=>{
  assert.notEqual(v1CiphertextHash(null),v1CiphertextHash(''));
  assert.match(v1CiphertextHash('bmV3'),/^[a-f0-9]{64}$/u);
  for(const bad of [undefined,42,{},[]])assert.throws(()=>v1CiphertextHash(bad),/invalid_v1_ciphertext/);
});


test('baseline capture is deterministic and rejects malformed or inconsistent database rows',async()=>{
 const a={vaultKind:'PERSONAL',ownerID:randomUUID(),vaultID:randomUUID(),revision:'0',ciphertext:null,envelope:envelope(null)};
 const b={vaultKind:'TEAM',ownerID:randomUUID(),vaultID:randomUUID(),revision:'3',ciphertext:'bmV3',envelope:envelope('bmV3')};
 const query=rows=>async()=>({rows});
 const state=await readV1VaultState(query([b,a]));
 assert.deepEqual(state,[{...a,revision:0,ciphertextHash:v1CiphertextHash(null),envelopeHash:v1EnvelopeHash(a.envelope),ciphertext:undefined},
   {...b,revision:3,ciphertextHash:v1CiphertextHash('bmV3'),envelopeHash:v1EnvelopeHash(b.envelope),ciphertext:undefined}].map(({ciphertext,envelope,...v})=>v));
 for(const rows of [[a,a],[{...a,revision:'01'}],[{...a,ciphertext:'AA'}],[{...b,ciphertext:null}],
   [{...b,ownerID:{toString:()=>b.ownerID}}]])
   await assert.rejects(readV1VaultState(query(rows)),/deployment_v1_data_mismatch/);
});
