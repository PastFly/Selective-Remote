import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';
import { verifyReaderHeader, verifyReaderInventory, wrapperCommitment } from '../public/vault-publication-v1.js';

test('shared browser/Mac empty generation has a signed complete zero inventory and no empty wrapper proof', async () => {
  const f=JSON.parse(await readFile(new URL('../../Tests/SelectiveRemoteTests/Fixtures/vault-publication-empty-v1.json',import.meta.url)));
  assert.equal(f.testOnly,true);
  await verifyReaderHeader({...f,cryptoValue:webcrypto});
  await verifyReaderInventory({...f,descriptors:[],cryptoValue:webcrypto});
  await assert.rejects(wrapperCommitment([],webcrypto),/wrapper_set_empty/);
  const inventory=structuredClone(f.inventory); inventory.payload.count=1;
  await assert.rejects(verifyReaderInventory({...f,inventory,descriptors:[],cryptoValue:webcrypto}));
});
