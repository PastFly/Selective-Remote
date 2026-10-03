import test from 'node:test';
import assert from 'node:assert/strict';
import {WholePublicationStore} from '../src/whole-publication-store.mjs';
import {canonicalMigrationJSON} from '../src/migration-policy.mjs';
test('large opaque checkpoint validates without recursive regex; exact encoded budget and invalid alphabet fail typed',()=>{
  const store=new WholePublicationStore(null),value={version:1,nonce:'A'.repeat(16),ciphertext:'A'.repeat(6*1024*1024)};
  assert.doesNotThrow(()=>store.checkpoint(value));
  const overhead=Buffer.byteLength(canonicalMigrationJSON({...value,ciphertext:''})),maximum=64*1024*1024-overhead;
  assert.doesNotThrow(()=>store.checkpoint({...value,ciphertext:'A'.repeat(maximum)}));
  for(const ciphertext of ['A'.repeat(maximum+1),'A'.repeat(1024*1024)+'\n','A'.repeat(21)])
    assert.throws(()=>store.checkpoint({...value,ciphertext}),e=>e.code==='invalid_migration_checkpoint');
});
