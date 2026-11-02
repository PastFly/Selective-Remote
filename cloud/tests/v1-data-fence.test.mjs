import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { v1CiphertextHash, assertV1DataFloor, readV1VaultState } from '../src/v1-data-fence.mjs';

const query=rows=>async()=>({rows});
const sample=(kind,revision,ciphertext)=>({vaultKind:kind,ownerID:randomUUID(),vaultID:randomUUID(),revision:String(revision),
 ciphertextNull:ciphertext===null,ciphertextNonempty:ciphertext!==null&&ciphertext.length>0,
 ciphertextHash:v1CiphertextHash(ciphertext),envelopeHash:'a'.repeat(64)});
const tuple=row=>({vaultKind:row.vaultKind,ownerID:row.ownerID,vaultID:row.vaultID,revision:Number(row.revision),ciphertextHash:row.ciphertextHash,envelopeHash:row.envelopeHash});

test('V1 data floor rejects rollback, substituted hashes, missing and extra Vault identities',async()=>{
  const row=sample('PERSONAL',2,'bmV3'),snapshot={v1BaselineID:randomUUID(),v1Committed:[tuple(row)],v1Pending:[]};
  assert.equal(await assertV1DataFloor(query([row]),snapshot),true);
  for(const rows of [[],[{...row,revision:'1'}],[{...row,ciphertextHash:v1CiphertextHash('c3RhbGU')}],
    [{...row,envelopeHash:'b'.repeat(64)}],[{...row,revision:'3'}],[{...row,ownerID:randomUUID()}],
    [row,{...row,vaultID:randomUUID()}],[row,row]])
    await assert.rejects(assertV1DataFloor(query(rows),snapshot),/deployment_v1_data_mismatch/);
  await assert.rejects(assertV1DataFloor(query([row]),{}),/deployment_v1_history_unavailable/);
});

test('null and empty ciphertext have distinct domain-separated commitments',()=>{
  assert.notEqual(v1CiphertextHash(null),v1CiphertextHash(''));
  assert.match(v1CiphertextHash('bmV3'),/^[a-f0-9]{64}$/u);
  for(const bad of [undefined,42,{},[]])assert.throws(()=>v1CiphertextHash(bad),/invalid_v1_ciphertext/);
});

test('baseline capture is deterministic and rejects malformed or inconsistent database rows',async()=>{
 const a=sample('PERSONAL',0,null),b=sample('TEAM',3,'bmV3');
 assert.deepEqual(await readV1VaultState(query([b,a])),[tuple(a),tuple(b)]);
 for(const rows of [[a,a],[{...a,revision:'01'}],[{...a,ciphertextNull:false}],[{...b,ciphertextNonempty:false}],
   [{...b,ownerID:{toString:()=>b.ownerID}}],[{...b,envelopeHash:'bad'}]])
   await assert.rejects(readV1VaultState(query(rows)),/deployment_v1_data_mismatch/);
});
