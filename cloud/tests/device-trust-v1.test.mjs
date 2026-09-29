import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { generateResourceCEK, unwrapResourceCEK } from "../public/resource-crypto-v2.js";
import {
  createTrustRoot, issueDeviceCertificate, signDeviceDirectory,
  verifyDeviceForWrapping, wrapForVerifiedDevice, deviceDirectoryDigest,
  advancePinnedTrust,
  createPossessionChallenge, answerPossessionChallenge, verifyPossessionAnswer,
  isDeviceEligibleForV2Wrapper,
} from "../public/device-trust-v1.js";

const accountID = "11111111-1111-4111-8111-111111111111";
const deviceID = "55555555-5555-4555-8555-555555555555";
const otherID = "66666666-6666-4666-8666-666666666666";
const endpoint = "https://cloud.example.test";
const wrapperContext = { teamID: "22222222-2222-4222-8222-222222222222",
  vaultID: "33333333-3333-4333-8333-333333333333",
  resourceID: "44444444-4444-4444-8444-444444444444",
  part: "SECRET", keyVersion: 1,
  membershipID: "77777777-7777-4777-8777-777777777777",
  membershipEpoch: 1, deviceID };

async function setup() {
  const root = await createTrustRoot({ endpoint, accountID, cryptoValue: webcrypto });
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const certificate = await issueDeviceCertificate({ root, accountID, deviceID,
    publicKey: identity.publicKey, keyVersion: 1, issuedAt: 1_800_000_000,
    serial: "88888888-8888-4888-8888-888888888888", cryptoValue: webcrypto });
  const checkpoint = await signDeviceDirectory({ root, accountID, version: 1,
    certificates: [certificate], cryptoValue: webcrypto });
  return { root, identity, certificate, checkpoint,
    trust: { endpoint, accountID, rootFingerprint: root.fingerprint, highWater: 1,
      checkpointDigest: await deviceDirectoryDigest(checkpoint, webcrypto) } };
}

function repository(initial) {
  let pin = initial;
  return {
    async loadPin() { return pin; },
    async advancePin(expected, next) {
      assert.deepEqual(pin, expected);
      pin = advancePinnedTrust(pin, next);
      return pin;
    },
    get pin() { return pin; },
  };
}

test("trusted signed certificate and directory authorize a resource wrapper", async () => {
  const { root, identity, certificate, checkpoint, trust } = await setup();
  const checked = await verifyDeviceForWrapping({ rootPublicKey: root.publicKey,
    certificate, checkpoint, trust, expectedDeviceID: deviceID, cryptoValue: webcrypto });
  assert.deepEqual(checked.publicKey, identity.publicKey);
  assert.equal(checked.highWater, 1);
  const cek = generateResourceCEK(webcrypto);
  const pinRepository = repository(trust);
  const wrapped = await wrapForVerifiedDevice({ cek, context: wrapperContext,
    rootPublicKey: root.publicKey, certificate, checkpoint, endpoint, pinRepository,
    cryptoValue: webcrypto });
  assert.equal(pinRepository.pin.highWater, 1);
  assert.deepEqual(await unwrapResourceCEK({ wrapper: wrapped.wrapper,
    context: wrapperContext, privateKey: identity.privateKey, cryptoValue: webcrypto }), cek);
});

test("server key substitution and unpaired root fail before wrapping", async () => {
  const { root, certificate, checkpoint, trust } = await setup();
  const attacker = await generateTeamDeviceIdentity(webcrypto);
  const substituted = { ...certificate,
    payload: { ...certificate.payload, publicKey: attacker.publicKey } };
  const pinRepository = repository(trust);
  const options = { cek: generateResourceCEK(webcrypto), context: wrapperContext,
    rootPublicKey: root.publicKey, certificate: substituted, checkpoint,
    endpoint, pinRepository, cryptoValue: webcrypto };
  await assert.rejects(wrapForVerifiedDevice(options), /device_trust/u);
  assert.deepEqual(pinRepository.pin, trust);
  await assert.rejects(wrapForVerifiedDevice({ ...options, certificate,
    pinRepository: repository(null) }), /device_trust/u);
  await assert.rejects(wrapForVerifiedDevice({ ...options, certificate,
    rootPublicKey: (await createTrustRoot({ endpoint, accountID, cryptoValue: webcrypto })).publicKey }),
  /device_trust/u);
  await assert.rejects(wrapForVerifiedDevice({ ...options, certificate,
    pinRepository: { loadPin: async () => trust,
      advancePin: async () => { throw new Error("storage_failed"); } } }), /storage_failed/u);
});

