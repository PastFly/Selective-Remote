import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import {
  generateResourceCEK, resourceCiphertextAAD, resourceWrapperAAD,
  encryptResourcePart, decryptResourcePart, wrapResourceCEK, unwrapResourceCEK,
  validateResourceVersionSet, prepareResourceRotation,
  validateResourceVersionCompatibility,
} from "../public/resource-crypto-v2.js";

const teamID = "11111111-1111-4111-8111-111111111111";
const vaultID = "22222222-2222-4222-8222-222222222222";
const resourceID = "33333333-3333-4333-8333-333333333333";
const membershipID = "44444444-4444-4444-8444-444444444444";
const deviceID = "55555555-5555-4555-8555-555555555555";
const content = { teamID, vaultID, resourceID, part: "METADATA", keyVersion: 1,
  policyVersion: 2, registryVersion: 4, resourceVersion: 5, manifestVersion: 7 };
const recipient = { ...content, membershipID, membershipEpoch: 3, deviceID };
const flipFirst = (value) => `${value[0] === "A" ? "B" : "A"}${value.slice(1)}`;

test("CEKs are random fixed-size keys and version sets are independent monotonic counters", () => {
  const keys = Array.from({ length: 100 }, () => generateResourceCEK(webcrypto));
  assert.ok(keys.every((key) => key.length === 32));
  assert.equal(new Set(keys.map((key) => Buffer.from(key).toString("hex"))).size, 100);
  assert.deepEqual(validateResourceVersionSet(content), content);
  assert.throws(() => validateResourceVersionSet({ ...content, manifestVersion: 0 }));
  assert.throws(() => validateResourceVersionSet({ ...content, keyVersion: 1.5 }));
  assert.throws(() => validateResourceVersionSet({ ...content, schemaVersion: 1 }));
});

test("canonical binary AAD is stable, versioned and field-disjoint", () => {
  const a = resourceCiphertextAAD(content);
  assert.deepEqual(a, resourceCiphertextAAD({ ...content, teamID: teamID.toUpperCase() }));
  assert.notDeepEqual(a, resourceCiphertextAAD({ ...content, vaultID: teamID, teamID: vaultID }));
  assert.notDeepEqual(a, resourceWrapperAAD(recipient));
  for (const [field, value] of Object.entries({ teamID: vaultID, vaultID: teamID,
    resourceID: vaultID, part: "SECRET", keyVersion: 2, membershipID: deviceID,
    membershipEpoch: 4, deviceID: membershipID })) {
    assert.notDeepEqual(resourceWrapperAAD(recipient), resourceWrapperAAD({ ...recipient, [field]: value }), field);
  }
  assert.throws(() => resourceWrapperAAD({ ...recipient, schemaVersion: 3 }));
});

test("resource ciphertext authenticates scope, part, versions, nonce and body", async () => {
  const cek = generateResourceCEK(webcrypto);
  const plaintext = new TextEncoder().encode("secret-data");
  const envelope = await encryptResourcePart({ plaintext, cek, context: content, cryptoValue: webcrypto });
  assert.equal(envelope.formatVersion, 2);
  assert.equal(envelope.algorithm, "AES-256-GCM");
  assert.deepEqual(await decryptResourcePart({ envelope, cek, context: content, cryptoValue: webcrypto }), plaintext);
  for (const [field, value] of Object.entries({ teamID: vaultID, vaultID: teamID,
    resourceID: vaultID, part: "SECRET", keyVersion: 2, policyVersion: 3,
    registryVersion: 5, resourceVersion: 6, manifestVersion: 8 })) {
    await assert.rejects(decryptResourcePart({ envelope, cek,
      context: { ...content, [field]: value }, cryptoValue: webcrypto }), undefined, field);
  }
  for (const field of ["nonce", "ciphertext"]) {
    const mutated = { ...envelope, [field]: flipFirst(envelope[field]) };
    await assert.rejects(decryptResourcePart({ envelope: mutated, cek, context: content, cryptoValue: webcrypto }));
  }
  await assert.rejects(decryptResourcePart({ envelope: { ...envelope, algorithm: "none" }, cek,
    context: content, cryptoValue: webcrypto }));
  await assert.rejects(decryptResourcePart({ envelope: { ...envelope, ciphertext: "A" }, cek,
    context: content, cryptoValue: webcrypto }));
  const second = await encryptResourcePart({ plaintext, cek, context: content, cryptoValue: webcrypto });
  assert.notEqual(second.nonce, envelope.nonce);
});

