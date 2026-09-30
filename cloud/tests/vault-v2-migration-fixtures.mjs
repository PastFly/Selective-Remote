import { randomUUID, webcrypto } from 'node:crypto';
import { generateTeamDeviceIdentity } from '../public/team-vault-crypto.js';
import { createTrustRoot, issueDeviceCertificate, signDeviceDirectory, deviceDirectoryDigest } from '../public/device-trust-v1.js';
export const uuid = randomUUID;
export async function migrationFixture() {
  const endpoint = 'https://staging.example.test', accountID = uuid(), deviceID = uuid();
  const root = await createTrustRoot({endpoint,accountID,cryptoValue:webcrypto});
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const certificate = await issueDeviceCertificate({root,accountID,deviceID,publicKey:identity.publicKey,keyVersion:1,issuedAt:1800000000,serial:uuid(),cryptoValue:webcrypto});
  const checkpoint = await signDeviceDirectory({root,accountID,version:1,certificates:[certificate],cryptoValue:webcrypto});
  const trust = {endpoint,accountID,rootFingerprint:root.fingerprint,highWater:1,checkpointDigest:await deviceDirectoryDigest(checkpoint,webcrypto)};
  const recipient = {membershipID:uuid(),membershipEpoch:1,deviceID,accountID,publicKey:identity.publicKey,rootPublicKey:root.publicKey,certificate,checkpoint};
  const scope = {teamID:uuid(),vaultID:uuid(),attemptID:uuid(),sourceRevision:1,sourceHash:'a'.repeat(64),snapshotHash:'b'.repeat(64),policyVersion:1};
  return {endpoint,accountID,deviceID,root,identity,recipient,scope,checkpointKey:webcrypto.getRandomValues(new Uint8Array(32)),
    pinnedTrust:{loadPin:async()=>trust,advancePin:async(_old,next)=>Object.assign(trust,next)}};
}
export function legacy(records) { return {schemaVersion:1,records,tombstones:[],vectorClock:{}}; }
export function record(type,data={},id=uuid()) { return {id,type,version:1,modifiedAt:1800000000,data}; }