test("checkpoint rejects rollback, revoked devices and changed scope", async () => {
  const { root, certificate, checkpoint, trust } = await setup();
  const base = { rootPublicKey: root.publicKey, certificate, checkpoint,
    trust, expectedDeviceID: deviceID, cryptoValue: webcrypto };
  await assert.rejects(verifyDeviceForWrapping({ ...base,
    trust: { ...trust, highWater: 2 } }), /device_trust/u);
  const { checkpointDigest: _omitted, ...incompletePin } = trust;
  await assert.rejects(verifyDeviceForWrapping({ ...base,
    trust: incompletePin }), /device_trust/u);
  await assert.rejects(verifyDeviceForWrapping({ ...base,
    trust: { ...trust, accountID: otherID } }), /device_trust/u);
  await assert.rejects(verifyDeviceForWrapping({ ...base, expectedDeviceID: otherID }), /device_trust/u);
  const revoked = await signDeviceDirectory({ root, accountID, version: 2,
    certificates: [], cryptoValue: webcrypto });
  await assert.rejects(verifyDeviceForWrapping({ ...base,
    checkpoint: revoked }), /device_trust/u);
  const altered = { ...checkpoint, signature: `A${checkpoint.signature.slice(1)}` };
  await assert.rejects(verifyDeviceForWrapping({ ...base, checkpoint: altered }), /device_trust/u);
});

test("replacement needs a higher signed version and exact active certificate", async () => {
  const { root, certificate, checkpoint, trust } = await setup();
  const replacement = await generateTeamDeviceIdentity(webcrypto);
  const newer = await issueDeviceCertificate({ root, accountID, deviceID,
    publicKey: replacement.publicKey, keyVersion: 2, issuedAt: 1_800_000_001,
    serial: "99999999-9999-4999-8999-999999999999", cryptoValue: webcrypto });
  const next = await signDeviceDirectory({ root, accountID, version: 2,
    certificates: [newer], cryptoValue: webcrypto });
  const base = { rootPublicKey: root.publicKey, certificate, checkpoint: next,
    trust, expectedDeviceID: deviceID, cryptoValue: webcrypto };
  await assert.rejects(verifyDeviceForWrapping(base), /device_trust/u);
  const verified = await verifyDeviceForWrapping({ ...base, certificate: newer });
  assert.equal(verified.highWater, 2);
  assert.deepEqual(verified.publicKey, replacement.publicKey);
  await assert.rejects(signDeviceDirectory({ root, accountID, version: 2,
    certificates: [certificate, newer], cryptoValue: webcrypto }), /device_trust/u);
  const changedSameVersion = await signDeviceDirectory({ root, accountID, version: 1,
    certificates: [], cryptoValue: webcrypto });
  await assert.rejects(verifyDeviceForWrapping({ ...base, certificate,
    checkpoint: changedSameVersion }), /device_trust/u);
});

test("ECDH possession proof binds account, request, device, key and short expiry", async () => {
  const { identity } = await setup();
  const requestID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const { challenge, privateKey } = await createPossessionChallenge({
    accountID, requestID, deviceID, publicKey: identity.publicKey,
    issuedAt: 1_800_000_000, cryptoValue: webcrypto,
  });
  const answer = await answerPossessionChallenge({ challenge,
    devicePrivateKey: identity.privateKey, devicePublicKey: identity.publicKey,
    cryptoValue: webcrypto });
  assert.equal(await verifyPossessionAnswer({ challenge, answer,
    approverPrivateKey: privateKey, now: 1_800_000_001, cryptoValue: webcrypto }), true);
  await assert.rejects(verifyPossessionAnswer({ challenge: { ...challenge, deviceID: otherID },
    answer, approverPrivateKey: privateKey, now: 1_800_000_001, cryptoValue: webcrypto }),
  /device_trust/u);
  await assert.rejects(verifyPossessionAnswer({ challenge, answer,
    approverPrivateKey: privateKey, now: 1_800_000_301, cryptoValue: webcrypto }),
  /device_trust/u);
  const attacker = await generateTeamDeviceIdentity(webcrypto);
  await assert.rejects(answerPossessionChallenge({ challenge,
    devicePrivateKey: attacker.privateKey, devicePublicKey: attacker.publicKey,
    cryptoValue: webcrypto }), /device_trust/u);
  await assert.rejects(verifyPossessionAnswer({ challenge,
    answer: { ...answer, proof: `A${answer.proof.slice(1)}` },
    approverPrivateKey: privateKey, now: 1_800_000_001, cryptoValue: webcrypto }),
  /device_trust/u);
});

test("signed account device needs independent Team admission and current epoch", async () => {
  const { root, certificate, checkpoint, trust } = await setup();
  const base = { rootPublicKey: root.publicKey, certificate, checkpoint, trust,
    expectedDeviceID: deviceID, proofEstablished: true, revoked: false,
    team: { membershipActive: true, membershipEpoch: 2, expectedEpoch: 2,
      admitted: true, capable: true }, cryptoValue: webcrypto };
  assert.equal((await isDeviceEligibleForV2Wrapper(base)).eligible, true);
  for (const change of [
    { proofEstablished: false }, { revoked: true },
    { team: { ...base.team, membershipActive: false } },
    { team: { ...base.team, membershipEpoch: 1 } },
    { team: { ...base.team, admitted: false } },
    { team: { ...base.team, capable: false } },
  ]) assert.equal((await isDeviceEligibleForV2Wrapper({ ...base, ...change })).eligible, false);
  const attacker = await generateTeamDeviceIdentity(webcrypto);
  assert.equal((await isDeviceEligibleForV2Wrapper({ ...base,
    certificate: { ...certificate, payload: { ...certificate.payload,
      publicKey: attacker.publicKey } } })).eligible, false);
});