test("authenticated empty resource parts round-trip without a malformed base64 exception", async () => {
  const cek = generateResourceCEK(webcrypto);
  const envelope = await encryptResourcePart({ plaintext: new Uint8Array(), cek,
    context: content, cryptoValue: webcrypto });
  assert.equal(envelope.ciphertext, "");
  assert.deepEqual(await decryptResourcePart({ envelope, cek, context: content,
    cryptoValue: webcrypto }), new Uint8Array());
});

test("wrapper-v2 is bound to recipient, epoch, team, Vault, resource and part", async () => {
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const other = await generateTeamDeviceIdentity(webcrypto);
  const cek = generateResourceCEK(webcrypto);
  const wrapper = await wrapResourceCEK({ cek, context: recipient,
    recipientPublicKey: identity.publicKey, cryptoValue: webcrypto });
  assert.deepEqual(await unwrapResourceCEK({ wrapper, context: recipient,
    privateKey: identity.privateKey, cryptoValue: webcrypto }), cek);
  await assert.rejects(unwrapResourceCEK({ wrapper, context: recipient,
    privateKey: other.privateKey, cryptoValue: webcrypto }));
  for (const [field, value] of Object.entries({ teamID: vaultID, vaultID: teamID,
    resourceID: vaultID, part: "SECRET", keyVersion: 2, membershipID: deviceID,
    membershipEpoch: 4, deviceID: membershipID, schemaVersion: 3 })) {
    await assert.rejects(unwrapResourceCEK({ wrapper, context: { ...recipient, [field]: value },
      privateKey: identity.privateKey, cryptoValue: webcrypto }), undefined, field);
  }
  await assert.rejects(unwrapResourceCEK({ wrapper: { ...wrapper, ciphertext: flipFirst(wrapper.ciphertext) },
    context: recipient, privateKey: identity.privateKey, cryptoValue: webcrypto }));
  await assert.rejects(unwrapResourceCEK({ wrapper: { ...wrapper, nonce: "A" },
    context: recipient, privateKey: identity.privateKey, cryptoValue: webcrypto }));
  await assert.rejects(unwrapResourceCEK({ wrapper: { ...wrapper, wrapperVersion: 1 },
    context: recipient, privateKey: identity.privateKey, cryptoValue: webcrypto }));
});

test("rotation preparation creates a fresh CEK and advances key and manifest versions", () => {
  const oldCEK = generateResourceCEK(webcrypto);
  const next = prepareResourceRotation({ context: content, oldCEK, cryptoValue: webcrypto });
  assert.equal(next.state, "PREPARED");
  assert.equal(next.context.keyVersion, 2);
  assert.equal(next.context.manifestVersion, 8);
  assert.equal(next.context.policyVersion, content.policyVersion);
  assert.notDeepEqual(next.cek, oldCEK);
});

test("version compatibility rejects stale pointer, wrapper and independent counters", async () => {
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const cek = generateResourceCEK(webcrypto);
  const ciphertext = await encryptResourcePart({ plaintext: new TextEncoder().encode("state"),
    cek, context: content, cryptoValue: webcrypto });
  const wrapper = await wrapResourceCEK({ cek, context: recipient,
    recipientPublicKey: identity.publicKey, cryptoValue: webcrypto });
  const pointer = { keyVersion: 1, manifestVersion: 7 };
  assert.equal(validateResourceVersionCompatibility({ ciphertext, wrapper, pointer,
    expected: content }), true);
  assert.throws(() => validateResourceVersionCompatibility({ ciphertext, wrapper,
    pointer: { ...pointer, manifestVersion: 6 }, expected: content }), /stale_resource_v2_version/u);
  assert.throws(() => validateResourceVersionCompatibility({ ciphertext, wrapper: {
    ...wrapper, context: { ...wrapper.context, keyVersion: 2 } }, pointer, expected: content }),
  /stale_resource_v2_version/u);
  for (const field of ["policyVersion", "registryVersion", "resourceVersion"]) {
    assert.throws(() => validateResourceVersionCompatibility({ ciphertext, wrapper, pointer,
      expected: { ...content, [field]: content[field] + 1 } }), /stale_resource_v2_version/u);
  }
});
