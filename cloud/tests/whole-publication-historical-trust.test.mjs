import test from 'node:test';
import assert from 'node:assert/strict';
import {migrationFixture} from './vault-v2-migration-fixtures.mjs';
import {verifyHistoricalDeviceCertificate,verifyDeviceForWrapping} from '../public/device-trust-v1.js';
test('historical publisher authentication cannot lower pins or authorize active wrapping',async()=>{
  const f=await migrationFixture(),trust=await f.pinnedTrust.loadPin(f.endpoint,f.accountID);trust.highWater=2;
  const before=structuredClone(trust),input={rootPublicKey:f.root.publicKey,certificate:f.recipient.certificate,trust,
    expectedAccountID:f.accountID,expectedDeviceID:f.deviceID,expectedKeyVersion:1};
  assert.equal((await verifyHistoricalDeviceCertificate(input)).historical,true);assert.deepEqual(trust,before);
  await assert.rejects(verifyDeviceForWrapping({...input,checkpoint:f.recipient.checkpoint}),/device_trust_invalid/);
  for(const change of [{trust:null},{expectedKeyVersion:2},{trust:{...trust,rootFingerprint:'a'.repeat(64)}},{certificate:{...f.recipient.certificate,signature:'A'.repeat(86)}}])
    await assert.rejects(verifyHistoricalDeviceCertificate({...input,...change}));
});
